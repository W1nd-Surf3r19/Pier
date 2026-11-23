import AppKit
import ApplicationServices

/// Hält Fenster aus dem Dock heraus: Wird ein Fenster so groß gemacht, dass es unter das Dock reicht
/// (Zoomen, „Füllen“, Ziehen am Rand), kürzt bzw. verschiebt Pier es bis an den Rand des Docks.
/// macOS erlaubt Drittanbietern nicht, Bildschirmplatz zu reservieren – das ist der Ersatz dafür.
@MainActor
final class WindowFitter {
    static let shared = WindowFitter()

    /// Dicke (in Punkten, ab der Kante jedes Bildschirms mit Dock), die frei bleiben soll. 0 = aus.
    private(set) var reserved: CGFloat = 0
    private(set) var edge: DockEdge = .bottom
    /// Bildschirme (Cocoa-Rahmen), an deren Kante ein Pier-Dock sitzt.
    private(set) var screens: [NSRect] = []
    private var observers: [pid_t: AXObserver] = [:]

    /// Freier Bereich (Cocoa) eines Bildschirms: sichtbarer Bereich ohne den Streifen des Docks.
    func freeArea(on screen: NSScreen) -> NSRect {
        var a = screen.visibleFrame
        guard reserved > 0, screens.contains(screen.frame) else { return a }
        let sf = screen.frame
        switch edge {
        case .bottom: let top = a.maxY; a.origin.y = max(a.minY, sf.minY + reserved); a.size.height = top - a.minY
        case .top: a.size.height = max(0, a.height - reserved)   // reserved = Dicke unter der Menüleiste
        case .left: let right = a.maxX; a.origin.x = max(a.minX, sf.minX + reserved); a.size.width = right - a.minX
        case .right: a.size.width = min(a.maxX, sf.maxX - reserved) - a.minX
        }
        return a
    }

