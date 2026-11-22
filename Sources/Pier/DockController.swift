import AppKit
import SwiftUI

@MainActor
final class DockFit: ObservableObject {
    static let shared = DockFit()
    @Published var scale: CGFloat = 1
}

/// Das Dock-Fenster selbst: Position, Form (Pille/Leiste) und automatisches Ausblenden.
@MainActor
final class DockController {
    let panel: PassivePanel
    private let effect: NSVisualEffectView
    private let hosting: FirstMouseHostingView<DockRootView>
    private var settings = DockSettings()
    private var pillSize = CGSize(width: 300, height: 60)
    private var concealed = false
    private var hideTimer: Timer?
    private var monitors: [Any] = []

    init() {
        let (panel, effect) = PanelFactory.makeGlass(PassivePanel.self, level: PanelFactory.dockLevel, radius: DockMetrics.pillRadius)
        self.panel = panel
        self.effect = effect
        hosting = FirstMouseHostingView(rootView: DockRootView(onSize: { _ in }))
        hosting.sizingOptions = []
        PanelFactory.embed(hosting, in: effect)
        hosting.rootView = DockRootView(onSize: { [weak self] size in self?.contentSizeChanged(size) })

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
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

    func apply(_ s: DockSettings) {
        let styleChanged = s.style != settings.style
        settings = s
        effect.maskImage = s.style == .pill ? PanelFactory.maskImage(radius: DockMetrics.pillRadius) : nil
        if !s.autoHide { concealed = false }
        if styleChanged, s.style == .pill {
            hosting.layoutSubtreeIfNeeded()
            pillSize = hosting.fittingSize
        }
        layout(animated: false)
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard settings.style == .pill, size.width > 1, size != pillSize else { return }
        pillSize = size
        fitToScreen()
        layout(animated: true)
    }

    /// Zu viele Icons? Dann werden sie kleiner, bis die Pille auf den Bildschirm passt.
    private func fitToScreen() {
        guard let sf = screen?.frame else { return }
        let available = sf.width - 32
        let fit = DockFit.shared
        let natural = pillSize.width / fit.scale
        let target = min(1, max(0.5, available / natural))
        if abs(target - fit.scale) > 0.01 || (pillSize.width > available && target < fit.scale) {
            fit.scale = target
        }
    }

    // MARK: Position

    private var screen: NSScreen? { PanelFactory.mainScreen }

    private func targetFrame() -> NSRect {
        guard let sf = screen?.frame else { return panel.frame }
        var f: NSRect
        switch settings.style {
        case .bar:
            let h = DockMetrics.barHeight(settings)
            f = NSRect(x: sf.minX, y: sf.minY, width: sf.width, height: h)
        case .pill:
            let w = min(ceil(pillSize.width), sf.width - 16)
            let h = ceil(pillSize.height)
            f = NSRect(x: (sf.midX - w / 2).rounded(), y: sf.minY + DockMetrics.pillBottomGap, width: w, height: h)
        }
        if concealed { f.origin.y = sf.minY - f.height - 20 }
        return f
    }

    private func layout(animated: Bool) {
        let f = targetFrame()
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(f, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            }
        } else {
            panel.setFrame(f, display: true)
            panel.invalidateShadow()
        }
    }

    // MARK: Automatisch ausblenden

    private func mouseMoved() {
        guard settings.autoHide, let sf = screen?.frame else { return }
        let p = NSEvent.mouseLocation
        if concealed {
            if p.y <= sf.minY + 2, p.x >= sf.minX, p.x <= sf.maxX {
                concealed = false
                layout(animated: true)
            }
        } else {
            let zone = panel.frame.insetBy(dx: -12, dy: -24)
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
