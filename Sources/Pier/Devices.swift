import AppKit
import CoreAudio
import IOBluetooth
import IOKit

// MARK: Akkuzustand

struct BatteryHealth: Equatable {
    var cycles: Int?
    var designCycles: Int?
    /// Maximale Kapazität in Prozent der ursprünglichen (wie in den Systemeinstellungen).
    var maxCapacity: Int?

    /// Nennkapazität / Design-Kapazität, höchstens 100 % (neue Akkus liegen oft leicht darüber).
    nonisolated static func percent(nominal: Int, design: Int) -> Int? {
        guard nominal > 0, design > 0 else { return nil }
        return min(100, Int((Double(nominal) / Double(design) * 100).rounded()))
    }

    /// Liest den Akku aus der IORegistry (AppleSmartBattery); nil ohne eingebauten Akku.
    static func read() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // Neuere Macs legen die Kapazitäten nur verschachtelt unter „BatteryData“ ab.
        let data = prop("BatteryData") as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (data[key] as? Int) ?? (prop(key) as? Int) }
        let max = int("NominalChargeCapacity").flatMap { n in int("DesignCapacity").flatMap { percent(nominal: n, design: $0) } }
        return BatteryHealth(cycles: prop("CycleCount") as? Int, designCycles: prop("DesignCycleCount9C") as? Int, maxCapacity: max)
    }
}

// MARK: Ton-Ein- und -Ausgänge (CoreAudio)

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
}

enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = name(of: id), !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            // Virtuelle Geräte (z. B. „Microsoft Teams Audio“) lassen sich nicht als Standard wählen – weglassen.
            let out = hasStreams(id, scope: kAudioDevicePropertyScopeOutput) && canBeDefault(id, scope: kAudioDevicePropertyScopeOutput)
            let inp = hasStreams(id, scope: kAudioDevicePropertyScopeInput) && canBeDefault(id, scope: kAudioDevicePropertyScopeInput)
            return out || inp ? AudioDevice(id: id, name: name, hasOutput: out, hasInput: inp) : nil
        }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func canBeDefault(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope)
        var value: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) != noErr || value != 0
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    static func setDefault(_ id: AudioDeviceID, input: Bool) -> Bool {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }
}

// MARK: Laufwerke und Bluetooth

struct ExternalVolume: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let isNetwork: Bool
}

struct BluetoothItem: Identifiable, Equatable {
    var id: String { address }
    let address: String
    let name: String
    let connected: Bool
}

@MainActor
final class DevicesModel: ObservableObject {
    static let shared = DevicesModel()

    @Published private(set) var volumes: [ExternalVolume] = []
    @Published private(set) var ejecting: Set<URL> = []
    @Published private(set) var bluetooth: [BluetoothItem] = []
    @Published private(set) var busyBluetooth: Set<String> = []
    /// Letzte Fehlermeldung (z. B. „wird benutzt“), wird beim nächsten Öffnen gelöscht.
    @Published var message: String?

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DevicesModel.shared.refreshVolumes() }
            }
        }
        refreshVolumes()
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
                                      .volumeIsLocalKey, .volumeLocalizedNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let new = urls.compactMap { url -> ExternalVolume? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return nil }
            let network = v.volumeIsLocal == false
            let external = v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false || network
            guard external, url.path != "/" else { return nil }
            return ExternalVolume(url: url, name: v.volumeLocalizedName ?? url.lastPathComponent, isNetwork: network)
        }
        if new != volumes { volumes = new }
    }

    /// Auswerfen blockiert (Finder fragt Apps nach offenen Dateien) – deshalb im Hintergrund.
    func eject(_ volume: ExternalVolume) {
        guard !ejecting.contains(volume.url) else { return }
        ejecting.insert(volume.url)
        let url = volume.url, name = volume.name
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch {
                failure = "„\(name)“ konnte nicht ausgeworfen werden: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = DevicesModel.shared
                    m.ejecting.remove(url)
                    if let failure { m.message = failure }
                    m.refreshVolumes()
                    // Letztes Laufwerk weg und kein Bluetooth: die Geräte-Kachel verschwindet, ihr Popup auch.
                    if m.volumes.isEmpty, !DockStore.shared.settings.showBluetooth, m.message == nil,
                       Coordinator.shared.popup.content == .devices {
                        Coordinator.shared.popup.hide()
                    }
                }
            }
        }
    }

    func ejectAll() { volumes.forEach(eject) }

    /// Erst beim Öffnen der Liste abfragen – der erste Zugriff löst die Bluetooth-Abfrage von macOS aus.
    func refreshBluetooth() {
        guard DockStore.shared.settings.showBluetooth else {
            bluetooth = []
            return
        }
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        bluetooth = devices.compactMap { d in
            guard let address = d.addressString else { return nil }
            return BluetoothItem(address: address, name: d.name ?? address, connected: d.isConnected())
        }
        .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    /// Verbinden (asynchron, Rückmeldung über `BluetoothConnector`) bzw. trennen – IOBluetooth nur auf dem Hauptthread.
    func toggle(_ item: BluetoothItem) {
        guard !busyBluetooth.contains(item.address), let device = IOBluetoothDevice(addressString: item.address) else { return }
        if item.connected {
            if device.closeConnection() != kIOReturnSuccess { message = "„\(item.name)“ ließ sich nicht trennen." }
            refreshBluetooth()
            return
        }
        busyBluetooth.insert(item.address)
        let connector = BluetoothConnector { [weak self] ok in
            guard let self else { return }
            self.busyBluetooth.remove(item.address)
            if !ok { self.message = "„\(item.name)“ ließ sich nicht verbinden." }
            self.refreshBluetooth()
        }
        connectors.insert(connector)
        connector.done = { [weak self, weak connector] in if let connector { self?.connectors.remove(connector) } }
        if device.openConnection(connector) != kIOReturnSuccess { connector.finish(false) }
    }

    /// Hält die Delegates, bis die Verbindung steht oder scheitert.
    private var connectors = Set<BluetoothConnector>()
}

/// Empfängt `connectionComplete` von `openConnection(_:)`.
final class BluetoothConnector: NSObject {
    private let result: @MainActor (Bool) -> Void
    var done: (() -> Void)?
    private var finished = false

    init(result: @escaping @MainActor (Bool) -> Void) { self.result = result }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) { finish(status == kIOReturnSuccess) }

    /// Immer über die Main-Queue – IOBluetooth sichert nicht zu, auf welchem Thread der Rückruf kommt.
    func finish(_ ok: Bool) {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true
            MainActor.assumeIsolated { self.result(ok) }
            self.done?()
        }
    }
}
