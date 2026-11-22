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
    @Published private(set) var launching: Set<String> = []
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()

    private var timer: Timer?
    private var refreshing = false

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
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
            await MainActor.run {
                if result != self.windows { self.windows = result }
                self.refreshing = false
            }
        }
    }

    // MARK: Abfragen

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
        return windows[app.processIdentifier] ?? []
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
        apps.filter { !pinned.contains(AppName.key($0)) && $0.bundleURL?.lastPathComponent != "Pier.app" }
    }

    /// Einträge der Fensterleiste (Leisten-Stil): ein Eintrag pro Fenster.
    func taskItems(pinned: Set<String>) -> [TaskItem] {
        var items: [TaskItem] = []
        for app in apps where app.bundleURL?.lastPathComponent != "Pier.app" {
            let key = AppName.key(app)
            let name = app.localizedName ?? "App"
            let isFront = app.processIdentifier == frontmostPID && !app.isHidden
            let wins = windows[app.processIdentifier] ?? []
            if wins.isEmpty {
                if !axTrusted || !pinned.contains(key) {
                    items.append(TaskItem(id: "a-\(key)", app: app, window: nil, title: name, isActive: isFront))
                }
            } else {
                for w in wins {
                    items.append(TaskItem(id: w.id, app: app, window: w,
                                          title: w.title.isEmpty ? name : w.title,
                                          isActive: isFront && w.isFocused))
                }
            }
        }
        return items
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
