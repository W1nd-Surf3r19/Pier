import AppKit
import CoreImage
import IOKit.ps
import SwiftUI

struct BatteryState: Equatable {
    var level: Int
    var charging: Bool
    var onPower: Bool
    /// Restlaufzeit bzw. Zeit bis voll in Minuten (nil = unbekannt, z. B. kurz nach dem Umstecken).
    var minutes: Int? = nil
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var playerBundleID: String
    /// Länge und Position in Sekunden; die Position galt zum Zeitpunkt `positionDate`.
    var duration: Double?
    var position: Double?
    var positionDate = Date()

    /// Anteil 0…1 – beim Abspielen läuft die Position seit `positionDate` weiter.
    func fraction(at now: Date) -> Double? {
        guard let duration, duration > 0, let position else { return nil }
        let p = position + (isPlaying ? now.timeIntervalSince(positionDate) : 0)
        return min(max(p / duration, 0), 1)
    }

    /// Position auf „jetzt“ festschreiben, z. B. vor Pause oder wenn die Quelle keine neue liefert.
    mutating func rebase(at now: Date) {
        if let duration, let f = fraction(at: now) { position = f * duration }
        positionDate = now
    }
}

/// AppleScript über osascript im Hintergrund – nur an laufende Apps, sonst würde AppleScript sie starten.
enum PlayerScript {
    static func run(_ bundleID: String, _ source: String, done: @escaping @MainActor (String?) -> Void) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            Task { @MainActor in done(nil) }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = proc.terminationStatus == 0
            Task { @MainActor in done(ok ? out : nil) }
        }
        do { try p.run() } catch { Task { @MainActor in done(nil) } }
    }

    /// „Titel|Position|Länge“ – der Titel darf selbst „|“ enthalten, die Zahlen stehen hinten.
    nonisolated static func parse(_ text: String) -> (title: String, position: Double, duration: Double)? {
        let parts = text.components(separatedBy: "|")
        guard parts.count >= 3, let pos = Double(parts[parts.count - 2]), let dur = Double(parts[parts.count - 1]) else { return nil }
        return (parts.dropLast(2).joined(separator: "|"), pos, dur)
    }
}

@MainActor
final class WidgetModel: ObservableObject {
    static let shared = WidgetModel()

    @Published private(set) var battery: BatteryState?
    @Published private(set) var nowPlaying: NowPlaying? { didSet { if nowPlaying?.title != oldValue?.title { refreshArtwork() } } }
    /// Grundfarbe des aktuellen Covers – nur fürs Thema „Now Playing“ ermittelt.
    @Published private(set) var artworkColor: NSColor?
    private var artworkKey: String?

    private var timer: Timer?
    private var mediaTimer: Timer?
    private var scriptRunning = false
    static let music = "com.apple.Music", vlc = "org.videolan.vlc", spotify = "com.spotify.client"

