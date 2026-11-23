import AppKit
import Carbon
import SwiftUI

// MARK: Panels

/// Panel, das nie Fokus bekommt (Dock, Vorschau, Ordner).
final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Panel, das Tastatureingaben annehmen kann, ohne die App zu aktivieren (Launcher).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum PanelFactory {
    static let dockLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))

    static func makeGlass<P: NSPanel>(_ type: P.Type, level: NSWindow.Level, radius: CGFloat?) -> (P, NSVisualEffectView) {
        let panel = P(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = radius.map(maskImage(radius:))
        panel.contentView = effect
        return (panel, effect)
    }

    static func embed(_ view: NSView, in effect: NSVisualEffectView) {
        view.frame = effect.bounds
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
    }

    static func maskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    static var mainScreen: NSScreen? { NSScreen.screens.first }
}

// MARK: Hover, unabhängig davon, ob Pier aktiv ist

struct HoverTracker: NSViewRepresentable {
    var onChange: (Bool, CGRect) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: TrackingView, context: Context) { v.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool, CGRect) -> Void)?
        private var inside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        var screenRect: CGRect {
            guard let w = window else { return .zero }
            return w.convertToScreen(convert(bounds, to: nil))
        }

        override func mouseEntered(with event: NSEvent) { inside = true; onChange?(true, screenRect) }
        override func mouseExited(with event: NSEvent) { inside = false; onChange?(false, screenRect) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, inside { inside = false; onChange?(false, .zero) }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

extension CGRect {
    func inset(by e: NSEdgeInsets) -> CGRect {
        CGRect(x: minX + e.left, y: minY + e.top, width: width - e.left - e.right, height: height - e.top - e.bottom)
    }
}

extension View {
    func onHoverAlways(_ action: @escaping (Bool, CGRect) -> Void) -> some View {
        background(HoverTracker(onChange: action))
    }
}

// MARK: Icons

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forPath path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 128, height: 128)
        cache.setObject(i, forKey: path as NSString)
        return i
    }

    static func icon(for app: NSRunningApplication) -> NSImage {
        if let path = app.bundleURL?.path { return icon(forPath: path) }
        return app.icon ?? NSImage(named: NSImage.applicationIconName)!
    }
}

// MARK: Globaler Kurzbefehl (Carbon, braucht keine Berechtigung)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32
    nonisolated(unsafe) private static var nextID: UInt32 = 1

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Jede Instanz hat einen eigenen Handler – nur auf die eigene ID reagieren, sonst feuern alle Kürzel gemeinsam.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            guard let ctx, let event else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(ctx).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.id == me.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5049_4552), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: Glas-Inseln (Pillen-Stil)

/// Echtes Hintergrund-Glas (Blur des Desktops) in Kapselform.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> CapsuleEffectView {
        let v = CapsuleEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: CapsuleEffectView, context: Context) {}

    final class CapsuleEffectView: NSVisualEffectView {
        private var radius: CGFloat = -1
        override func layout() {
            super.layout()
            let r = floor(bounds.height / 2)
            if r > 0, r != radius {
                radius = r
                maskImage = PanelFactory.maskImage(radius: r)
                window?.invalidateShadow()
            }
        }
        // Klicks/Rechtsklicks gehen an SwiftUI, nicht an das Glas.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct GlassIsland<Content: View>: View {
    /// Zusätzlicher Abstand an beiden Enden der Kapsel – damit Badge und Mulde des äußersten Icons in der Rundung bleiben.
    var endInset: CGFloat = 0
    @ViewBuilder var content: Content
    @Environment(\.dockEdge) private var edge
    @Environment(\.dockTheme) private var theme

    var body: some View {
        // Zur Bildschirmkante hin etwas mehr Platz für den Lauf-Indikator.
        content
            .padding(.top, (edge == .bottom ? 6 : (edge == .top ? 9 : 7)) + (edge.isVertical ? endInset : 0))
            .padding(.bottom, (edge == .bottom ? 9 : (edge == .top ? 6 : 7)) + (edge.isVertical ? endInset : 0))
            .padding(.leading, (edge == .left ? 9 : (edge == .right ? 6 : 7)) + (edge.isVertical ? 0 : endInset))
            .padding(.trailing, (edge == .right ? 9 : (edge == .left ? 6 : 7)) + (edge.isVertical ? 0 : endInset))
            .background { ZStack { if !theme.isClear { GlassBackground() }; Capsule().fill(theme.glassTint) } }
            .background(Capsule().fill(Color.black.opacity(0.001)))
            .overlay(
                Capsule().fill(
                    LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
                )
                .allowsHitTesting(false)
            )
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            )
    }
}

