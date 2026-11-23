import AppKit
import Darwin

/// CPU- und Speicherverbrauch laufender Apps – nur gemessen, solange ⌃ gehalten wird.
@MainActor
final class ActivityModel: ObservableObject {
    static let shared = ActivityModel()

    struct Stat: Equatable {
        var cpu: Double      // Prozent eines Kerns
        var memory: UInt64   // Bytes (physischer Footprint)
    }

    @Published private(set) var visible = false
    @Published private(set) var stats: [pid_t: Stat] = [:]

    private var last: [pid_t: (ticks: UInt64, at: UInt64)] = [:]
    private var timer: Timer?
    private var holdTimer: Timer?
    private var monitors: [Any] = []
    private let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    func start() {
        let handler: (NSEvent) -> Void = { e in MainActor.assumeIsolated { ActivityModel.shared.flagsChanged(e.modifierFlags) } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let onlyControl = flags.intersection(.deviceIndependentFlagsMask) == .control
        holdTimer?.invalidate()
        guard onlyControl, DockStore.shared.settings.showActivity else { return setVisible(false) }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated { ActivityModel.shared.setVisible(true) }
        }
    }

    private func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        timer?.invalidate()
        timer = nil
        last = [:]
        stats = [:]
        guard on else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ActivityModel.shared.sample() }
        }
    }

    private func sample() {
        let now = mach_absolute_time()
        var next: [pid_t: Stat] = [:]
        for app in RunningAppsModel.shared.apps {
            let pid = app.processIdentifier
            guard let u = Self.usage(pid) else { continue }
            let ticks = u.ri_user_time + u.ri_system_time
            var cpu = stats[pid]?.cpu ?? 0
            if let prev = last[pid], now > prev.at, ticks >= prev.ticks {
                cpu = Self.cpuPercent(deltaTicks: ticks - prev.ticks, deltaWall: now - prev.at,
                                      numer: timebase.numer, denom: timebase.denom)
            }
            last[pid] = (ticks, now)
            next[pid] = Stat(cpu: cpu, memory: u.ri_phys_footprint)
        }
        stats = next
    }

    /// CPU-Zeiten von proc_pid_rusage sind Mach-Ticks (auf Apple Silicon ≠ ns), die Wandzeit ebenso.
    nonisolated static func cpuPercent(deltaTicks: UInt64, deltaWall: UInt64, numer: UInt32, denom: UInt32) -> Double {
        guard deltaWall > 0 else { return 0 }
        let cpuNs = Double(deltaTicks) * Double(numer) / Double(denom)
        let wallNs = Double(deltaWall) * Double(numer) / Double(denom)
        return cpuNs / wallNs * 100
    }

    private static func usage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? info : nil
    }

    nonisolated static func cpuText(_ s: Stat) -> String { "\(Int(s.cpu.rounded())) %" }

    /// Kurz genug für einen 40-pt-Tab: „340 MB“, „1,2 GB“.
    nonisolated static func memoryText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1000 { return "\(Int(mb.rounded())) MB" }
        return (mb / 1024).formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}
