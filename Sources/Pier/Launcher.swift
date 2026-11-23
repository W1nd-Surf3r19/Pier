import AppKit
import SwiftUI

struct LaunchItem: Identifiable, Hashable {
    enum Kind: Hashable { case app, setting, folder }
    /// Pfad (App, Ordner) bzw. Einstellungs-URL.
    let id: String
    let name: String
    var kind: Kind = .app
    /// SF Symbol statt Datei-Icon (Einstellungsbereiche).
    var symbol: String? = nil
    var url: URL { kind == .setting ? URL(string: id)! : URL(fileURLWithPath: id) }
}

/// Bereiche der Systemeinstellungen. Die Namen in den .appex sind englisch, deshalb eine feste deutsche Liste;
/// gezeigt wird nur, was es auf diesem Mac gibt. Alle Links am 2026-11-23 einzeln geprüft (macOS 27); „Maus“ fehlt,
/// weil der Link ohne angeschlossene Maus in „Tastatur“ landet.
enum SettingsCatalog {
    private static let panes: [(name: String, bundle: String, appex: String, symbol: String)] = [
        ("Allgemein", "com.apple.systempreferences.GeneralSettings", "GeneralSettings", "gearshape.fill"),
        ("Apple Account", "com.apple.systempreferences.AppleIDSettings", "AppleIDSettings", "person.crop.circle.fill"),
        ("WLAN", "com.apple.wifi-settings-extension", "Wi-Fi", "wifi"),
        ("Bluetooth", "com.apple.BluetoothSettings", "Bluetooth", "antenna.radiowaves.left.and.right"),
        ("Netzwerk", "com.apple.Network-Settings.extension", "Network", "network"),
        ("VPN", "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", "VPN", "lock.shield.fill"),
        ("Batterie", "com.apple.Battery-Settings.extension", "PowerPreferences", "battery.100percent"),
        ("Erscheinungsbild", "com.apple.Appearance-Settings.extension", "Appearance", "circle.lefthalf.filled"),
        ("Bedienungshilfen", "com.apple.Accessibility-Settings.extension", "AccessibilitySettingsExtension", "accessibility"),
        ("Menüleiste", "com.apple.ControlCenter-Settings.extension", "ControlCenterSettings", "menubar.rectangle"),
        ("Siri", "com.apple.Siri-Settings.extension", "SiriPreferenceExtension", "waveform"),
        ("Spotlight", "com.apple.Spotlight-Settings.extension", "SpotlightPreferenceExtension", "magnifyingglass"),
        ("Datenschutz & Sicherheit", "com.apple.settings.PrivacySecurity.extension", "SecurityPrivacyExtension", "hand.raised.fill"),
        ("Schreibtisch & Dock", "com.apple.Desktop-Settings.extension", "DesktopSettings", "dock.rectangle"),
        ("Displays", "com.apple.Displays-Settings.extension", "DisplaysExt", "display"),
        ("Hintergrundbild", "com.apple.Wallpaper-Settings.extension", "Wallpaper", "photo.fill"),
        ("Mitteilungen", "com.apple.Notifications-Settings.extension", "NotificationsSettings", "bell.badge.fill"),
        ("Ton", "com.apple.Sound-Settings.extension", "Sound", "speaker.wave.2.fill"),
        ("Fokus", "com.apple.Focus-Settings.extension", "FocusSettingsExtension", "moon.fill"),
        ("Bildschirmzeit", "com.apple.Screen-Time-Settings.extension", "ScreenTimePreferencesExtension", "hourglass"),
        ("Sperrbildschirm", "com.apple.Lock-Screen-Settings.extension", "LockScreen", "lock.fill"),
        ("Touch ID & Passwort", "com.apple.Touch-ID-Settings.extension", "Touch ID & Password", "touchid"),
        ("Benutzer:innen & Gruppen", "com.apple.Users-Groups-Settings.extension", "UsersGroups", "person.2.fill"),
        ("Internetaccounts", "com.apple.Internet-Accounts-Settings.extension", "InternetAccountsSettingsExtension", "at"),
        ("Wallet & Apple Pay", "com.apple.WalletSettingsExtension", "WalletSettingsExtension", "wallet.pass.fill"),
        ("Tastatur", "com.apple.Keyboard-Settings.extension", "KeyboardSettings", "keyboard"),
        ("Trackpad", "com.apple.Trackpad-Settings.extension", "TrackpadExtension", "rectangle.and.hand.point.up.left.fill"),
        ("Drucker & Scanner", "com.apple.Print-Scan-Settings.extension", "PrinterScannerSettings", "printer.fill"),
        ("Softwareupdate", "com.apple.Software-Update-Settings.extension", "SoftwareUpdateSettingsExtension", "arrow.triangle.2.circlepath"),
        ("Speicher", "com.apple.settings.Storage", "Storage", "internaldrive.fill"),
        ("Teilen", "com.apple.Sharing-Settings.extension", "Sharing", "person.2.wave.2.fill"),
        ("Time Machine", "com.apple.Time-Machine-Settings.extension", "TimeMachineSettings", "clock.arrow.circlepath"),
        ("Anmeldeobjekte", "com.apple.LoginItems-Settings.extension", "LoginItems", "list.bullet.rectangle.fill"),
        ("Sprache & Region", "com.apple.Localization-Settings.extension", "Localization", "globe"),
        ("Datum & Uhrzeit", "com.apple.Date-Time-Settings.extension", "DateAndTime Extension", "clock.fill"),
        ("Startvolume", "com.apple.Startup-Disk-Settings.extension", "StartupDisk", "externaldrive.fill"),
        ("Info", "com.apple.SystemProfiler.AboutExtension", "AboutExtension", "info.circle.fill"),
    ]