// MARK: Kleine Design-Bausteine

struct DockDivider: View {
    var height: CGFloat
    /// Waagerechter Strich für die senkrechte Pille.
    var horizontal = false
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.16)).frame(width: horizontal ? height : 1, height: horizontal ? 1 : height)
    }
}

struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: Griff zum Verschieben der frei schwebenden Pille

/// Ziehen bewegt das Fenster, in dem der Griff liegt; Loslassen meldet die neue Lage.
struct MoveHandle: NSViewRepresentable {
    var onEnd: (NSWindow) -> Void

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onEnd = onEnd
        return v
    }

    func updateNSView(_ v: HandleView, context: Context) { v.onEnd = onEnd }

    final class HandleView: NSView {
        var onEnd: ((NSWindow) -> Void)?
        private var start: (mouse: NSPoint, origin: NSPoint)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            start = (NSEvent.mouseLocation, w.frame.origin)
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let w = window, let s = start else { return }
            let m = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            NSCursor.pop()
            if let w = window { onEnd?(w) }
        }
    }
}

// MARK: Griff zum Ändern der Zeilenzahl der Leiste

/// Dünner Streifen am Innenrand der Leiste: Ziehen ändert die Zahl der Zeilen in Stufen.
/// Rechnet mit der absoluten Mausposition – das Panel ändert beim Ziehen seine Größe.
struct BarResizeHandle: NSViewRepresentable {
    let edge: DockEdge
    let rows: Int
    let step: CGFloat
    /// (neue Zeilenzahl, Ziehen beendet)
    var onChange: (Int, Bool) -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ v: HandleView, context: Context) {
        v.edge = edge
        v.rows = rows
        v.step = step
        v.onChange = onChange
    }

    final class HandleView: NSView {
        var edge = DockEdge.bottom
        var rows = 1
        var step: CGFloat = 30
        var onChange: ((Int, Bool) -> Void)?
        private var start: (mouseY: CGFloat, rows: Int)?
        private var last = 0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Cursor auch, wenn Pier nicht aktiv ist (resetCursorRects greift dann nicht).
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { NSCursor.resizeUpDown.set() }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }
        override func mouseExited(with event: NSEvent) { if start == nil { NSCursor.arrow.set() } }

        override func mouseDown(with event: NSEvent) {
            start = (NSEvent.mouseLocation.y, rows)
            last = rows
        }

        override func mouseDragged(with event: NSEvent) {
            guard let s = start else { return }
            NSCursor.resizeUpDown.set()
            let next = BarResizeHandle.rows(from: s.rows, drag: NSEvent.mouseLocation.y - s.mouseY, step: step, edge: edge)
            if next != last {
                last = next
                onChange?(next, false)
            }
        }

        override func mouseUp(with event: NSEvent) { finish() }

        // Verschwindet der Griff mitten im Ziehen (Bildschirmwechsel baut das Dock neu), trotzdem abschließen.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finish() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func finish() {
            guard start != nil else { return }
            start = nil
            onChange?(last, true)
        }
    }

    /// Zeilen nach dem Ziehen: unten wächst die Leiste nach oben, oben nach unten; je `step` eine Zeile.
    nonisolated static func rows(from start: Int, drag dy: CGFloat, step: CGFloat, edge: DockEdge) -> Int {
        let toward = edge == .top ? -dy : dy
        return min(max(start + Int((toward / step).rounded()), 1), DockMetrics.maxBarRows)
    }
}
