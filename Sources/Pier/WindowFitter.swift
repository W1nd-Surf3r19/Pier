import AppKit
import ApplicationServices

/// Hält Fenster über dem Dock: Wird ein Fenster so groß gemacht, dass es unter das Dock reicht
/// (Zoomen, „Füllen“, Ziehen am unteren Rand), kürzt Pier es bis zur Oberkante des Docks.
/// macOS erlaubt Drittanbietern nicht, Bildschirmplatz zu reservieren – das ist der Ersatz dafür.
@MainActor
final class WindowFitter {
    static let shared = WindowFitter()

    /// Höhe (in Punkten, ab Unterkante jedes Bildschirms mit Dock), die frei bleiben soll. 0 = aus.
    private(set) var reserved: CGFloat = 0
    /// Bildschirme (Cocoa-Rahmen), an deren Unterkante ein Pier-Dock sitzt.
    private(set) var screens: [NSRect] = []
    private var observers: [pid_t: AXObserver] = [:]

    /// Freigehaltene Höhe am unteren Rand dieses Bildschirms.
    func reserved(on screen: NSScreen) -> CGFloat { screens.contains(screen.frame) ? reserved : 0 }

    func update(reserved: CGFloat, screens: [NSRect], pids: [pid_t]) {
        let previous = self.reserved
        let changed = reserved != previous || screens != self.screens
        self.reserved = reserved
        self.screens = screens
        guard reserved > 0, AXIsProcessTrusted() else {
            removeAll()
            return
        }
        let wanted = Set(pids)
        for pid in observers.keys where !wanted.contains(pid) { remove(pid) }
        for pid in wanted where observers[pid] == nil { add(pid) }
        if changed { fitAll(pids: pids, previous: previous) }
    }

    /// Passt alle Fenster an. Fenster, die an der alten Grenze endeten, wandern mit zur neuen.
    func fitAll(pids: [pid_t], previous: CGFloat = 0) {
        guard reserved > 0 else { return }
        for pid in pids {
            for w in WindowService.windows(pid: pid) where !w.isMinimized { fit(w.element, followFrom: previous) }
        }
    }

    func fit(_ window: AXUIElement, followFrom previous: CGFloat = 0) {
        guard reserved > 0, let primary = NSScreen.screens.first else { return }
        let subrole: String? = value(window, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole as String else { return }
        if let full: Bool = value(window, "AXFullScreen"), full { return }
        if let min: Bool = value(window, kAXMinimizedAttribute), min { return }
        guard let pos = point(window), let size = size(window) else { return }

        // AX-Koordinaten: Ursprung oben links am Hauptbildschirm.
        guard let screenBottom = Self.dockedScreenBottom(windowOrigin: pos, screens: screens,
                                                         primaryHeight: primary.frame.height) else { return }
        let limit = screenBottom - reserved
        let bottom = pos.y + size.height
        let wasDocked = previous > 0 && abs(bottom - (screenBottom - previous)) <= 2
        guard bottom > limit + 1 || (wasDocked && abs(bottom - limit) > 1), pos.y < limit - 150 else { return }

        var newSize = CGSize(width: size.width, height: (limit - pos.y).rounded(.down))
        if let v = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }

    /// Unterkante (AX-y) des Dock-Bildschirms, auf dem die Titelleiste des Fensters liegt – sonst nil.
    nonisolated static func dockedScreenBottom(windowOrigin p: CGPoint, screens: [NSRect], primaryHeight: CGFloat) -> CGFloat? {
        let probe = CGPoint(x: p.x + 20, y: p.y + 10)
        for f in screens {
            let ax = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            if ax.contains(probe) { return ax.maxY }
        }
        return nil
    }

    // MARK: AX-Beobachter

    private func add(_ pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, fitterCallback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for n in [kAXWindowResizedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func remove(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func removeAll() {
        for pid in Array(observers.keys) { remove(pid) }
    }

    // MARK: Helfer

    private func value<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private func point(_ el: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success, let v else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private func size(_ el: AXUIElement) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success, let v else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}

private let fitterCallback: AXObserverCallback = { _, element, notification, _ in
    let isNew = (notification as String) == kAXWindowCreatedNotification
    // Neue Fenster bekommen ihre endgültige Größe oft erst kurz nach dem Erzeugen.
    DispatchQueue.main.asyncAfter(deadline: .now() + (isNew ? 0.25 : 0.05)) {
        WindowFitter.shared.fit(element)
    }
}