    private init() {
        updateBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBattery() }
        }
        // Music und Spotify senden ihren Status als verteilte Notification – ohne Berechtigung.
        let players = [("com.apple.Music.playerInfo", "com.apple.Music"),
                       ("com.spotify.client.PlaybackStateChanged", "com.spotify.client")]
        for (name, bundleID) in players {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.handlePlayer(info, bundleID: bundleID) }
            }
        }
        // Position nachführen: Music meldet sie nicht, VLC meldet gar nichts. Dazwischen rechnet die Ansicht selbst.
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMedia() }
        }
    }

    // Millisekunden als Ganzzahl – „as text“ einer Kommazahl hängt vom Gebietsschema ab.
    private static let musicScript = """
        tell application id "com.apple.Music" to if player state is not stopped then \
        return name of current track & "|" & ((player position * 1000) as integer) & "|" & ((duration of current track * 1000) as integer)
        """
    private static let vlcScript = """
        tell application id "org.videolan.vlc" to if playing then \
        return name of current item & "|" & (current time) & "|" & (duration of current item)
        """

    private func syncMedia() {
        guard !scriptRunning else { return }
        if nowPlaying?.playerBundleID == Self.music, nowPlaying?.isPlaying == true {
            scriptRunning = true
            PlayerScript.run(Self.music, Self.musicScript) { [weak self] out in
                guard let self else { return }
                self.scriptRunning = false
                guard let out, let r = PlayerScript.parse(out), self.nowPlaying?.playerBundleID == Self.music else { return }
                self.nowPlaying?.position = r.position / 1000
                self.nowPlaying?.duration = r.duration / 1000
                self.nowPlaying?.positionDate = Date()
            }
        } else if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.vlc).isEmpty {
            scriptRunning = true
            PlayerScript.run(Self.vlc, Self.vlcScript) { [weak self] out in
                guard let self else { return }
                self.scriptRunning = false
                if let out, let r = PlayerScript.parse(out) {
                    self.nowPlaying = NowPlaying(title: r.title, artist: "", isPlaying: true, playerBundleID: Self.vlc,
                                                 duration: r.duration, position: r.position)
                } else if self.nowPlaying?.playerBundleID == Self.vlc, self.nowPlaying?.isPlaying == true {
                    self.nowPlaying?.rebase(at: Date())
                    self.nowPlaying?.isPlaying = false
                }
            }
        } else if nowPlaying?.playerBundleID == Self.vlc {
            nowPlaying = nil
        }
    }

    private func handlePlayer(_ info: [AnyHashable: Any], bundleID: String) {
        let state = info["Player State"] as? String ?? "Stopped"
        if state == "Stopped" {
            if nowPlaying?.playerBundleID == bundleID { nowPlaying = nil }
            return
        }
        let ms = (info["Total Time"] ?? info["Duration"]) as? NSNumber
        var np = NowPlaying(title: info["Name"] as? String ?? "Unbekannt",
                            artist: info["Artist"] as? String ?? "",
                            isPlaying: state == "Playing",
                            playerBundleID: bundleID,
                            duration: ms.map { $0.doubleValue / 1000 },
                            position: (info["Playback Position"] as? NSNumber)?.doubleValue)
        // Music liefert keine Position: beim selben Titel weiterrechnen (Pause/Fortsetzen), dann nachfragen.
        if np.position == nil, var old = nowPlaying, old.playerBundleID == bundleID, old.title == np.title {
            old.rebase(at: np.positionDate)
            np.position = old.position
        }
        nowPlaying = np
        if bundleID == Self.music { syncMedia() }
    }

    // MARK: Cover-Farbe (Thema „Now Playing“)

    /// Liest das Cover des laufenden Titels (Music: Bilddaten in eine Temp-Datei, Spotify: Bild-URL) und
    /// mittelt seine Farbe. Läuft nur beim Thema „Now Playing“ und einmal je Titel.
    func refreshArtwork() {
        guard DockStore.shared.settings.theme == .nowPlaying, let np = nowPlaying else {
            if nowPlaying == nil { artworkKey = nil; if artworkColor != nil { artworkColor = nil } }
            return
        }
        let key = np.playerBundleID + "|" + np.title
        guard key != artworkKey else { return }
        artworkKey = key
        let finish: @MainActor (NSImage?) -> Void = { [weak self] img in
            guard let self, self.artworkKey == key else { return }
            self.artworkColor = img.flatMap(ArtworkColor.average).map(ArtworkColor.accent)
            // Fehlschlag (z. B. Erlaubnis noch nicht erteilt, Netz weg): beim nächsten Anstoß erneut versuchen.
            if self.artworkColor == nil { self.artworkKey = nil }
        }
        switch np.playerBundleID {
        case Self.music:
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pier-artwork-\(UUID().uuidString)")
            PlayerScript.run(Self.music, Self.musicArtworkScript(file.path)) { out in
                defer { try? FileManager.default.removeItem(at: file) }
                finish(out == "ok" ? NSImage(contentsOf: file) : nil)
            }
        case Self.spotify:
            PlayerScript.run(Self.spotify, "tell application id \"com.spotify.client\" to return artwork url of current track") { out in
                guard let out, let url = URL(string: out), url.scheme == "https" else { finish(nil); return }
                Task {
                    let data = try? await URLSession.shared.data(from: url).0
                    finish(data.flatMap(NSImage.init(data:)))
                }
            }
        default:
            finish(nil)
        }
    }

    private static func musicArtworkScript(_ path: String) -> String {
        """
        tell application id "com.apple.Music"
            if (count of artworks of current track) is 0 then return "none"
            set d to raw data of artwork 1 of current track
        end tell
        set f to open for access (POSIX file "\(path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """
    }

    func updateBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            battery = nil
            return
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let onPower = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let mins = (charging ? desc[kIOPSTimeToFullChargeKey] : (onPower ? nil : desc[kIOPSTimeToEmptyKey])) as? Int
            let new = BatteryState(level: Int((Double(cur) / Double(max) * 100).rounded()), charging: charging,
                                   onPower: onPower, minutes: mins.flatMap { $0 > 0 ? $0 : nil })
            if new != battery { battery = new }
            return
        }
        battery = nil
    }

    // MARK: Steuerung über Medientasten (geht an die App, die gerade spielt)

    func playPause() {
        MediaKeys.send(16)
        nowPlaying?.rebase(at: Date())
        nowPlaying?.isPlaying.toggle()
    }

    func next() { MediaKeys.send(17) }

    func openPlayer() {
        guard let id = nowPlaying?.playerBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        AppActions.launch(url)
    }
}

