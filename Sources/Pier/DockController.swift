import AppKit
import Combine
import SwiftUI

/// Verkleinerung der Icons, damit die Pille auf ihren Bildschirm passt – je Dock eigener Wert.
@MainActor
final class DockFit: ObservableObject {
    @Published var scale: CGFloat = 1
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Bleibt über Neustarts und Umstecken gleich – anders als `displayID`.
    var uuid: String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }
}

/// Ein Dock-Fenster auf einem Bildschirm: Position, Form (Pille/Leiste) und automatisches Ausblenden.
@MainActor
final class DockController {
    let panel: PassivePanel
    let displayID: CGDirectDisplayID
    private let fit = DockFit()
    private var screenObserver: NSObjectProtocol?
    private let effect: NSVisualEffectView
    /// Tönung des Farbthemas – liegt im Glas, damit sie dieselbe Form (Ecken, Hohlkehlen) bekommt.
    private let tint = CAGradientLayer()
    private let hosting: FirstMouseHostingView<DockRootView>
    private var settings = DockSettings()
    private var pillSize = CGSize(width: 300, height: 60)
    private var concealed = false
    private var hideTimer: Timer?
    private var monitors: [Any] = []
    private var shapeTimer: Timer?
    private var fillets: [Fillet] = []
    private var shapeSize: CGSize = .zero
    private var themeSub: AnyCancellable?

    /// Hohlkehle an der unteren Ecke eines angedockten Fensters (x in Panel-Koordinaten).
    struct Fillet: Equatable {
        var x: CGFloat
        var rightEdge: Bool
    }

    /// Sichtbare Oberkante des Docks (ohne den transparenten Streifen für die Hohlkehlen).
    var visibleTop: CGFloat {
        settings.style == .bar ? panel.frame.minY + DockMetrics.barHeight(settings) : panel.frame.maxY
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        // Keine Anfangsmaske: macOS übernimmt die Maske des ersten Inhalts als Fensterform und rundete sonst die Leiste unten ab.
        let (panel, effect) = PanelFactory.makeGlass(PassivePanel.self, level: PanelFactory.dockLevel, radius: nil)
        self.panel = panel
        self.effect = effect
        hosting = FirstMouseHostingView(rootView: DockRootView(fit: fit, onSize: { _ in }))
        hosting.sizingOptions = []
        // Container: Glas (nur Leiste) hinten, SwiftUI vorne. Im Pillen-Stil zeichnen die Inseln ihr eigenes Glas.
        let container = NSView()
        panel.contentView = container
        effect.frame = container.bounds
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)
        effect.wantsLayer = true
        let tintView = NSView(frame: effect.bounds)
        tintView.layer = tint
        tintView.wantsLayer = true
        tintView.autoresizingMask = [.width, .height]
        tint.startPoint = CGPoint(x: 0, y: 1)
        tint.endPoint = CGPoint(x: 1, y: 0)
        effect.addSubview(tintView)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        hosting.rootView = DockRootView(fit: fit, onSize: { [weak self] size in self?.contentSizeChanged(size) })
        // Tönung folgt den aufgelösten Farben – auch wenn nur das Cover wechselt.
        themeSub = ThemeModel.shared.$colors.sink { [weak self] c in
            self?.tint.colors = c.glass.isEmpty ? nil : c.glass.map { NSColor($0).withAlphaComponent(0.2).cgColor }
        }

        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.mouseMoved() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    func show() {
        layout(animated: false)
        panel.orderFrontRegardless()
    }

