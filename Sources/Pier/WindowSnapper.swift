import AppKit
import ApplicationServices

/// Scrollen auf der Titelleiste eines Fensters ordnet es an:
/// hoch = maximieren, runter = zentrieren, links/rechts = linke/rechte Bildschirmhälfte.
@MainActor
final class WindowSnapper {
    static let shared = WindowSnapper()

    enum Action: Equatable { case maximize, center, leftHalf, rightHalf }

    private var monitor: Any?
    private var accum = CGSize.zero
    private var firedAt = Date.distantPast
    private var lastEventAt = Date.distantPast
    private let titleBarHeight: CGFloat = 30

    func setEnabled(_ on: Bool) {
        if on, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { e in
                MainActor.assumeIsolated { WindowSnapper.shared.scrolled(e) }
            }
        } else if !on, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func scrolled(_ e: NSEvent) {
        if e.phase == .began || Date().timeIntervalSince(lastEventAt) > 0.3 { accum = .zero }
        lastEventAt = Date()
        guard e.momentumPhase.isEmpty else { return }
        let f: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        accum.width += e.scrollingDeltaX * f
        accum.height += e.scrollingDeltaY * f
        // Pro Geste nur eine Aktion (Trackpads liefern viele Einzelereignisse).
        guard Date().timeIntervalSince(firedAt) > 0.5,
              let action = Self.action(for: accum, naturalScrolling: e.isDirectionInvertedFromDevice) else { return }
        accum = .zero
        guard let window = windowUnderTitleBar(at: NSEvent.mouseLocation) else { return }
        firedAt = Date()
        apply(action, to: window, at: NSEvent.mouseLocation)
    }

    /// Richtung ab 40 pt Weg; maßgeblich ist die Fingerbewegung, unabhängig von „natürlichem Scrollen“.
    nonisolated static func action(for d: CGSize, naturalScrolling: Bool) -> Action? {
        let s: CGFloat = naturalScrolling ? -1 : 1
        let dx = d.width * s, dy = d.height * s
        guard max(abs(dx), abs(dy)) >= 40 else { return nil }
        if abs(dy) >= abs(dx) { return dy > 0 ? .maximize : .center }
        return dx > 0 ? .leftHalf : .rightHalf
    }

    private func windowUnderTitleBar(at p: NSPoint) -> AXUIElement? {
        guard let primary = NSScreen.screens.first else { return nil }
        let axPoint = CGPoint(x: p.x, y: primary.frame.height - p.y)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let role: String? = value(hit, kAXRoleAttribute)
        let window: AXUIElement? = role == kAXWindowRole as String ? hit : value(hit, kAXWindowAttribute)
        guard let window, let frame = frame(of: window) else { return nil }
        return axPoint.y - frame.minY <= titleBarHeight ? window : nil
    }

    private func apply(_ action: Action, to window: AXUIElement, at p: NSPoint) {
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main,
              let current = frame(of: window) else { return }
        var area = screen.visibleFrame
        // Platz fürs Pier-Dock freihalten (nur am Bildschirm, an dem es angedockt ist).
        let reserved = WindowFitter.shared.reserved(on: screen)
        if reserved > 0 {
            let top = area.maxY
            area.origin.y = max(area.minY, screen.frame.minY + reserved)
            area.size.height = top - area.minY
        }
        // AX-Koordinaten: oben links am Hauptbildschirm.
        let ax = CGRect(x: area.minX, y: primary.frame.height - area.maxY, width: area.width, height: area.height)
        var target: CGRect
        switch action {
        case .maximize: target = ax
        case .leftHalf: target = CGRect(x: ax.minX, y: ax.minY, width: (ax.width / 2).rounded(), height: ax.height)
        case .rightHalf:
            let w = (ax.width / 2).rounded()
            target = CGRect(x: ax.maxX - w, y: ax.minY, width: w, height: ax.height)
        case .center:
            let w = min(current.width, ax.width), h = min(current.height, ax.height)
            target = CGRect(x: (ax.midX - w / 2).rounded(), y: (ax.midY - h / 2).rounded(), width: w, height: h)
        }
        // Position – Größe – Position: manche Apps begrenzen die Größe sonst an der alten Stelle.
        set(window, origin: target.origin)
        set(window, size: target.size)
        set(window, origin: target.origin)
    }

    // MARK: AX-Helfer

    private func value<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private func frame(of w: AXUIElement) -> CGRect? {
        guard let pv: AXValue = value(w, kAXPositionAttribute), let sv: AXValue = value(w, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p)
        AXValueGetValue(sv, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func set(_ w: AXUIElement, origin: CGPoint) {
        var o = origin
        if let v = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }

    private func set(_ w: AXUIElement, size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }
}
