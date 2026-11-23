import AppKit
import Combine

enum RunState: Equatable {
    case none, running, active, launching
}

struct TaskItem: Identifiable, Equatable {
    let id: String
    let app: NSRunningApplication
    let window: WindowRef?
    let title: String
    let isActive: Bool
    /// Gemeinsamer Tab für mehrere Fenster (Fenstergruppierung): deren Anzahl, sonst nil.
    var groupedCount: Int? = nil
    /// Der Tab des Players, der gerade spielt: breiter, mit Titel und Steuerung statt eigenem Musik-Widget.
    var media = false
    var isMinimized: Bool { window?.isMinimized ?? false }
}

/// Beobachtet laufende Apps und (über Bedienungshilfen) deren Fenster.
@MainActor
final class RunningAppsModel: ObservableObject {
    static let shared = RunningAppsModel()

    @Published private(set) var apps: [NSRunningApplication] = []
    @Published private(set) var frontmostPID: pid_t = 0
    @Published private(set) var windows: [pid_t: [WindowRef]] = [:]
    @Published private(set) var onScreen: Set<CGWindowID> = []
    @Published private(set) var launching: Set<String> = []
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var progress: [String: Double] = [:]
    /// Apps, deren Badge gerade neu erschienen oder gestiegen ist – das Icon leuchtet kurz auf.
    @Published private(set) var attention: Set<String> = []
    /// Apps, die mehrmals in Folge nicht geantwortet haben („reagiert nicht“).
    @Published private(set) var hung: Set<pid_t> = []
    private var axFailures: [pid_t: Int] = [:]
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()