    static func scan() -> [LaunchItem] {
        panes.filter { FileManager.default.fileExists(atPath: "/System/Library/ExtensionKit/Extensions/\($0.appex).appex") }
            .map { LaunchItem(id: "x-apple.systempreferences:\($0.bundle)", name: $0.name, kind: .setting, symbol: $0.symbol) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Standardordner des Benutzers plus die eigenen aus den Einstellungen.
    static func folders(custom: [String]) -> [LaunchItem] {
        let fm = FileManager.default
        let standard: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory,
                                                           .applicationDirectory]
        let urls = [fm.homeDirectoryForCurrentUser] + standard.compactMap { fm.urls(for: $0, in: $0 == .applicationDirectory ? .localDomainMask : .userDomainMask).first }
            + custom.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL.path)
            .filter { fm.fileExists(atPath: $0) && seen.insert($0).inserted }
            .map { LaunchItem(id: $0, name: fm.displayName(atPath: $0), kind: .folder) }
    }
}

enum AppCatalog {
    static func scan() -> [LaunchItem] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var paths: [String] = []
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names where !n.hasPrefix(".") {
                let p = root + "/" + n
                if n.hasSuffix(".app") {
                    paths.append(p)
                } else if root != "/Applications/Utilities", root != "/System/Applications/Utilities",
                          let sub = try? fm.contentsOfDirectory(atPath: p) {
                    // Eine Ebene tiefer, z. B. „/Applications/Adobe Photoshop/…app“
                    paths.append(contentsOf: sub.filter { $0.hasSuffix(".app") }.map { p + "/" + $0 })
                }
            }
        }
        paths.append("/System/Library/CoreServices/Finder.app")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
            .map { LaunchItem(id: $0, name: AppName.display(forPath: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case apps = "Apps", settings = "Einstellungen", folders = "Ordner"
        var id: String { rawValue }
    }

    @Published var query = "" { didSet { selection = 0 } }
    @Published var section = Section.apps { didSet { selection = 0; scrollTarget = nil } }
    @Published var selection = 0
    @Published private(set) var all: [LaunchItem] = []
    private let settingsItems = SettingsCatalog.scan()
    /// Beim Öffnen eingelesen (reload), nicht bei jedem Tastendruck.
    @Published private(set) var folderItems: [LaunchItem] = []
    @Published var focusToken = 0
    /// Nur Tastatur-Navigation scrollt – Hover soll die Liste nicht verschieben.
    @Published var scrollTarget: String?

    static let columns = 6

    /// Ohne Suche der gewählte Bereich; mit Suche alles (Apps zuerst, dann Einstellungen, dann Ordner).
    var results: [LaunchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            switch section {
            case .apps: return all
            case .settings: return settingsItems
            case .folders: return folderItems
            }
        }
        let all = self.all + settingsItems + folderItems
        let prefix = all.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        let contains = all.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil && !prefix.contains($0)
        }
        return prefix + contains
    }

    func reload() {
        folderItems = SettingsCatalog.folders(custom: DockStore.shared.settings.launcherFolders)
        Task.detached(priority: .userInitiated) {
            let items = AppCatalog.scan()
            await MainActor.run { self.all = items }
        }
    }

    func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selection = min(max(selection + delta, 0), n - 1)
        scrollTarget = results[selection].id
    }
}

