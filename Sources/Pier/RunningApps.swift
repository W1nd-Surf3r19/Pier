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
            let result = WindowService.windows(for: pids)
            let status = WindowService.dockStatus()
            let onScreen = WindowService.onScreenWindowIDs()
            await MainActor.run {
                if result != self.windows { self.windows = result }
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

    // MARK: Abfragen

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
    func tasks(for app: NSRunningApplication) -> [TaskItem] {
        let key = AppName.key(app)
        let name = app.localizedName ?? "App"
        let isFront = app.processIdentifier == frontmostPID && !app.isHidden
        let wins = shownWindows(of: app)
        if wins.isEmpty {
            return [TaskItem(id: "a-\(key)", app: app, window: nil, title: name, isActive: isFront)]
        }
        return wins.map { w in
            TaskItem(id: w.id, app: app, window: w, title: w.title.isEmpty ? name : w.title,
                     isActive: isFront && w.isFocused)
        }
    }

    /// Alle laufenden Apps außer Pier selbst und den ausgeschlossenen.
    var otherApps: [NSRunningApplication] {
        let excluded = DockStore.shared.settings.excludedApps
        return apps.filter { $0.bundleURL?.lastPathComponent != "Pier.app" && excluded[AppName.key($0)] == nil }
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