    private var timer: Timer?
    private var statusLoaded = false
    private var refreshing = false

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didLaunchApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self?.launching.remove(AppName.key(app))
                    }
                    self?.refresh()
                }
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let newApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if newApps.map(\.processIdentifier) != apps.map(\.processIdentifier) { apps = newApps }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if front != frontmostPID { frontmostPID = front }
        let ax = AXIsProcessTrusted()
        if ax != axTrusted { axTrusted = ax }
        let sr = CGPreflightScreenCaptureAccess()
        if sr != screenRecording { screenRecording = sr }
        refreshWindows()
    }

    private func refreshWindows() {
        guard axTrusted, !refreshing else { return }
        refreshing = true
        let pids = apps.map(\.processIdentifier)
        Task.detached(priority: .userInitiated) {
            let scan = WindowService.windows(for: pids)
            let status = WindowService.dockStatus()
            let onScreen = WindowService.onScreenWindowIDs()
            await MainActor.run {
                // Wer nicht antwortet, behält seine letzten Fenster – sonst fielen die Tabs gerade dann zusammen.
                var result = scan.windows
                for pid in scan.unresponsive { if let old = self.windows[pid] { result[pid] = old } }
                if result != self.windows { self.windows = result }
                // Startende Apps antworten oft noch nicht – sie zählen nicht als hängend.
                let settled = Set(self.apps.filter { ($0.launchDate ?? .distantPast).timeIntervalSinceNow < -10 }.map(\.processIdentifier))
                let h = Self.updateHung(failures: self.axFailures, unresponsive: scan.unresponsive.intersection(settled))
                self.axFailures = h.failures
                if h.hung != self.hung { self.hung = h.hung }
                if onScreen != self.onScreen { self.onScreen = onScreen }
                if status.badges != self.badges {
                    if self.statusLoaded { self.flashNewBadges(old: self.badges, new: status.badges) }
                    self.badges = status.badges
                }
                if status.progress != self.progress { self.progress = status.progress }
                self.statusLoaded = true
                self.refreshing = false
            }
        }
    }

    private func flashNewBadges(old: [String: String], new: [String: String]) {
        for (key, label) in new where Self.badgeRose(from: old[key], to: label) {
            attention.insert(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.attention.remove(key) }
        }
    }

    /// Neu erschienen oder Zahl gestiegen. Text-Badges (z. B. „•“) zählen nur beim Erscheinen.
    nonisolated static func badgeRose(from old: String?, to new: String) -> Bool {
        guard let old else { return true }
        if let o = Int(old), let n = Int(new) { return n > o }
        return false
    }

    /// Erst nach `threshold` Fehlversuchen in Folge gilt eine App als hängend; jede Antwort setzt zurück.
    nonisolated static func updateHung(failures: [pid_t: Int], unresponsive: Set<pid_t>,
                                       threshold: Int = 4) -> (failures: [pid_t: Int], hung: Set<pid_t>) {
        var next: [pid_t: Int] = [:]
        for pid in unresponsive { next[pid] = (failures[pid] ?? 0) + 1 }
        return (next, Set(next.filter { $0.value >= threshold }.keys))
    }

    // MARK: Abfragen

    func isHung(_ key: String) -> Bool {
        app(forKey: key).map { hung.contains($0.processIdentifier) } ?? false
    }

    func isLaunching(_ key: String) -> Bool { launching.contains(key) }

    /// Name mit Status für Tooltips, z. B. „Nachrichten · 3“ oder „Xcode · reagiert nicht“.
    func label(_ name: String, key: String?) -> String {
        guard let key else { return name }
        var parts = [name]
        if DockStore.shared.settings.showBadges, let b = badges[key] { parts.append(b) }
        if isHung(key) { parts.append("reagiert nicht") }
        return parts.joined(separator: " · ")
    }

    /// Fenster einer App, wie Pier sie zeigt: auf Wunsch nur die des aktuellen Schreibtischs.
    /// Minimierte Fenster und Fenster ausgeblendeter Apps liegen nie auf dem Bildschirm – sie bleiben drin.
    func shownWindows(of app: NSRunningApplication) -> [WindowRef] {
        let all = windows[app.processIdentifier] ?? []
        guard DockStore.shared.settings.currentSpaceOnly, !app.isHidden else { return all }
        return all.filter { $0.isMinimized || $0.windowID == 0 || onScreen.contains($0.windowID) }
    }

    func app(forKey key: String) -> NSRunningApplication? {
        apps.first { AppName.key($0) == key || $0.bundleURL?.standardizedFileURL.path == key }
    }

    func state(forKey key: String) -> RunState {
        if launching.contains(key) { return .launching }
        guard let app = app(forKey: key) else { return .none }
        return app.processIdentifier == frontmostPID && !app.isHidden ? .active : .running
    }

    func windows(forKey key: String) -> [WindowRef] {
        guard let app = app(forKey: key) else { return [] }
        return shownWindows(of: app)
    }

    func hasVisibleWindows(_ app: NSRunningApplication) -> Bool {
        guard axTrusted else { return true }
        return (windows[app.processIdentifier] ?? []).contains { !$0.isMinimized }
    }

    func markLaunching(_ key: String) {
        launching.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.launching.remove(key) }
    }

    /// Laufende Apps, die nicht direkt im Dock angepinnt sind.
    func unpinnedApps(pinned: Set<String>) -> [NSRunningApplication] {
        otherApps.filter { !pinned.contains(AppName.key($0)) }
    }

    /// Tabs einer App für die Leiste: ein Tab pro Fenster, ohne Fenster ein App-Tab.
    /// `grouped`: mehrere Fenster teilen sich einen Tab.
    func tasks(for app: NSRunningApplication, grouped: Bool = false) -> [TaskItem] {
        let key = AppName.key(app)
        let name = app.localizedName ?? "App"
        let isFront = app.processIdentifier == frontmostPID && !app.isHidden
        let wins = shownWindows(of: app)
        if wins.isEmpty {
            return [TaskItem(id: "a-\(key)", app: app, window: nil, title: name, isActive: isFront)]
        }
        if grouped, wins.count > 1 {
            return [TaskItem(id: "g-\(key)", app: app, window: nil, title: name, isActive: isFront, groupedCount: wins.count)]
        }
        return wins.map { w in
            TaskItem(id: w.id, app: app, window: w, title: w.title.isEmpty ? name : w.title,
                     isActive: isFront && w.isFocused)
        }
    }

    /// Alle laufenden Apps außer Pier selbst und den ausgeschlossenen, in der gewählten Reihenfolge.
    var otherApps: [NSRunningApplication] {
        let s = DockStore.shared.settings
        let list = apps.filter { $0.bundleURL?.lastPathComponent != "Pier.app" && s.excludedApps[AppName.key($0)] == nil }
        return Self.ordered(list, by: s.runningOrder, name: { $0.localizedName ?? "" }, launched: \.launchDate)
    }

    /// Nach Startzeit (älteste zuerst) oder alphabetisch; bei Gleichstand bleibt die bisherige Reihenfolge.
    nonisolated static func ordered<T>(_ items: [T], by order: RunningOrder, name: (T) -> String, launched: (T) -> Date?) -> [T] {
        items.enumerated().sorted { a, b in
            switch order {
            case .launch:
                let da = launched(a.element) ?? .distantPast, db = launched(b.element) ?? .distantPast
                return da != db ? da < db : a.offset < b.offset
            case .alphabetical:
                let r = name(a.element).localizedStandardCompare(name(b.element))
                return r != .orderedSame ? r == .orderedAscending : a.offset < b.offset
            }
        }.map(\.element)
    }
}

enum AppActions {
    static func launch(_ url: URL) {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: c)
    }

    /// Holt eine App nach vorne. Wie beim Mac-Dock: hat sie kein Fenster, öffnet sie eins.
    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if let url = app.bundleURL {
            launch(url)
        } else {
            app.activate()
        }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
