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
    @ViewBuilder var content: Content
    @Environment(\.dockEdge) private var edge

    var body: some View {
        // Zur Bildschirmkante hin etwas mehr Platz für den Lauf-Indikator.
        content
            .padding(.top, edge == .bottom ? 6 : (edge == .top ? 9 : 7))
            .padding(.bottom, edge == .bottom ? 9 : (edge == .top ? 6 : 7))
            .padding(.leading, edge == .left ? 9 : (edge == .right ? 6 : 7))
            .padding(.trailing, edge == .right ? 9 : (edge == .left ? 6 : 7))
            .background(GlassBackground())
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