    func update(reserved: CGFloat, edge: DockEdge, screens: [NSRect], pids: [pid_t]) {
        // Mitwandern nur an derselben Kante – sonst läse man die alte Höhe als neue linke Grenze.
        let previous: CGFloat? = edge == self.edge && self.reserved > 0 ? self.reserved : nil
        let changed = reserved != self.reserved || edge != self.edge || screens != self.screens
        self.reserved = reserved
        self.edge = edge
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
    func fitAll(pids: [pid_t], previous: CGFloat? = nil) {
        guard reserved > 0 else { return }
        for pid in pids {
            for w in WindowService.windows(pid: pid) where !w.isMinimized { fit(w.element, followFrom: previous) }
        }
    }

    func fit(_ window: AXUIElement, followFrom previous: CGFloat? = nil) {
        guard reserved > 0, let primary = NSScreen.screens.first else { return }
        let subrole: String? = value(window, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole as String else { return }
        if let full: Bool = value(window, "AXFullScreen"), full { return }
        if let min: Bool = value(window, kAXMinimizedAttribute), min { return }
        guard let pos = point(window), let size = size(window) else { return }

        // AX-Koordinaten: Ursprung oben links am Hauptbildschirm.
        guard var ax = Self.dockedScreen(windowOrigin: pos, screens: screens, primaryHeight: primary.frame.height) else { return }
        // Oben zählt der Streifen ab der Menüleiste dieses Bildschirms (Notch-Bildschirme haben eine höhere).
        if edge == .top { ax = ax.inset(by: menuBar(ofAX: ax, primaryHeight: primary.frame.height)) }
        guard let target = Self.fittedFrame(CGRect(origin: pos, size: size), screen: ax, edge: edge,
                                            reserved: reserved, previous: previous) else { return }
        if target.width > size.width || target.height > size.height {
            // Wächst das Fenster (Leiste wurde schmaler), erst verschieben – sonst ragte es über den anderen Rand.
            WindowService.setOrigin(window, target.origin)
            WindowService.setSize(window, target.size)
            return
        }
        // Schrumpft es: erst verkleinern, dann verschieben – sonst ragt es kurz über den Rand und macOS klemmt es.
        WindowService.setSize(window, target.size)
        guard target.origin != pos else { return }
        // Lehnt die App das Verkleinern ab, nur so weit verschieben, dass es noch auf den Bildschirm passt.
        let actual = self.size(window) ?? target.size
        var origin = target.origin
        if edge == .top { origin.y = max(ax.minY, min(origin.y, ax.maxY - actual.height)) }
        if edge == .left { origin.x = max(ax.minX, min(origin.x, ax.maxX - actual.width)) }
        WindowService.setOrigin(window, origin)
    }

    /// Fenster wurde verschoben: Nur bei der Leiste oben eingreifen – dort verschwände sonst die Titelleiste
    /// unter der Leiste und ließe sich nicht mehr greifen. An den anderen Kanten darf man Fenster bewusst darunter schieben.
    func moved(_ window: AXUIElement) {
        guard reserved > 0, edge == .top, let primary = NSScreen.screens.first, let pos = point(window),
              let ax = Self.dockedScreen(windowOrigin: pos, screens: screens, primaryHeight: primary.frame.height) else { return }
        let limit = ax.minY + menuBar(ofAX: ax, primaryHeight: primary.frame.height).top + reserved
        if pos.y < limit - 1 { WindowService.setOrigin(window, CGPoint(x: pos.x, y: limit)) }
    }

    /// Höhe der Menüleiste des Bildschirms mit diesem AX-Rahmen.
    private func menuBar(ofAX ax: CGRect, primaryHeight: CGFloat) -> NSEdgeInsets {
        let cocoa = NSRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
        guard let s = NSScreen.screens.first(where: { $0.frame == cocoa }) else { return NSEdgeInsets() }
        return NSEdgeInsets(top: s.frame.maxY - s.visibleFrame.maxY, left: 0, bottom: 0, right: 0)
    }

    /// Neuer Rahmen (AX) für ein Fenster, das in den Streifen des Docks ragt – oder nil, wenn nichts zu tun ist.
    /// `previous`: alte Dicke an derselben Kante; Fenster, die dort bündig endeten, wandern mit (auch nach außen).
    nonisolated static func fittedFrame(_ w: CGRect, screen ax: CGRect, edge: DockEdge,
                                        reserved: CGFloat, previous: CGFloat?) -> CGRect? {
        let minKeep: CGFloat = 150
        switch edge {
        case .bottom:
            let limit = ax.maxY - reserved
            let docked = previous.map { abs(w.maxY - (ax.maxY - $0)) <= 2 } ?? false
            guard w.maxY > limit + 1 || (docked && abs(w.maxY - limit) > 1), w.minY < limit - minKeep else { return nil }
            return CGRect(x: w.minX, y: w.minY, width: w.width, height: (limit - w.minY).rounded(.down))
        case .right:
            let limit = ax.maxX - reserved
            let docked = previous.map { abs(w.maxX - (ax.maxX - $0)) <= 2 } ?? false
            guard w.maxX > limit + 1 || (docked && abs(w.maxX - limit) > 1), w.minX < limit - minKeep else { return nil }
            return CGRect(x: w.minX, y: w.minY, width: (limit - w.minX).rounded(.down), height: w.height)
        case .top:
            let limit = ax.minY + reserved
            let docked = previous.map { abs(w.minY - (ax.minY + $0)) <= 2 } ?? false
            guard w.minY < limit - 1 || (docked && abs(w.minY - limit) > 1), w.maxY > limit + minKeep else { return nil }
            return CGRect(x: w.minX, y: limit, width: w.width, height: (w.maxY - limit).rounded(.down))
        case .left:
            let limit = ax.minX + reserved
            let docked = previous.map { abs(w.minX - (ax.minX + $0)) <= 2 } ?? false
            guard w.minX < limit - 1 || (docked && abs(w.minX - limit) > 1), w.maxX > limit + minKeep else { return nil }
            return CGRect(x: limit, y: w.minY, width: (w.maxX - limit).rounded(.down), height: w.height)
        }
    }

    /// Rahmen (AX) des Dock-Bildschirms, auf dem die Titelleiste des Fensters liegt – sonst nil.
    nonisolated static func dockedScreen(windowOrigin p: CGPoint, screens: [NSRect], primaryHeight: CGFloat) -> CGRect? {
        let probe = CGPoint(x: p.x + 20, y: p.y + 10)
        for f in screens {
            let ax = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            if ax.contains(probe) { return ax }
        }
        return nil
    }

    // MARK: AX-Beobachter

    private func add(_ pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, fitterCallback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for n in [kAXWindowResizedNotification, kAXWindowCreatedNotification, kAXWindowMovedNotification] {
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
    let name = notification as String
    let isNew = name == kAXWindowCreatedNotification
    // Neue Fenster bekommen ihre endgültige Größe oft erst kurz nach dem Erzeugen.
    DispatchQueue.main.asyncAfter(deadline: .now() + (isNew ? 0.25 : 0.05)) {
        if name == kAXWindowMovedNotification { WindowFitter.shared.moved(element) } else { WindowFitter.shared.fit(element) }
    }
}
