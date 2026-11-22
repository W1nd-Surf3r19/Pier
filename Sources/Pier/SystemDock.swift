import Foundation

/// Blendet das Mac-Dock aus (Auto-Ausblenden mit sehr langer Verzögerung) und stellt es wieder her.
/// Der Dock-Prozess läuft weiter – Mission Control, Spaces und ⌘-Tab hängen an ihm.
///
/// Notfall-Wiederherstellung im Terminal:
///   defaults delete com.apple.dock autohide-delay; defaults write com.apple.dock autohide -bool false; killall Dock
enum SystemDock {
    private static let savedKey = "savedSystemDockState"

    static func hide() {
        let d = UserDefaults.standard
        if d.dictionary(forKey: savedKey) == nil {
            var state: [String: Any] = [:]
            if let v = read("autohide") { state["autohide"] = v }
            if let v = read("autohide-delay") { state["autohide-delay"] = v }
            d.set(state, forKey: savedKey)
        }
        if read("autohide") == "1", read("autohide-delay").flatMap(Double.init) == 1000 { return }
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        run("/usr/bin/killall", ["Dock"])
    }

    static func restore() {
        let d = UserDefaults.standard
        guard let state = d.dictionary(forKey: savedKey) else { return }
        if let a = state["autohide"] as? String {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", a == "1" ? "true" : "false"])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide"])
        }
        if let v = state["autohide-delay"] as? String {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", v])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        }
        d.removeObject(forKey: savedKey)
        run("/usr/bin/killall", ["Dock"])
    }

    private static func read(_ key: String) -> String? {
        let out = run("/usr/bin/defaults", ["read", "com.apple.dock", key])
        return out.status == 0 ? out.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
