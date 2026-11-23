import AppKit
import IOKit.ps
import SwiftUI

struct BatteryState: Equatable {
    var level: Int
    var charging: Bool
    var onPower: Bool
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
    @Published private(set) var nowPlaying: NowPlaying?

    private var timer: Timer?
    private var mediaTimer: Timer?
    private var scriptRunning = false
    static let music = "com.apple.Music", vlc = "org.videolan.vlc"

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
            let new = BatteryState(level: Int((Double(cur) / Double(max) * 100).rounded()),
                                   charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                                   onPower: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
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
        .help(state.charging ? "Lädt" : (state.onPower ? "Am Netzteil" : "Batterie"))
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
    @ObservedObject var model = WidgetModel.shared

    var hasContent: Bool {
        settings.showClock || (settings.showBattery && model.battery != nil)
            || (settings.showNowPlaying && model.nowPlaying != nil)
    }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: compact ? 12 : 18))
        layout {
            if settings.showNowPlaying { NowPlayingWidget(compact: compact) }
            if settings.showBattery, let b = model.battery { BatteryWidget(state: b) }
            if settings.showClock { ClockWidget(showDate: settings.showDate) }
        }
    }
}
