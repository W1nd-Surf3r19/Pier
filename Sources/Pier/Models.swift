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

/// Eine angepinnte Datei (kein Programm, kein Ordner) – Klick öffnet sie mit ihrer Standard-App.
struct DockFile: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var name: String

    init(url: URL) {
        path = url.standardizedFileURL.path
        name = FileManager.default.displayName(atPath: path)
    }

    var url: URL { URL(fileURLWithPath: path) }
}

enum DockEntry: Codable, Hashable, Identifiable {
    case app(PinnedApp)
    case folder(DockFolder)
    case stack(DockStack)
    case separator(DockSeparator)
    case file(DockFile)

    var id: UUID {
        switch self {
        case .app(let a): a.id
        case .folder(let f): f.id
        case .stack(let s): s.id
        case .separator(let s): s.id
        case .file(let f): f.id
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

/// Wo die Pille an ihrer Kante sitzt – oder frei verschoben.
enum PillPlacement: String, Codable, CaseIterable, Identifiable {
    case start, center, end, free
    var id: String { rawValue }
    func title(vertical: Bool) -> String {
        switch self {
        case .start: vertical ? "Oben" : "Links"
        case .center: "Mitte"
        case .end: vertical ? "Unten" : "Rechts"
        case .free: "Frei"
        }
    }
}

/// Reihenfolge der laufenden, nicht angepinnten Apps (angepinnte bleiben in deiner Reihenfolge).
enum RunningOrder: String, Codable, CaseIterable, Identifiable {
    case launch, alphabetical, grouped
    var id: String { rawValue }
    var title: String {
        switch self {
        case .launch: "Nach Start"
        case .alphabetical: "Alphabetisch"
        case .grouped: "In Gruppen einsortieren"
        }
    }
}

/// Mehrere Fenster einer App in der Leiste: ein Tab je Fenster oder ein gemeinsamer Tab.
enum WindowGrouping: String, Codable, CaseIterable, Identifiable {
    case never, automatic, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: "Nie"
        case .automatic: "Automatisch"
        case .always: "Immer"
        }
    }
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

/// Beschriftung der Tabs in der Leiste.
enum BarLabels: String, Codable, CaseIterable, Identifiable {
    case automatic, iconsOnly, iconAndText
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatisch"
        case .iconsOnly: "Nur Icons"
        case .iconAndText: "Icon und Text"
        }
    }
}