enum MediaKeys {
    static func send(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: Ansichten

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "HH:mm"
    return f
}()

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = "EEE, d. MMM"
    return f
}()

struct ClockWidget: View {
    var showDate: Bool
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .trailing, spacing: 0) {
                Text(timeFormatter.string(from: ctx.date))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                if showDate {
                    Text(dateFormatter.string(from: ctx.date))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .dockTextShadow()
        }
        .contentShape(Rectangle())
        .hoverPopup(.calendar)
    }
}

struct BatteryWidget: View {
    var state: BatteryState
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isLow ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            Text("\(state.level)%")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .dockTextShadow()
        }
        .fixedSize()
        .contentShape(Rectangle())
        .hoverPopup(.battery)
    }

    private var isLow: Bool { state.level <= 20 && !state.onPower }

    private var symbol: String {
        if state.charging || state.onPower { return "battery.100percent.bolt" }
        switch state.level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct NowPlayingWidget: View {
    @ObservedObject var model = WidgetModel.shared
    var compact: Bool

    var body: some View {
        if let np = model.nowPlaying {
            HStack(spacing: 8) {
                Button { model.playPause() } label: {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                }
                .buttonStyle(DockPressStyle())

                VStack(alignment: .leading, spacing: 0) {
                    Text(np.title)
                        .font(.system(size: 12, weight: .semibold))
                    if !compact && !np.artist.isEmpty {
                        Text(np.artist)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .dockTextShadow()
                .overlay(alignment: .bottom) { MediaProgressBar(bundleID: nil).offset(y: 5) }
                .frame(maxWidth: compact ? 110 : 160, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .onTapGesture { model.openPlayer() }

                if !compact {
                    Button { model.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(DockPressStyle())
                    .foregroundStyle(.secondary)
                }
            }
            .help(np.artist.isEmpty ? np.title : "\(np.title) – \(np.artist)")
        }
    }
}

/// Titelposition eines Players als dünner grüner Balken. `bundleID` nil = was gerade spielt.
struct MediaProgressBar: View {
    var bundleID: String?
    @ObservedObject var model = WidgetModel.shared

    var body: some View {
        if let np = model.nowPlaying, bundleID == nil || np.playerBundleID == bundleID, np.fraction(at: Date()) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let f = np.fraction(at: ctx.date) ?? 0
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(Color.green).frame(width: max(3, g.size.width * f))
                    }
                }
            }
            .frame(height: 3)
            .allowsHitTesting(false)
            .accessibilityLabel("Titelposition")
        }
    }
}

struct WidgetStrip: View {
    let settings: DockSettings
    var compact: Bool
    var vertical = false
    /// Die Leiste zeigt die Musik im Tab des Players.
    var hideNowPlaying = false
    @ObservedObject var model = WidgetModel.shared
    @ObservedObject var devices = DevicesModel.shared

    /// Die Geräte-Kachel erscheint nur, wenn es etwas zu zeigen gibt.
    private var showsDevices: Bool { settings.showDevices && (!devices.volumes.isEmpty || settings.showBluetooth) }

    var hasContent: Bool {
        settings.showClock || (settings.showBattery && model.battery != nil)
            || (settings.showNowPlaying && !hideNowPlaying && model.nowPlaying != nil) || settings.showSound || showsDevices
    }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: compact ? 12 : 18))
        layout {
            if settings.showNowPlaying && !hideNowPlaying { NowPlayingWidget(compact: compact) }
            if showsDevices {
                WidgetButton(symbol: devices.volumes.isEmpty ? "externaldrive.connected.to.line.below" : "externaldrive.fill",
                             help: "Geräte") { Coordinator.shared.toggleDevices(anchor: $0) }
            }
            if settings.showSound {
                WidgetButton(symbol: "speaker.wave.2.fill", help: "Ton-Ausgang und -Eingang") { Coordinator.shared.toggleSound(anchor: $0) }
            }
            if settings.showBattery, let b = model.battery { BatteryWidget(state: b) }
            if settings.showClock { ClockWidget(showDate: settings.showDate) }
        }
    }
}

