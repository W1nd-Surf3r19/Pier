import AppKit

/// Verbindet Dock, Popups, Launcher und Einstellungen. Die Views rufen hierüber Aktionen auf.
@MainActor
final class Coordinator {
    static let shared = Coordinator()

    private(set) var dock: DockController!
    private(set) var popup: PopupController!
    private(set) var launcher: LauncherController!
    private var hotKey: HotKey?
    private var current: DockSettings?

    private let store = DockStore.shared
    private let running = RunningAppsModel.shared

    func start() {
        _ = WidgetModel.shared
        dock = DockController()
        popup = PopupController()
        launcher = LauncherController()
        apply(store.settings)
        dock.show()
    }

    func apply(_ s: DockSettings) {
        let previous = current
        current = s
        for p in [dock.panel, popup.panel, launcher.panel] as [NSPanel] { p.appearance = s.appearance.nsAppearance }
        dock.apply(s)
        popup.hide()
        if let previous, previous.hideSystemDock != s.hideSystemDock {
            s.hideSystemDock ? SystemDock.hide() : SystemDock.restore()
        }
        if s.launcherHotKey, hotKey == nil {
            hotKey = HotKey { Coordinator.shared.toggleLauncher() }
        } else if !s.launcherHotKey {
            hotKey = nil
        }
    }

    // MARK: Aktionen aus den Views

    func openSettings() {
        popup.hide()
        launcher.hide()
        SettingsWindowController.shared.show()
    }

    func toggleLauncher() {
        popup.hide()
        launcher.toggle()
    }

    func hoverBegan(_ target: HoverTarget, rect: CGRect) { popup.hoverBegan(target, anchor: rect) }
    func hoverEnded() { popup.hoverEnded() }

    func toggleFolder(_ folder: DockFolder, anchor: CGRect) { popup.toggleFolder(folder, anchor: anchor) }

    func clickApp(key: String, url: URL?) {
        popup.hide()
        if let app = running.app(forKey: key) {
            let isFront = app.processIdentifier == running.frontmostPID && !app.isHidden
            if isFront && store.settings.clickHidesActiveApp && running.hasVisibleWindows(app) {
                app.hide()
            } else {
                AppActions.activate(app)
            }
        } else if let url {
            running.markLaunching(key)
            AppActions.launch(url)
        }
    }

    func launchFromFolder(_ app: PinnedApp) {
        popup.hide()
        clickApp(key: app.key, url: app.url)
    }

    func clickTask(_ item: TaskItem) {
        popup.hide()
        guard let w = item.window else {
            clickApp(key: AppName.key(item.app), url: item.app.bundleURL)
            return
        }
        if item.isActive && !w.isMinimized {
            WindowService.minimize(w)
        } else {
            focusWindow(w)
        }
    }

    func focusWindow(_ w: WindowRef) {
        popup.hide()
        WindowService.raise(w)
        guard let app = NSRunningApplication(processIdentifier: w.pid) else { return }
        if app.isHidden { app.unhide() }
        app.activate()
        // Kooperative Aktivierung (macOS 14+) kann den Aufruf ignorieren – dann über LaunchServices.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != w.pid {
                AppActions.activate(app)
                WindowService.raise(w)
            }
        }
    }
}
