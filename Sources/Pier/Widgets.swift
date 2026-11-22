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
}

@MainActor
final class WidgetModel: ObservableObject {
    static let shared = WidgetModel()

    @Published private(set) var battery: BatteryState?
    @Published private(set) var nowPlaying: NowPlaying?

    private var timer: Timer?

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
    }

    private func handlePlayer(_ info: [AnyHashable: Any], bundleID: String) {
        let state = info["Player State"] as? String ?? "Stopped"
        if state == "Stopped" {
            if nowPlaying?.playerBundleID == bundleID { nowPlaying = nil }
            return
        }
        nowPlaying = NowPlaying(title: info["Name"] as? String ?? "Unbekannt",
                                artist: info["Artist"] as? String ?? "",
                                isPlaying: state == "Playing",
                                playerBundleID: bundleID)
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

struct WidgetStrip: View {
    let settings: DockSettings
    var compact: Bool
    @ObservedObject var model = WidgetModel.shared

    var hasContent: Bool {
        settings.showClock || (settings.showBattery && model.battery != nil)
            || (settings.showNowPlaying && model.nowPlaying != nil)
    }

    var body: some View {
        HStack(spacing: compact ? 12 : 18) {
            if settings.showNowPlaying { NowPlayingWidget(compact: compact) }
            if settings.showBattery, let b = model.battery { BatteryWidget(state: b) }
            if settings.showClock { ClockWidget(showDate: settings.showDate) }
        }
    }
}
