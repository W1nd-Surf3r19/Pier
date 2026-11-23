import AppKit
import CoreGraphics

// MARK: Kategorien

enum AppCategory: String, CaseIterable, Identifiable {
    case finder, internet, communication, ai, development, work, creative, media, games, utilities, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .finder: "Finder"
        case .internet: "Internet"
        case .communication: "Kommunikation"
        case .ai: "KI-Assistenten"
        case .development: "Entwicklung"
        case .work: "Arbeit & Notizen"
        case .creative: "Kreativ"
        case .media: "Musik & Video"
        case .games: "Spiele"
        case .utilities: "Werkzeuge"
        case .other: "Sonstiges"
        }
    }

    var symbol: String {
        switch self {
        case .finder: "face.smiling"
        case .internet: "globe"
        case .communication: "bubble.left.and.bubble.right"
        case .ai: "sparkles"
        case .development: "chevron.left.forwardslash.chevron.right"
        case .work: "doc.text"
        case .creative: "paintbrush"
        case .media: "play.circle"
        case .games: "gamecontroller"
        case .utilities: "wrench.and.screwdriver"
        case .other: "square.grid.2x2"
        }
    }
}

enum SmartArranger {
    /// Eigene Zuordnung zuerst – die Kategorien in den Apps selbst sind oft falsch
    /// (Beeper nennt sich „Entwicklerwerkzeug“, Safari „Produktivität“).
    private static let exact: [String: AppCategory] = [
        // Internet
        "com.apple.Safari": .internet, "net.imput.helium": .internet, "org.mozilla.firefox": .internet,
        "company.thebrowser.Browser": .internet, "com.brave.Browser": .internet, "com.microsoft.edgemac": .internet,
        "com.vivaldi.Vivaldi": .internet, "com.kagi.kagimacOS": .internet, "com.operasoftware.Opera": .internet,
        "app.zen-browser.zen": .internet,
        // Kommunikation
        "com.apple.mail": .communication, "com.apple.MobileSMS": .communication, "com.apple.FaceTime": .communication,
        "com.automattic.beeper.desktop": .communication, "com.hnc.Discord": .communication,
        "com.tinyspeck.slackmacgap": .communication, "net.whatsapp.WhatsApp": .communication,
        "desktop.WhatsApp": .communication, "ru.keepcoder.Telegram": .communication,
        "org.telegram.desktop": .communication, "org.whispersystems.signal-desktop": .communication,
        "com.microsoft.teams2": .communication, "com.microsoft.teams": .communication, "us.zoom.xos": .communication,
        "com.microsoft.Outlook": .communication, "com.readdle.smartemail-Mac": .communication,
        // KI
        "com.anthropic.claudefordesktop": .ai, "com.openai.chat": .ai, "com.google.GeminiMacOS": .ai,
        "ai.perplexity.mac": .ai,
        // Entwicklung
        "com.googlecode.iterm2": .development, "com.apple.Terminal": .development, "com.microsoft.VSCode": .development,
        "com.todesktop.230313mzl4w4u92": .development, "dev.zed.Zed": .development, "com.docker.docker": .development,
        "dev.kdrag0n.MacVirt": .development, "com.github.GitHubClient": .development, "com.mitchellh.ghostty": .development,
        "dev.warp.Warp-Stable": .development, "com.postmanlabs.mac": .development, "com.apple.TestFlight": .development,
        // Arbeit & Notizen
        "com.apple.iCal": .work, "com.apple.Notes": .work, "com.apple.reminders": .work, "com.apple.Preview": .work,
        "md.obsidian": .work, "notion.id": .work, "com.microsoft.onenote.mac": .work, "com.microsoft.Word": .work,
        "com.microsoft.Excel": .work, "com.microsoft.Powerpoint": .work, "com.moneymoney-app.retail": .work,
        "com.culturedcode.ThingsMac": .work,
        // Kreativ
        "com.apple.Photos": .creative, "org.upscayl.Upscayl": .creative, "com.figma.Desktop": .creative,
        "com.bohemiancoding.sketch3": .creative, "com.apple.FinalCut": .creative, "com.apple.iMovieApp": .creative,
        "com.apple.garageband10": .creative, "com.apple.logic10": .creative,
        // Musik & Video
        "com.apple.Music": .media, "com.spotify.client": .media, "com.apple.podcasts": .media, "com.apple.TV": .media,
        "com.colliderli.iina": .media, "org.videolan.vlc": .media,
        // Werkzeuge
        "com.apple.finder": .finder, "com.apple.systempreferences": .utilities, "com.bitwarden.desktop": .utilities,
        "com.apple.ActivityMonitor": .utilities, "com.apple.AppStore": .utilities, "com.apple.Maps": .utilities,
    ]

