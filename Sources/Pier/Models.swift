import AppKit
import SwiftUI

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

/// Ein echter Finder-Ordner (z. B. Downloads), dessen neueste Dateien als Stapel aufklappen.
struct DockStack: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var name: String

    init(url: URL) {
        path = url.standardizedFileURL.path
        name = FileManager.default.displayName(atPath: path)
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Trennlinie zwischen Gruppen (wie der Abstandhalter im Mac-Dock).
struct DockSeparator: Codable, Hashable, Identifiable {
    var id = UUID()
}

enum DockEntry: Codable, Hashable, Identifiable {
    case app(PinnedApp)
    case folder(DockFolder)
    case stack(DockStack)
    case separator(DockSeparator)

    var id: UUID {
        switch self {
        case .app(let a): a.id
        case .folder(let f): f.id
        case .stack(let s): s.id
        case .separator(let s): s.id
        }
    }
}

enum DockStyle: String, Codable, CaseIterable, Identifiable {
    case pill, bar
    var id: String { rawValue }
    var title: String { self == .pill ? "Schwebende Pille" : "Schlanke Leiste" }
}

enum DockEdge: String, Codable, CaseIterable, Identifiable {
    case bottom, left, right, top
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottom: "Unten"
        case .left: "Links"
        case .right: "Rechts"
        case .top: "Oben"
        }
    }
    var isVertical: Bool { self == .left || self == .right }
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

/// Farbthema: Akzentfarbe (aktive App, Fortschritt, Auswahl) und eine leichte Tönung des Dock-Glases.
enum DockTheme: String, Codable, CaseIterable, Identifiable {
    case system, graphite, midnight, ocean, lavender, coral, sage, sunset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .graphite: "Graphit"
        case .midnight: "Mitternacht"
        case .ocean: "Ozean"
        case .lavender: "Lavendel"
        case .coral: "Koralle"
        case .sage: "Salbei"
        case .sunset: "Abendrot"
        }
    }
    var accent: Color {
        switch self {
        case .system: .accentColor
        case .graphite: Color(nsColor: .systemGray)
        case .midnight: .indigo
        case .ocean: .cyan
        case .lavender: .purple
        case .coral: .pink
        case .sage: .mint
        case .sunset: .orange
        }
    }
    /// Verlauf für die Glas-Tönung (oben links → unten rechts). Leer = ungefärbtes Glas.
    var glass: [Color] {
        switch self {
        case .system: []
        case .graphite: [Color(white: 0.55), Color(white: 0.3)]
        case .midnight: [.indigo, .blue]
        case .ocean: [.blue, .cyan]
        case .lavender: [.purple, .indigo]
        case .coral: [.pink, .orange]
        case .sage: [.green, .mint]
        case .sunset: [.orange, .pink]
        }
    }
    var glassTint: LinearGradient {
        LinearGradient(colors: glass.isEmpty ? [.clear] : glass.map { $0.opacity(0.2) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct DockSettings: Codable, Equatable {
    var style: DockStyle = .pill
    var iconSize: Double = 42
    var appearance: AppearanceMode = .system
    var theme: DockTheme = .system
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
    var fitWindows = true
    var showBadges = true
    var appHotKeys = false
    var scrollCyclesWindows = true
    var showActivity = true
    var currentSpaceOnly = false
    var titlebarScroll = false
    var altTab = false
    var edge: DockEdge = .bottom
    var allScreens = false
    /// Gruppenreihenfolge fürs intelligente Anordnen (AppCategory-Rohwerte, links → rechts). Leer = automatisch.
    var groupOrder: [String] = []
    /// Laufende Apps, die Pier nicht zeigt (Schlüssel → Name).
    var excludedApps: [String: String] = [:]

    init() {}

    /// Die Leiste gibt es nur unten (Hohlkehlen, Fenster-Anpassung); seitlich nur die Pille.
    var effectiveEdge: DockEdge { style == .bar ? .bottom : edge }

    // Fehlende Schlüssel (z. B. nach Updates) fallen auf Standardwerte zurück.
    init(from decoder: Decoder) throws {
        let d = DockSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        style = v(.style, d.style)
        iconSize = v(.iconSize, d.iconSize)
        appearance = v(.appearance, d.appearance)
        theme = v(.theme, d.theme)
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
        fitWindows = v(.fitWindows, d.fitWindows)
        showBadges = v(.showBadges, d.showBadges)
        appHotKeys = v(.appHotKeys, d.appHotKeys)
        scrollCyclesWindows = v(.scrollCyclesWindows, d.scrollCyclesWindows)
        showActivity = v(.showActivity, d.showActivity)
        currentSpaceOnly = v(.currentSpaceOnly, d.currentSpaceOnly)
        titlebarScroll = v(.titlebarScroll, d.titlebarScroll)
        altTab = v(.altTab, d.altTab)
        edge = v(.edge, d.edge)
        allScreens = v(.allScreens, d.allScreens)
        groupOrder = v(.groupOrder, d.groupOrder)
        excludedApps = v(.excludedApps, d.excludedApps)
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
    /// Hohlkehle, mit der die Leiste in die runden Ecken angedockter Fenster übergeht.
    static let filletRadius: CGFloat = 22
    static let barCornerRadius: CGFloat = 14
    static func barIcon(_ s: DockSettings) -> CGFloat { max(22, (s.iconSize * 0.66).rounded()) }
    static func barHeight(_ s: DockSettings) -> CGFloat { barIcon(s) + 18 }
}
