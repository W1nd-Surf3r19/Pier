import AppKit
import Combine

@main
enum PierMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = DockStore.shared
        if store.settings.hideSystemDock { SystemDock.hide() }

        Coordinator.shared.start()
        store.$settings
            .removeDuplicates()
            .dropFirst()
            .sink { Coordinator.shared.apply($0) }
            .store(in: &cancellables)

        installSignalHandlers()

        if !Permissions.accessibility { Permissions.requestAccessibility() }
        if store.isFirstLaunch { SettingsWindowController.shared.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageTracker.shared.closeSession(reopen: false)
        DockStore.shared.save()
        SystemDock.restore()
    }

    /// Auch bei `kill`/`killall Pier` das Mac-Dock wiederherstellen.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }
}