    private static let prefixes: [(String, AppCategory)] = [
        ("com.google.Chrome", .internet), ("com.apple.dt.", .development), ("com.jetbrains.", .development),
        ("com.sublimetext.", .development), ("com.apple.iWork.", .work), ("com.adobe.", .creative),
        ("com.pixelmatorteam.", .creative), ("com.seriflabs.", .creative), ("com.1password", .utilities),
        ("com.riotgames.", .games),
    ]

    private static let plist: [String: AppCategory] = [
        "public.app-category.social-networking": .communication,
        "public.app-category.developer-tools": .development,
        "public.app-category.productivity": .work, "public.app-category.business": .work,
        "public.app-category.finance": .work, "public.app-category.education": .work,
        "public.app-category.reference": .work,
        "public.app-category.graphics-design": .creative, "public.app-category.photography": .creative,
        "public.app-category.video": .media, "public.app-category.music": .media,
        "public.app-category.entertainment": .media,
        "public.app-category.utilities": .utilities,
    ]

    nonisolated static func category(bundleID: String?, plistCategory: String?) -> AppCategory {
        if let id = bundleID {
            if let c = exact[id] { return c }
            if let c = prefixes.first(where: { id.hasPrefix($0.0) })?.1 { return c }
        }
        if let p = plistCategory {
            if let c = plist[p] { return c }
            if p.hasPrefix("public.app-category.") && p.hasSuffix("-games") || p == "public.app-category.games" { return .games }
        }
        return .other
    }

    static func category(of app: PinnedApp) -> AppCategory {
        let plist = Bundle(url: app.url)?.infoDictionary?["LSApplicationCategoryType"] as? String
        return category(bundleID: app.bundleID, plistCategory: plist)
    }

    // MARK: Planer

    struct Group: Identifiable, Equatable {
        let category: AppCategory
        var apps: [PinnedApp]
        var id: AppCategory { category }
    }

    struct Plan: Equatable {
        var groups: [Group] = []
        var rare: [PinnedApp] = []
        var entries: [DockEntry] = []
    }

    struct Options {
        var separators = true
        var rareIntoFolder = false
        /// Vom Nutzer festgelegte Gruppenreihenfolge (links → rechts). Fehlende Gruppen folgen automatisch dahinter.
        var order: [AppCategory] = []
    }

    static let finderID = "com.apple.finder"
    static let rareFolderName = "Selten benutzt"

