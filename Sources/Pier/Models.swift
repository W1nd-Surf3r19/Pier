import AppKit

struct PinnedApp: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var bundleID: String?
    var name: String

    init(url: URL) {
        path = url.standardizedFileURL.path
        bundleID = Bundle(url: url)?.bundleIdentifier
        name = AppName.display(forPath: path)
    }

    var url: URL { URL(fileURLWithPath: path) }
    /// Schlüssel, über den laufende Apps zugeordnet werden.
    var key: String { bundleID ?? path }
}

struct DockFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var apps: [PinnedApp] = []
}

enum DockEntry: Codable, Hashable, Identifiable {
    case app(PinnedApp)
    case folder(DockFolder)

    var id: UUID {
        switch self {
        case .app(let a): a.id
        case .folder(let f): f.id
        }
    }
}

enum DockStyle: String, Codable, CaseIterable, Identifiable {
    case pill, bar
    var id: String { rawValue }
    var title: String { self == .pill ? "Schwebende Pille" : "Schlanke Leiste" }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct DockSettings: Codable, Equatable {
    var style: DockStyle = .pill
    var iconSize: Double = 42
    var appearance: AppearanceMode = .system
    var autoHide = false
    var hideSystemDock = true
    var showLauncher = true
    var showRunningApps = true
    var windowPreviews = true
    var clickHidesActiveApp = true
    var showClock = true
    var showDate = true
    var showBattery = true
    var showNowPlaying = true
    var launcherHotKey = true

    init() {}

    // Fehlende Schlüssel (z. B. nach Updates) fallen auf Standardwerte zurück.
    init(from decoder: Decoder) throws {
        let d = DockSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        style = v(.style, d.style)
        iconSize = v(.iconSize, d.iconSize)
        appearance = v(.appearance, d.appearance)
        autoHide = v(.autoHide, d.autoHide)
        hideSystemDock = v(.hideSystemDock, d.hideSystemDock)
        showLauncher = v(.showLauncher, d.showLauncher)
        showRunningApps = v(.showRunningApps, d.showRunningApps)
        windowPreviews = v(.windowPreviews, d.windowPreviews)
        clickHidesActiveApp = v(.clickHidesActiveApp, d.clickHidesActiveApp)
        showClock = v(.showClock, d.showClock)
        showDate = v(.showDate, d.showDate)
        showBattery = v(.showBattery, d.showBattery)
        showNowPlaying = v(.showNowPlaying, d.showNowPlaying)
        launcherHotKey = v(.launcherHotKey, d.launcherHotKey)
    }
}

enum AppName {
    static func display(forPath path: String) -> String {
        var n = FileManager.default.displayName(atPath: path)
        if n.hasSuffix(".app") { n.removeLast(4) }
        return n
    }

    static func key(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? app.bundleURL?.standardizedFileURL.path ?? "pid-\(app.processIdentifier)"
    }
}

enum DockMetrics {
    static let pillRadius: CGFloat = 20
    static let pillBottomGap: CGFloat = 8
    static let popupRadius: CGFloat = 14
    static func barIcon(_ s: DockSettings) -> CGFloat { max(22, (s.iconSize * 0.66).rounded()) }
    static func barHeight(_ s: DockSettings) -> CGFloat { barIcon(s) + 18 }
}
