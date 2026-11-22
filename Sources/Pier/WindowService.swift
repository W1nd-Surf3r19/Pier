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
    static func windows(for pids: [pid_t]) -> [pid_t: [WindowRef]] {
        var result: [pid_t: [WindowRef]] = [:]
        for pid in pids {
            let w = windows(pid: pid)
            if !w.isEmpty { result[pid] = w }
        }
        return result
    }

    static func windows(pid: pid_t) -> [WindowRef] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let wins: [AXUIElement] = attr(app, kAXWindowsAttribute) else { return [] }
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

    static func close(_ w: WindowRef) {
        if let button: AXUIElement = attr(w.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
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
