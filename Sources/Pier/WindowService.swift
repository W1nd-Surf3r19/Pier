import AppKit
import ApplicationServices
import ScreenCaptureKit

// Private, aber stabile API (wird u. a. von AltTab genutzt): liefert die CGWindowID zu einem AX-Fenster.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowRef: Identifiable, Equatable, @unchecked Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let isMinimized: Bool
    let isFocused: Bool
    let element: AXUIElement

    var id: String { windowID != 0 ? "w\(windowID)" : "p\(pid)-\(CFHash(element))" }

    static func == (a: WindowRef, b: WindowRef) -> Bool {
        a.id == b.id && a.title == b.title && a.isMinimized == b.isMinimized && a.isFocused == b.isFocused
    }
}

enum WindowService {
    /// Fenster aller Apps; `unresponsive` = Apps, die nicht rechtzeitig geantwortet haben.
    static func windows(for pids: [pid_t]) -> (windows: [pid_t: [WindowRef]], unresponsive: Set<pid_t>) {
        var result: [pid_t: [WindowRef]] = [:]
        var unresponsive = Set<pid_t>()
        for pid in pids {
            guard let w = scan(pid: pid) else { unresponsive.insert(pid); continue }
            if !w.isEmpty { result[pid] = w }
        }
        return (result, unresponsive)
    }

    static func windows(pid: pid_t) -> [WindowRef] { scan(pid: pid) ?? [] }

    /// nil = die App hat nicht innerhalb des Zeitlimits geantwortet (hängt oder ist gerade sehr beschäftigt).
    private static func scan(pid: pid_t) -> [WindowRef]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if err == .cannotComplete { return nil }
        guard err == .success, let wins = value as? [AXUIElement] else { return [] }
        let focused: AXUIElement? = attr(app, kAXFocusedWindowAttribute)

        return wins.compactMap { w in
            let subrole: String? = attr(w, kAXSubroleAttribute)
            guard subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { return nil }
            var wid: CGWindowID = 0
            _AXUIElementGetWindow(w, &wid)
            let title: String = attr(w, kAXTitleAttribute) ?? ""
            let minimized: Bool = attr(w, kAXMinimizedAttribute) ?? false
            let isFocused = focused.map { CFEqual($0, w) } ?? false
            return WindowRef(windowID: wid, pid: pid, title: title, isMinimized: minimized, isFocused: isFocused, element: w)
        }
    }

    /// IDs der Fenster, die gerade auf dem Bildschirm liegen – also auf dem aktuellen Schreibtisch (Space).
    static func onScreenWindowIDs() -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    static func raise(_ w: WindowRef) {
        if w.isMinimized {
            AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
    }

    static func minimize(_ w: WindowRef) {
        AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Setzt das Fenster so, dass die Mitte seiner Titelleiste am Punkt `p` (Cocoa-Koordinaten) liegt.
    static func move(_ w: WindowRef, titleBarTo p: NSPoint) {
        guard let primary = NSScreen.screens.first,
              let sizeValue: AXValue = attr(w.element, kAXSizeAttribute) else { return }
        var size = CGSize.zero
        AXValueGetValue(sizeValue, .cgSize, &size)
        // AX: Ursprung oben links am Hauptbildschirm, y wächst nach unten.
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? primary
        let topLimit = primary.frame.height - screen.visibleFrame.maxY
        var origin = CGPoint(x: (p.x - size.width / 2).rounded(), y: max(primary.frame.height - p.y - 12, topLimit).rounded())
        if let v = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(w.element, kAXPositionAttribute as CFString, v)
        }
    }

    static func close(_ w: WindowRef) {
        if let button: AXUIElement = attr(w.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    struct DockStatus: Equatable, Sendable {
        var badges: [String: String] = [:]
        var progress: [String: Double] = [:]
    }

    /// Badges (z. B. „3“ ungelesene Nachrichten) und Fortschritt liest Pier aus dem ausgeblendeten Mac-Dock.
    /// Schlüssel wie `PinnedApp.key`: Bundle-ID, sonst Pfad.
    static func dockStatus() -> DockStatus {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return DockStatus() }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var result = DockStatus()
        for list in attr(root, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
            for item in attr(list, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
                let label: String? = attr(item, "AXStatusLabel")
                let progress: NSNumber? = attr(item, "AXProgressValue")
                guard label?.isEmpty == false || progress != nil, let url: URL = attr(item, "AXURL") else { continue }
                let key = Bundle(url: url)?.bundleIdentifier ?? url.standardizedFileURL.path
                if let label, !label.isEmpty { result.badges[key] = label }
                if let progress { result.progress[key] = min(max(progress.doubleValue, 0), 1) }
            }
        }
        return result
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}

/// Fenster-Thumbnails über ScreenCaptureKit (braucht die Berechtigung „Bildschirmaufnahme“).
actor ThumbnailService {
    static let shared = ThumbnailService()

    private var cache: [CGWindowID: (image: NSImage, date: Date)] = [:]
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast

    func thumbnail(for id: CGWindowID) async -> NSImage? {
        guard id != 0, CGPreflightScreenCaptureAccess() else { return nil }
        if let c = cache[id], Date().timeIntervalSince(c.date) < 1.5 { return c.image }
        do {
            if content == nil || Date().timeIntervalSince(contentDate) > 2 {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                contentDate = Date()
            }
            guard let win = content?.windows.first(where: { $0.windowID == id }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let w = min(win.frame.width * 2, 440)
            cfg.width = max(Int(w), 2)
            cfg.height = max(Int(w * win.frame.height / max(win.frame.width, 1)), 2)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
            cache[id] = (img, Date())
            return img
        } catch {
            return nil
        }
    }
}