// MARK: Cover-Farbe

enum ArtworkColor {
    /// Mittlere Farbe über alle Pixel eines Bildes (CIAreaAverage).
    static func average(_ image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let out = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci,
                                                                    kCIInputExtentKey: CIVector(cgRect: ci.extent)])?.outputImage,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: srgb])
            .render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// Als Akzent brauchbar machen: nicht zu dunkel, nicht zu hell, etwas kräftiger.
    static func accent(_ c: NSColor) -> NSColor {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.3), brightness: min(max(b, 0.55), 0.85), alpha: 1)
    }
}

/// Kleines Symbol im Widget-Bereich, das per Klick ein Popup öffnet.
struct WidgetButton: View {
    let symbol: String
    let help: String
    let action: (CGRect) -> Void
    @State private var rect: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        Button { action(rect) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
                .dockTextShadow()
        }
        .buttonStyle(DockPressStyle())
        .onHoverAlways { h, r in
            rect = r
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension View {
    /// Zeigt beim Darüberfahren ein Info-Popup (Kalender, Akku) über dem Dock.
    func hoverPopup(_ target: HoverTarget) -> some View {
        onHoverAlways { h, r in h ? Coordinator.shared.hoverBegan(target, rect: r) : Coordinator.shared.hoverEnded() }
    }
}

/// Abspielen/Pause und Weiter – im breiten Tab des Players in der Leiste.
struct MediaControls: View {
    @ObservedObject var model = WidgetModel.shared

    var body: some View {
        if let np = model.nowPlaying {
            HStack(spacing: 4) {
                Button { model.playPause() } label: {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                }
                .help(np.isPlaying ? "Pause" : "Abspielen")
                .accessibilityLabel(np.isPlaying ? "Pause" : "Abspielen")
                Button { model.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                }
                .foregroundStyle(.secondary)
                .help("Nächster Titel")
                .accessibilityLabel("Nächster Titel")
            }
            .buttonStyle(DockPressStyle())
        }
    }
}