    /// Für Bildschirme, die abgesteckt oder abgewählt wurden.
    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        hideTimer?.invalidate()
        shapeTimer?.invalidate()
        shapeTimer = nil
        panel.orderOut(nil)
    }

    func apply(_ s: DockSettings) {
        let styleChanged = s.style != settings.style || s.effectiveEdge != settings.effectiveEdge
        settings = s
        effect.isHidden = s.style == .pill || s.theme.isClear
        // Ohne Glas würde der Fensterschatten jedes Icon einzeln umranden.
        panel.hasShadow = !s.theme.isClear
        panel.invalidateShadow()
        if s.style == .bar {
            // Leiste unten im Panel, darüber ein transparenter Streifen für die Hohlkehlen.
            hosting.frame = NSRect(x: 0, y: 0, width: panel.frame.width, height: DockMetrics.barHeight(s))
            hosting.autoresizingMask = [.width, .maxYMargin]
            startShapeTracking()
        } else {
            hosting.frame = panel.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]
            effect.maskImage = nil
            shapeTimer?.invalidate()
            shapeTimer = nil
        }
        if !s.autoHide || s.isFree {
            concealed = false
            hideTimer?.invalidate()
            hideTimer = nil
        }
        if styleChanged, s.style == .pill {
            hosting.layoutSubtreeIfNeeded()
            // Vor dem ersten Anzeigen kann die Größe noch 0 sein – dann liefert onSize sie nach.
            let fitting = hosting.fittingSize
            if fitting.width > 1, fitting.height > 1 {
                pillSize = fitting
                fitToScreen()
            }
        }
        layout(animated: false)
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard settings.style == .pill, size.width > 1, size != pillSize else { return }
        pillSize = size
        fitToScreen()
        layout(animated: true)
        panel.invalidateShadow()
    }

    /// Zu viele Icons? Dann werden sie kleiner, bis die Pille auf den Bildschirm passt.
    private func fitToScreen() {
        guard let sf = screen?.visibleFrame else { return }
        let vertical = settings.effectiveEdge.isVertical
        let available = (vertical ? sf.height : sf.width) - 32
        let length = vertical ? pillSize.height : pillSize.width
        let natural = length / fit.scale
        let target = min(1, max(0.5, available / natural))
        if abs(target - fit.scale) > 0.01 || (length > available && target < fit.scale) {
            fit.scale = target
        }
    }

    // MARK: Position

    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    private func targetFrame() -> NSRect {
        guard let screen else { return panel.frame }
        let sf = screen.frame
        let gap = DockMetrics.pillBottomGap
        var f: NSRect
        switch settings.style {
        case .bar:
            let h = DockMetrics.barHeight(settings) + DockMetrics.filletRadius
            f = NSRect(x: sf.minX, y: sf.minY, width: sf.width, height: h)
        case .pill:
            let vf = screen.visibleFrame
            let size = CGSize(width: min(ceil(pillSize.width), sf.width - 16), height: min(ceil(pillSize.height), vf.height - 16))
            let origin = settings.isFree
                ? Self.freeOrigin(settings.freeOrigin, size: size, visible: vf)
                    ?? Self.pillOrigin(edge: settings.effectiveEdge, placement: .center, size: size, screen: sf, visible: vf, gap: gap)
                : Self.pillOrigin(edge: settings.effectiveEdge, placement: settings.placement, size: size, screen: sf, visible: vf, gap: gap)
            f = NSRect(origin: origin, size: size)
        }
        // Ausgeblendet: nur ein Stück zur Kante rutschen und unsichtbar werden. Ganz hinausschieben
        // würde das Dock auf einem angrenzenden Bildschirm auftauchen lassen.
        if concealed {
            let nudge: CGFloat = 12
            switch settings.effectiveEdge {
            case .bottom: f.origin.y -= nudge
            case .top: f.origin.y += nudge
            case .left: f.origin.x -= nudge
            case .right: f.origin.x += nudge
            }
        }
        return f
    }

    /// Ecke der Pille an ihrer Kante: Anfang (links/oben), Mitte oder Ende (rechts/unten).
    /// Seitlich im Bereich unter der Menüleiste.
    nonisolated static func pillOrigin(edge: DockEdge, placement: PillPlacement, size: CGSize,
                                       screen sf: CGRect, visible vf: CGRect, gap: CGFloat) -> CGPoint {
        let w = size.width, h = size.height
        let x: CGFloat = switch placement {
        case .start: sf.minX + gap
        case .end: sf.maxX - w - gap
        case .center, .free: (sf.midX - w / 2).rounded()
        }
        let y: CGFloat = switch placement {
        case .start: vf.maxY - h - gap
        case .end: vf.minY + gap
        case .center, .free: (vf.midY - h / 2).rounded()
        }
        switch edge {
        case .bottom: return CGPoint(x: x, y: sf.minY + gap)
        case .top: return CGPoint(x: x, y: vf.maxY - h - gap)
        case .left: return CGPoint(x: sf.minX + gap, y: y)
        case .right: return CGPoint(x: sf.maxX - w - gap, y: y)
        }
    }

    /// Frei verschobene Pille: gespeicherter Anteil (0…1) des freien Bereichs, immer ganz auf dem Bildschirm.
    nonisolated static func freeOrigin(_ fraction: CGPoint?, size: CGSize, visible vf: CGRect) -> CGPoint? {
        guard let fraction else { return nil }
        let fx = min(max(fraction.x, 0), 1), fy = min(max(fraction.y, 0), 1)
        return CGPoint(x: (vf.minX + fx * max(vf.width - size.width, 0)).rounded(),
                       y: (vf.minY + fy * max(vf.height - size.height, 0)).rounded())
    }

    /// Umkehrung von `freeOrigin`: wo die Pille nach dem Ziehen steht, als Anteil.
    nonisolated static func freeFraction(of frame: CGRect, visible vf: CGRect) -> CGPoint {
        let sx = max(vf.width - frame.width, 1), sy = max(vf.height - frame.height, 1)
        return CGPoint(x: min(max((frame.minX - vf.minX) / sx, 0), 1), y: min(max((frame.minY - vf.minY) / sy, 0), 1))
    }

    /// Nach dem Ziehen am Griff: Position merken (gilt für alle Docks) und einrasten.
    func movedByUser() {
        guard settings.isFree, let vf = screen?.visibleFrame else { return }
        DockStore.shared.settings.freeOrigin = Self.freeFraction(of: panel.frame, visible: vf)
        // Bleibt der Anteil gleich (z. B. über den Rand hinaus gezogen), kommt kein apply – selbst einrasten.
        layout(animated: true)
    }

    /// Kante, an der Popups andocken. Die frei schwebende Pille öffnet sie zur Bildschirmmitte hin.
    private var popupEdge: DockEdge {
        guard settings.isFree, let vf = screen?.visibleFrame else { return settings.effectiveEdge }
        let f = panel.frame
        if settings.effectiveEdge.isVertical { return f.midX < vf.midX ? .left : .right }
        return f.midY < vf.midY ? .bottom : .top
    }

    /// Wo ein Popup (Vorschau, Ordner, Stapel) neben diesem Dock erscheint.
    func popupFrame(size: CGSize, anchor: CGRect) -> NSRect {
        let vf = screen?.visibleFrame ?? panel.frame
        let gap: CGFloat = 8
        let edge = popupEdge
        switch edge {
        case .bottom:
            let x = min(max(anchor.midX - size.width / 2, vf.minX + gap), vf.maxX - size.width - gap)
            return NSRect(x: x.rounded(), y: (visibleTop + gap).rounded(), width: size.width, height: size.height)
        case .top:
            let x = min(max(anchor.midX - size.width / 2, vf.minX + gap), vf.maxX - size.width - gap)
            return NSRect(x: x.rounded(), y: (panel.frame.minY - gap - size.height).rounded(), width: size.width, height: size.height)
        case .left, .right:
            let y = min(max(anchor.midY - size.height / 2, vf.minY + gap), vf.maxY - size.height - gap)
            let x = edge == .left ? panel.frame.maxX + gap : panel.frame.minX - size.width - gap
            return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        }
    }

    private func layout(animated: Bool) {
        let f = targetFrame()
        let alpha: CGFloat = concealed ? 0 : 1
        panel.ignoresMouseEvents = concealed
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(f, display: true)
                panel.animator().alphaValue = alpha
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            }
        } else {
            panel.setFrame(f, display: true)
            panel.alphaValue = alpha
            panel.invalidateShadow()
        }
        if settings.style == .bar {
            hosting.frame = NSRect(x: 0, y: 0, width: f.width, height: DockMetrics.barHeight(settings))
            updateBarShape(force: true)
        }
    }

    // MARK: Form der Leiste (runde Ecken + Hohlkehlen unter angedockten Fenstern)

    private func startShapeTracking() {
        guard shapeTimer == nil else { return }
        shapeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBarShape(force: false) }
        }
    }

    private func updateBarShape(force: Bool) {
        guard settings.style == .bar else { return }
        let new = (settings.fitWindows && !settings.autoHide && !concealed) ? findFillets() : []
        let size = panel.frame.size
        guard force || new != fillets || size != shapeSize else { return }
        fillets = new
        shapeSize = size
        let mask = barMask(size: size)
        effect.maskImage = mask
        // maskImage schneidet nur das Glas zu, nicht dessen Unterebenen – die Tönung braucht dieselbe Form.
        let tintMask = CALayer()
        tintMask.frame = CGRect(origin: .zero, size: size)
        tintMask.contents = mask
        tint.mask = tintMask
        panel.invalidateShadow()
    }

    /// Fenster, deren Unterkante genau auf der Leiste sitzt und deren Ecke nicht verdeckt ist.
    private func findFillets() -> [Fillet] {
        guard let sf = screen?.frame, let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let r = DockMetrics.filletRadius
        // CG-Koordinaten: oben links am Hauptbildschirm.
        let barTop = primary.frame.height - sf.minY - DockMetrics.barHeight(settings)
        let me = ProcessInfo.processInfo.processIdentifier
        var inFront: [CGRect] = []
        var result: [Fillet] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.width > 60, b.height > 60 else { continue }
            if abs(b.maxY - barTop) <= 2, b.minY < barTop - 100 {
                let probeL = CGPoint(x: b.minX + r * 0.35, y: barTop - r * 0.35)
                let probeR = CGPoint(x: b.maxX - r * 0.35, y: barTop - r * 0.35)
                if b.minX >= sf.minX - 1, b.minX < sf.maxX, !inFront.contains(where: { $0.contains(probeL) }) {
                    result.append(Fillet(x: (b.minX - sf.minX).rounded(), rightEdge: false))
                }
                if b.maxX <= sf.maxX + 1, b.maxX > sf.minX, !inFront.contains(where: { $0.contains(probeR) }) {
                    result.append(Fillet(x: (b.maxX - sf.minX).rounded(), rightEdge: true))
                }
            }
            inFront.append(b)
        }
        return result.sorted { ($0.x, $0.rightEdge ? 1 : 0) < ($1.x, $1.rightEdge ? 1 : 0) }
    }

    private func barMask(size: CGSize) -> NSImage {
        let h = DockMetrics.barHeight(settings)
        let r = DockMetrics.filletRadius
        let corner = DockMetrics.barCornerRadius
        let fillets = self.fillets
        // Sitzt ein Fenster bündig am Bildschirmrand, bleibt die Ecke dort eckig (sonst entstünde dort ein Keil).
        let squareLeft = fillets.contains { !$0.rightEdge && $0.x <= 2 }
        let squareRight = fillets.contains { $0.rightEdge && $0.x >= size.width - 2 }
        return NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: 0, y: 0))
            bar.line(to: NSPoint(x: size.width, y: 0))
            if squareRight {
                bar.line(to: NSPoint(x: size.width, y: h))
            } else {
                bar.line(to: NSPoint(x: size.width, y: h - corner))
                bar.appendArc(withCenter: NSPoint(x: size.width - corner, y: h - corner), radius: corner,
                              startAngle: 0, endAngle: 90)
            }
            if squareLeft {
                bar.line(to: NSPoint(x: 0, y: h))
            } else {
                bar.line(to: NSPoint(x: corner, y: h))
                bar.appendArc(withCenter: NSPoint(x: corner, y: h - corner), radius: corner,
                              startAngle: 90, endAngle: 180)
            }
            bar.close()
            bar.fill()

            for f in fillets {
                let p = NSBezierPath()
                if f.rightEdge {
                    p.move(to: NSPoint(x: f.x, y: h))
                    p.line(to: NSPoint(x: f.x, y: h + r))
                    p.appendArc(withCenter: NSPoint(x: f.x - r, y: h + r), radius: r, startAngle: 0, endAngle: 270, clockwise: true)
                } else {
                    p.move(to: NSPoint(x: f.x, y: h))
                    p.line(to: NSPoint(x: f.x, y: h + r))
                    p.appendArc(withCenter: NSPoint(x: f.x + r, y: h + r), radius: r, startAngle: 180, endAngle: 270)
                }
                p.close()
                p.fill()
            }
            return true
        }
    }

    // MARK: Automatisch ausblenden

    private func mouseMoved() {
        guard settings.autoHide, !settings.isFree, let sf = screen?.frame else { return }
        let p = NSEvent.mouseLocation
        if concealed {
            let atEdge: Bool = switch settings.effectiveEdge {
            case .bottom: p.y <= sf.minY + 2 && p.x >= sf.minX && p.x <= sf.maxX
            case .top: p.y >= sf.maxY - 2 && p.x >= sf.minX && p.x <= sf.maxX
            case .left: p.x <= sf.minX + 2 && p.y >= sf.minY && p.y <= sf.maxY
            case .right: p.x >= sf.maxX - 2 && p.y >= sf.minY && p.y <= sf.maxY
            }
            if atEdge {
                concealed = false
                layout(animated: true)
                updateBarShape(force: true)
            }
        } else {
            let zone = settings.effectiveEdge.isVertical ? panel.frame.insetBy(dx: -24, dy: -12) : panel.frame.insetBy(dx: -12, dy: -24)
            let popupOpen = Coordinator.shared.popup.isVisible || Coordinator.shared.launcher.isVisible
            if zone.contains(p) || popupOpen {
                hideTimer?.invalidate()
                hideTimer = nil
            } else if hideTimer == nil {
                hideTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.hideTimer = nil
                        self.concealed = true
                        self.layout(animated: true)
                    }
                }
            }
        }
    }
}