/// Farbthema: Akzentfarbe (aktive App, Fortschritt, Auswahl) und eine leichte Tönung des Dock-Glases.
enum DockTheme: String, Codable, CaseIterable, Identifiable {
    case system, graphite, midnight, ocean, lavender, coral, sage, sunset, clear, custom, nowPlaying
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
        case .clear: "Transparent"
        case .custom: "Eigene Farbe"
        case .nowPlaying: "Now Playing"
        }
    }
    /// Feste Akzentfarbe; bei „Eigene Farbe“ und „Now Playing“ kommt sie aus `colors(custom:artwork:)`.
    private var accent: Color {
        switch self {
        case .system, .clear, .custom, .nowPlaying: .accentColor
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
    private var glass: [Color] {
        switch self {
        case .system, .clear, .custom, .nowPlaying: []
        case .graphite: [Color(white: 0.55), Color(white: 0.3)]
        case .midnight: [.indigo, .blue]
        case .ocean: [.blue, .cyan]
        case .lavender: [.purple, .indigo]
        case .coral: [.pink, .orange]
        case .sage: [.green, .mint]
        case .sunset: [.orange, .pink]
        }
    }
    /// Kein Milchglas im Dock – der Hintergrund scheint unverändert durch.
    var isClear: Bool { self == .clear }

    /// Aufgelöste Farben. `artwork` = Grundfarbe des aktuellen Covers (nil = nichts spielt → wie „System“).
    func colors(custom: Color, artwork: Color?) -> ThemeColors {
        switch self {
        case .custom: ThemeColors(accent: custom, glass: [custom, custom.opacity(0.6)], isClear: false)
        case .nowPlaying:
            if let artwork { ThemeColors(accent: artwork, glass: [artwork, artwork.opacity(0.6)], isClear: false) }
            else { ThemeColors(accent: .accentColor, glass: [], isClear: false) }
        default: ThemeColors(accent: accent, glass: glass, isClear: isClear)
        }
    }
}

/// Die tatsächlich gezeichneten Farben eines Themas – ändert sich auch ohne neue Einstellung (Cover wechselt).
struct ThemeColors: Equatable {
    var accent: Color
    var glass: [Color]
    var isClear: Bool

    static let fallback = ThemeColors(accent: .accentColor, glass: [], isClear: false)

    var glassTint: LinearGradient {
        LinearGradient(colors: glass.isEmpty ? [.clear] : glass.map { $0.opacity(0.2) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension NSColor {
    /// „#RRGGBB“ → Farbe (sRGB).
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }
}

struct DockSettings: Codable, Equatable {
    var style: DockStyle = .pill
    var iconSize: Double = 42
    var appearance: AppearanceMode = .system
    var theme: DockTheme = .system
    var barLabels: BarLabels = .automatic
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
    /// Bei mehreren Docks: jedes zeigt nur laufende Apps mit Fenstern auf seinem Monitor.
    var perScreenApps = false
    var titlebarScroll = false
    var altTab = false
    var edge: DockEdge = .bottom
    var allScreens = false
    /// Bildschirm des Docks (Display-UUID), nil = Hauptbildschirm. Gilt nur ohne „alle Bildschirme“.
    var screenUUID: String?
    var placement: PillPlacement = .center
    /// Position der frei verschobenen Pille als Anteil (0…1) des freien Bildschirmbereichs.
    var freeOrigin: CGPoint?
    var runningOrder: RunningOrder = .launch
    var windowGrouping: WindowGrouping = .never
    /// Zeilen der Leiste oben/unten (1…5), per Ziehen am Innenrand.
    var barRows = 1
    var customColor = "#3478F6"
    var showSound = true
    var showDevices = true
    /// Bluetooth-Geräte in der Geräte-Liste (fragt beim ersten Öffnen nach der Bluetooth-Erlaubnis).
    var showBluetooth = false
    /// Eigene Ordner im Launcher (Pfade).
    var launcherFolders: [String] = []
    /// Gruppenreihenfolge fürs intelligente Anordnen (AppCategory-Rohwerte, links → rechts). Leer = automatisch.
    var groupOrder: [String] = []
    /// Laufende Apps, die Pier nicht zeigt (Schlüssel → Name).
    var excludedApps: [String: String] = [:]

    init() {}

    /// Kante des Docks – Pille und Leiste können an alle vier.
    var effectiveEdge: DockEdge { edge }
    /// Frei verschobene Pille: kein Ausblenden an der Kante, kein Freihalten für Fenster.
    var isFree: Bool { style == .pill && placement == .free }

    // Fehlende Schlüssel (z. B. nach Updates) fallen auf Standardwerte zurück.
    init(from decoder: Decoder) throws {
        let d = DockSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        style = v(.style, d.style)
        iconSize = v(.iconSize, d.iconSize)
        appearance = v(.appearance, d.appearance)
        theme = v(.theme, d.theme)
        barLabels = v(.barLabels, d.barLabels)
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
        perScreenApps = v(.perScreenApps, d.perScreenApps)
        titlebarScroll = v(.titlebarScroll, d.titlebarScroll)
        altTab = v(.altTab, d.altTab)
        edge = v(.edge, d.edge)
        allScreens = v(.allScreens, d.allScreens)
        screenUUID = v(.screenUUID, d.screenUUID)
        placement = v(.placement, d.placement)
        freeOrigin = v(.freeOrigin, d.freeOrigin)
        runningOrder = v(.runningOrder, d.runningOrder)
        windowGrouping = v(.windowGrouping, d.windowGrouping)
        barRows = min(max(v(.barRows, d.barRows), 1), DockMetrics.maxBarRows)
        // Configs von vor der Leiste an allen Kanten: dort konnte die Kante noch aus Pillen-Zeiten auf „links“ stehen,
        // die Leiste war aber unten. Einmalig unten lassen (barRows wird ab jetzt mitgespeichert).
        if !c.contains(.barRows), style == .bar { edge = .bottom }
        customColor = v(.customColor, d.customColor)
        showSound = v(.showSound, d.showSound)
        showDevices = v(.showDevices, d.showDevices)
        showBluetooth = v(.showBluetooth, d.showBluetooth)
        launcherFolders = v(.launcherFolders, d.launcherFolders)
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
    static let maxBarRows = 5
    static let barRowSpacing: CGFloat = 4
    static func barIcon(_ s: DockSettings) -> CGFloat { max(22, (s.iconSize * 0.66).rounded()) }
    /// Höhe eines Tabs (einer Zeile) der Leiste.
    static func barTabHeight(_ s: DockSettings) -> CGFloat { barIcon(s) + 6 }
    /// Mehrere Zeilen nur oben/unten; seitlich ist die Leiste eine Spalte.
    static func barRows(_ s: DockSettings) -> Int { s.effectiveEdge.isVertical ? 1 : min(max(s.barRows, 1), maxBarRows) }
    /// Breite der seitlichen Leiste: schmal bei „Nur Icons“, sonst mit Titeln.
    static func barWidth(_ s: DockSettings) -> CGFloat { s.barLabels == .iconsOnly ? barIcon(s) + 18 : 210 }
    /// Dicke der Leiste quer zu ihrer Kante (Höhe oben/unten, Breite seitlich).
    static func barThickness(_ s: DockSettings) -> CGFloat {
        if s.effectiveEdge.isVertical { return barWidth(s) }
        let rows = CGFloat(barRows(s))
        return rows * barTabHeight(s) + (rows - 1) * barRowSpacing + 12
    }
}