    /// Neue Anordnung: Gruppen in der festgelegten Reihenfolge, sonst Finder vorn und dann die meistbenutzte Gruppe
    /// (darin die meistbenutzte App zuerst); danach Ordner und Stapel in bisheriger Reihenfolge. Keine App geht verloren.
    nonisolated static func plan(entries: [DockEntry], add suggestions: [PinnedApp], options: Options,
                                 score: (String) -> Double, isRare: (String) -> Bool,
                                 category: (PinnedApp) -> AppCategory) -> Plan {
        var apps: [PinnedApp] = []
        var keep: [DockEntry] = []   // Ordner und Stapel
        var inFolders = Set<String>()
        for e in entries {
            switch e {
            case .app(let a): apps.append(a)
            case .folder(let f):
                keep.append(e)
                f.apps.forEach { inFolders.insert($0.key) }
            case .stack, .file: keep.append(e)
            case .separator: break   // werden neu gesetzt
            }
        }
        var seen = Set(apps.map(\.key)).union(inFolders)
        for s in suggestions where !seen.contains(s.key) {
            apps.append(s)
            seen.insert(s.key)
        }

        var plan = Plan()
        if options.rareIntoFolder {
            plan.rare = apps.filter { isRare($0.key) }
            apps.removeAll { isRare($0.key) }
        }

        var byCategory: [AppCategory: [PinnedApp]] = [:]
        for a in apps { byCategory[category(a), default: []].append(a) }
        let rank = Dictionary(uniqueKeysWithValues: AppCategory.allCases.enumerated().map { ($1, $0) })
        func total(_ c: AppCategory) -> Double { byCategory[c, default: []].reduce(0) { $0 + score($1.key) } }
        let automatic = byCategory.keys.sorted {
            ($0 == .finder ? 1 : 0, total($0), -rank[$0]!) > ($1 == .finder ? 1 : 0, total($1), -rank[$1]!)
        }
        let chosen = Dictionary(options.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        plan.groups = automatic.enumerated()
            .sorted { (chosen[$0.element] ?? Int.max, $0.offset) < (chosen[$1.element] ?? Int.max, $1.offset) }
            .map(\.element)
            .map { c in
                Group(category: c, apps: byCategory[c]!.sorted {
                    (score($0.key), $1.name.lowercased()) > (score($1.key), $0.name.lowercased())
                })
            }

        // Einträge zusammensetzen
        var blocks: [[DockEntry]] = plan.groups.map { $0.apps.map(DockEntry.app) }
        if !plan.rare.isEmpty {
            var keepWithRare = keep
            if let i = keepWithRare.firstIndex(where: { if case .folder(let f) = $0 { f.name == rareFolderName } else { false } }),
               case .folder(var f) = keepWithRare[i] {
                f.apps += plan.rare.filter { r in !f.apps.contains { $0.key == r.key } }
                keepWithRare[i] = .folder(f)
            } else {
                keepWithRare.append(.folder(DockFolder(name: rareFolderName, apps: plan.rare)))
            }
            keep = keepWithRare
        }
        if !keep.isEmpty { blocks.append(keep) }
        for (i, b) in blocks.enumerated() {
            if i > 0 && options.separators { plan.entries.append(.separator(DockSeparator())) }
            plan.entries += b
        }
        return plan
    }
}

// MARK: Nutzung lernen

/// Vordergrund-Zeit und Starts je App, mit Halbwertszeit – was du lange nicht benutzt hast, verliert Gewicht.
struct UsageBook: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var name: String
        var path: String
        var seconds: Double = 0
        var launches: Double = 0
        var updated: Date
    }

    var trackingSince: Date
    var apps: [String: Entry] = [:]

    static let halfLife: TimeInterval = 14 * 86_400

    static func decay(_ v: Double, from: Date, to: Date) -> Double {
        v * pow(0.5, max(0, to.timeIntervalSince(from)) / halfLife)
    }

    mutating func add(key: String, name: String, path: String, seconds: Double = 0, launches: Double = 0, now: Date) {
        var e = apps[key] ?? Entry(name: name, path: path, updated: now)
        e.seconds = Self.decay(e.seconds, from: e.updated, to: now) + seconds
        e.launches = Self.decay(e.launches, from: e.updated, to: now) + launches
        e.updated = now
        e.name = name
        e.path = path
        apps[key] = e
    }

    /// Punkte ≈ Minuten Nutzung + 5 je Start, gealtert bis `now`.
    func score(_ key: String, now: Date) -> Double {
        guard let e = apps[key] else { return 0 }
        return Self.decay(e.seconds / 60 + e.launches * 5, from: e.updated, to: now)
    }

    func trackedDays(now: Date) -> Int { Int(now.timeIntervalSince(trackingSince) / 86_400) }

    /// Gezählte Sekunden einer Vordergrund-Sitzung: ohne Leerlauf (über 5 min) und höchstens 2 h am Stück.
    static func counted(elapsed: TimeInterval, idle: TimeInterval) -> Double {
        let active = idle > 300 ? elapsed - idle : elapsed
        return min(max(active, 0), 7_200)
    }
}

@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    @Published private(set) var book: UsageBook
    private var session: (key: String, name: String, path: String, since: Date)?
    private var timer: Timer?
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pier", isDirectory: true)
        fileURL = base.appendingPathComponent("usage.json")
        book = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(UsageBook.self, from: $0) }
            ?? UsageBook(trackingSince: Date())
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { UsageTracker.shared.activated(app) }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { UsageTracker.shared.launched(app) }
        }
        // Schlaf, Bildschirmsperre, Benutzerwechsel: Sitzung beenden, sonst zählt die Nacht mit.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UsageTracker.shared.closeSession(reopen: false) }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UsageTracker.shared.activated(NSWorkspace.shared.frontmostApplication) }
            }
        }
        activated(NSWorkspace.shared.frontmostApplication)
        // Jede Minute zwischenbuchen und speichern.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { UsageTracker.shared.closeSession(reopen: true) }
        }
    }

    func score(_ key: String) -> Double { book.score(key, now: Date()) }

    private static func describe(_ app: NSRunningApplication?) -> (key: String, name: String, path: String)? {
        guard let app, app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let path = app.bundleURL?.standardizedFileURL.path else { return nil }
        return (AppName.key(app), app.localizedName ?? AppName.display(forPath: path), path)
    }

    private func activated(_ app: NSRunningApplication?) {
        closeSession(reopen: false)
        guard let d = Self.describe(app) else { return }
        session = (d.key, d.name, d.path, Date())
    }

    private func launched(_ app: NSRunningApplication?) {
        guard let d = Self.describe(app) else { return }
        book.add(key: d.key, name: d.name, path: d.path, launches: 1, now: Date())
    }

    func closeSession(reopen: Bool) {
        guard let s = session else { return }
        let now = Date()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let secs = UsageBook.counted(elapsed: now.timeIntervalSince(s.since), idle: idle)
        if secs > 0 { book.add(key: s.key, name: s.name, path: s.path, seconds: secs, now: now) }
        session = reopen ? (s.key, s.name, s.path, now) : nil
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
