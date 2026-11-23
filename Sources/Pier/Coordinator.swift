import AppKit
import Carbon
import Combine

/// Verbindet Dock, Popups, Launcher und Einstellungen. Die Views rufen hierüber Aktionen auf.
@MainActor
final class Coordinator {
    static let shared = Coordinator()

    /// Ein Dock pro gewähltem Bildschirm, das des Hauptbildschirms zuerst.
    private(set) var docks: [DockController] = []
    var dock: DockController { docks[0] }   // syncDocks lässt die Liste nie leer
    private var screenObserver: NSObjectProtocol?
    private(set) var popup: PopupController!
    private(set) var launcher: LauncherController!
    private(set) var altTab: AltTabController!
    private var hotKey: HotKey?
    private var appHotKeys: [HotKey] = []
    private var current: DockSettings?
    private var appsSub: AnyCancellable?
    private var scrollMonitor: Any?
    private var hovered: HoverTarget?
    private var scrollAccum: CGFloat = 0
    /// Feste Reihenfolge fürs Blättern – die AX-Liste sortiert sich nach jedem Nach-vorne-Holen um.
    private var cycle: (windows: [WindowRef], index: Int)?

    private let store = DockStore.shared
    private let running = RunningAppsModel.shared

    func start() {
        _ = WidgetModel.shared
        ActivityModel.shared.start()
        UsageTracker.shared.start()
        popup = PopupController()
        launcher = LauncherController()
        altTab = AltTabController()
        syncDocks(store.settings)
        apply(store.settings)
        updateWindowFitter()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            MainActor.assumeIsolated {
                if Coordinator.shared.isDockPanel(e.window) { Coordinator.shared.scrolled(e) }
            }
            return e
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = Coordinator.shared
                c.syncDocks(c.store.settings)
                c.updateWindowFitter()
            }
        }
        appsSub = running.$apps.dropFirst().sink { _ in
            DispatchQueue.main.async { Coordinator.shared.updateWindowFitter() }
        }
    }

    func apply(_ s: DockSettings) {
        let previous = current
        current = s
        if previous?.allScreens != s.allScreens || previous?.screenUUID != s.screenUUID { syncDocks(s) }
        if s.theme == .nowPlaying { WidgetModel.shared.refreshArtwork() }
        for p in docks.map(\.panel) + [popup.panel, launcher.panel, altTab.panel] as [NSPanel] {
            p.appearance = s.appearance.nsAppearance
        }
        docks.forEach { $0.apply(s) }
        popup.hide()
        if let previous, previous.hideSystemDock != s.hideSystemDock {
            s.hideSystemDock ? SystemDock.hide() : SystemDock.restore()
        }
        updateWindowFitter()
        WindowSnapper.shared.setEnabled(s.titlebarScroll)
        altTab.setEnabled(s.altTab)
        if s.launcherHotKey, hotKey == nil {
            hotKey = HotKey { Coordinator.shared.toggleLauncher() }
        } else if !s.launcherHotKey {
            hotKey = nil
        }
        if s.appHotKeys != !appHotKeys.isEmpty {
            appHotKeys = s.appHotKeys ? Self.digitKeys.enumerated().map { i, code in
                HotKey(keyCode: code, modifiers: UInt32(controlKey | optionKey)) { Coordinator.shared.activatePinned(at: i) }
            } : []
        }
    }

    /// Tastencodes der Ziffern 1–9 (physische Position, auf deutscher Tastatur gleich).
    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map(UInt32.init)

    /// ⌃⌥1–9: n-te angepinnte App (Ordner zählen nicht) starten, nach vorne holen oder ausblenden.
    func activatePinned(at index: Int) {
        let apps = store.entries.compactMap { if case .app(let a) = $0 { a } else { nil } }
        guard apps.indices.contains(index) else { return }
        clickApp(key: apps[index].key, url: apps[index].url)
    }

    /// Sofort beenden nur nach Rückfrage – ungesicherte Arbeit geht dabei verloren.
    func forceQuit(_ app: NSRunningApplication) {
        popup.hide()
        let alert = NSAlert()
        alert.messageText = "„\(app.localizedName ?? "App")“ sofort beenden?"
        alert.informativeText = "Nicht gesicherte Änderungen gehen verloren."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sofort beenden")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { app.forceTerminate() }
    }

    // MARK: Anpinnen & Ziehen

    func pin(_ url: URL) { store.addApps([url]) }

    func unpin(key: String) {
        guard let entry = store.entries.first(where: { if case .app(let a) = $0 { a.key == key } else { false } }) else { return }
        store.removeEntry(entry.id)
    }

    /// Aufs Dock gezogene Programme werden angepinnt. Auf freier Dock-Fläche werden Ordner zu Stapeln und
    /// andere Dateien angepinnt; auf einer App öffnet sie die Dateien.
    @discardableResult
    func drop(_ urls: [URL], onto appURL: URL?) -> Bool {
        let apps = urls.filter { $0.pathExtension == "app" }
        let dirs = urls.filter { $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if !apps.isEmpty, apps.count == urls.count {
            store.addApps(apps)
            return true
        }
        if appURL == nil, !urls.isEmpty {
            // Web-Links (z. B. ein Tab aus Safari) sind keine Dateien – nicht anpinnen.
            guard urls.allSatisfy(\.isFileURL) else { return false }
            store.addApps(apps)
            store.addStacks(dirs)
            store.addFiles(urls.filter { !apps.contains($0) && !dirs.contains($0) })
            return true
        }
        guard let appURL, !urls.isEmpty else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    // MARK: Bildschirme

    /// Legt Docks für neue Bildschirme an und räumt die abgesteckter (oder abgewählter) ab.
    func syncDocks(_ s: DockSettings) {
        // Gewählter Bildschirm; ist er nicht angeschlossen, der Hauptbildschirm.
        let chosen = NSScreen.screens.first { s.screenUUID != nil && $0.uuid == s.screenUUID } ?? NSScreen.screens.first
        let screens = s.allScreens ? NSScreen.screens : (chosen.map { [$0] } ?? [])
        var wanted = screens.map(\.displayID)
        // Beim Zuklappen/Display-Schlaf meldet macOS kurz keine Bildschirme – dann nichts abbauen.
        if wanted.isEmpty {
            guard docks.isEmpty else { return }
            wanted = [CGMainDisplayID()]
        }
        for d in docks where !wanted.contains(d.displayID) { d.close() }
        var next: [DockController] = []
        for id in wanted {
            if let d = docks.first(where: { $0.displayID == id }) {
                next.append(d)
            } else {
                let d = DockController(displayID: id)
                d.panel.appearance = s.appearance.nsAppearance
                d.apply(s)
                d.show()
                next.append(d)
            }
        }
        docks = next
        popup?.hide()
    }

    /// Während am Griff gezogen wird, nur die Leiste anpassen; Fenster erst beim Loslassen (fitAll ist teuer).
    private var resizingBar = false

    func resizeBar(rows: Int, done: Bool) {
        resizingBar = !done
        if store.settings.barRows != rows { store.settings.barRows = rows }
        if done { updateWindowFitter() }
    }

    func dockMoved(_ w: NSWindow) {
        docks.first { $0.panel === w }?.movedByUser()
    }

    func isDockPanel(_ w: NSWindow?) -> Bool {
        guard let w else { return false }
        return docks.contains { $0.panel === w }
    }

    /// Das Dock, zu dem ein Icon-Rechteck (Bildschirmkoordinaten) gehört.
    func dock(containing rect: CGRect) -> DockController {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        return docks.first { $0.panel.frame.insetBy(dx: -4, dy: -4).contains(mid) }
            ?? docks.first { $0.screen?.frame.contains(mid) == true }
            ?? dock
    }

    /// Freizuhaltender Streifen = wie weit das Dock (+ kleiner Abstand bei der Pille) in jeden Bildschirm mit Dock ragt.
    /// Die Leiste an jeder Kante, die Pille nur unten (sonst schrumpften plötzlich Fenster bei seitlicher Pille).
    func updateWindowFitter() {
        guard let s = current, !resizingBar else { return }
        var reserved: CGFloat = 0
        if s.fitWindows && !s.autoHide && !s.isFree && (s.style == .bar || s.effectiveEdge == .bottom) {
            reserved = dock.reservedThickness
        }
        WindowFitter.shared.update(reserved: reserved, edge: s.effectiveEdge, screens: docks.compactMap { $0.screen?.frame },
                                   pids: running.apps.map(\.processIdentifier))
    }

    // MARK: Aktionen aus den Views

    func openArrange() {
        popup.hide()
        launcher.hide()
        SettingsWindowController.shared.show(tab: .apps, arrange: true)
    }

    func openSettings() {
        popup.hide()
        launcher.hide()
        SettingsWindowController.shared.show()
    }

    func toggleLauncher() {
        popup.hide()
        launcher.toggle()
    }

    func hoverBegan(_ target: HoverTarget, rect: CGRect) {
        if hovered != target { cycle = nil; scrollAccum = 0 }
        hovered = target
        popup.hoverBegan(target, anchor: rect)
    }

    func hoverEnded() {
        hovered = nil
        cycle = nil
        popup.hoverEnded()
    }

    /// Scrollen über einem App-Icon oder Fenster-Tab holt reihum das nächste Fenster der App nach vorne.
    private func scrolled(_ e: NSEvent) {
        guard store.settings.scrollCyclesWindows, e.momentumPhase.isEmpty, let hovered else { return }
        scrollAccum += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10
        guard abs(scrollAccum) >= 30 else { return }
        let step = scrollAccum > 0 ? -1 : 1
        scrollAccum = 0
        if cycle == nil {
            let wins: [WindowRef]
            switch hovered {
            case .app(let key, _): wins = running.windows(forKey: key)
            case .window(let w): wins = NSRunningApplication(processIdentifier: w.pid).map(running.shownWindows) ?? []
            case .label, .calendar, .battery: return
            }
            guard !wins.isEmpty else { return }
            let current = wins.firstIndex { $0.isFocused && $0.pid == running.frontmostPID } ?? -step
            cycle = (wins, current)
        }
        guard var c = cycle else { return }
        c.index = ((c.index + step) % c.windows.count + c.windows.count) % c.windows.count
        cycle = c
        focusWindow(c.windows[c.index])
    }

    func toggleFolder(_ folder: DockFolder, anchor: CGRect) { popup.toggleFolder(folder, anchor: anchor) }
    func toggleStack(_ stack: DockStack, anchor: CGRect) { popup.toggleStack(stack, anchor: anchor) }
    func toggleSound(anchor: CGRect) { popup.toggleSound(anchor: anchor) }
    func toggleDevices(anchor: CGRect) { popup.toggleDevices(anchor: anchor) }

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

    func openFile(_ file: DockFile) {
        popup.hide()
        NSWorkspace.shared.open(file.url)
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