/// Launchpad-Ersatz: Overlay mit Sofortsuche. Öffnet per Dock-Kachel oder ⌥ Leertaste.
@MainActor
final class LauncherController: NSObject, NSWindowDelegate {
    let panel: KeyPanel
    let model = LauncherModel()
    private var keyMonitor: Any?
    private let size = NSSize(width: 780, height: 560)

    var isVisible: Bool { panel.isVisible }

    override init() {
        let (panel, effect) = PanelFactory.makeGlass(KeyPanel.self, level: PanelFactory.dockLevel + 2, radius: 24)
        self.panel = panel
        super.init()
        effect.material = .popover
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        let hosting = FirstMouseHostingView(rootView: LauncherView(model: model, onLaunch: { [weak self] in self?.launch($0) }))
        hosting.sizingOptions = []
        PanelFactory.embed(hosting, in: effect)
        model.reload()
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? PanelFactory.mainScreen
        guard let sf = screen?.visibleFrame else { return }
        model.query = ""
        model.section = .apps
        model.selection = 0
        model.scrollTarget = nil
        model.reload()
        panel.setFrame(NSRect(x: (sf.midX - size.width / 2).rounded(), y: (sf.midY - size.height / 2 + 40).rounded(),
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func launch(_ item: LaunchItem) {
        hide()
        if item.kind == .app { AppActions.launch(item.url) } else { NSWorkspace.shared.open(item.url) }
    }

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.window === self.panel else { return e }
                let cols = LauncherModel.columns
                switch e.keyCode {
                case 53: self.hide()
                case 36, 76:
                    let r = self.model.results
                    if r.indices.contains(self.model.selection) { self.launch(r[self.model.selection]) }
                case 123: self.model.move(-1)
                case 124: self.model.move(1)
                case 125: self.model.move(cols)
                case 126: self.model.move(-cols)
                default: return e
                }
                return nil
            }
        }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    var onLaunch: (LaunchItem) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Apps, Einstellungen und Ordner durchsuchen", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                Button { Coordinator.shared.openSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Pier-Einstellungen")
            }
            .padding(.horizontal, 24)
            .frame(height: 66)

            if model.query.isEmpty {
                Picker("Bereich", selection: $model.section) {
                    ForEach(LauncherModel.Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                .padding(.bottom, 12)
            }

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)

            if results.isEmpty {
                Spacer()
                Text("Nichts gefunden").font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(116), spacing: 4), count: LauncherModel.columns),
                                  spacing: 8) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                LauncherCell(item: item, selected: i == model.selection)
                                    .id(item.id)
                                    .onTapGesture { onLaunch(item) }
                                    .onHoverAlways { h, _ in if h { model.selection = i } }
                            }
                        }
                        .padding(18)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.scrollTarget) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Gleiche Rundung wie das Glas-Panel (makeGlass radius: 24).
        .background(RoundedRectangle(cornerRadius: 24).fill(ThemeModel.shared.colors.glassTint))
        .onChange(of: model.focusToken, initial: true) { DispatchQueue.main.async { focused = true } }
    }
}

struct LauncherCell: View {
    let item: LaunchItem
    let selected: Bool
    private var theme: ThemeColors { ThemeModel.shared.colors }

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if let symbol = item.symbol {
                    // Einstellungsbereich: Symbol auf grauer Kachel wie in den Systemeinstellungen.
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.38)], startPoint: .top, endPoint: .bottom)))
                        .frame(width: 62, height: 62)
                } else {
                    Image(nsImage: IconCache.icon(forPath: item.id))
                        .resizable().interpolation(.high)
                        .frame(width: 62, height: 62)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(item.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? theme.accent.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
