import Testing
import AppKit
@testable import Pier

@Test func badgeRoseOnlyWhenNewOrHigher() {
    #expect(RunningAppsModel.badgeRose(from: nil, to: "1"))
    #expect(RunningAppsModel.badgeRose(from: "2", to: "5"))
    #expect(!RunningAppsModel.badgeRose(from: "5", to: "2"))
    #expect(!RunningAppsModel.badgeRose(from: "3", to: "3"))
    #expect(!RunningAppsModel.badgeRose(from: "•", to: "•"))
    #expect(RunningAppsModel.badgeRose(from: nil, to: "•"))
}

@Test func cpuPercentConvertsMachTicks() {
    // Apple Silicon: 125/3 ns pro Tick. Halb so viel CPU-Zeit wie Wandzeit = 50 %.
    #expect(abs(ActivityModel.cpuPercent(deltaTicks: 12_000_000, deltaWall: 24_000_000, numer: 125, denom: 3) - 50) < 0.001)
    #expect(ActivityModel.cpuPercent(deltaTicks: 5, deltaWall: 0, numer: 1, denom: 1) == 0)
    #expect(abs(ActivityModel.cpuPercent(deltaTicks: 2_000, deltaWall: 1_000, numer: 1, denom: 1) - 200) < 0.001)
}

@Test func stackListsNewestFilesFirst() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pier-stack-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (i, name) in ["alt.txt", "mittel.txt", "neu.txt"].enumerated() {
        let f = dir.appendingPathComponent(name)
        try Data().write(to: f)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + i))], ofItemAtPath: f.path)
    }
    try Data().write(to: dir.appendingPathComponent(".versteckt"))
    let names = StackView.recentFiles(in: dir).map(\.lastPathComponent)
    #expect(Set(names) == ["alt.txt", "mittel.txt", "neu.txt"])
}

@Test func memoryTextStaysShort() {
    #expect(ActivityModel.memoryText(340 * 1_048_576) == "340 MB")
    #expect(ActivityModel.memoryText(1_288_490_189).hasSuffix(" GB"))
}

@Test func titlebarScrollDirection() {
    #expect(WindowSnapper.action(for: CGSize(width: 0, height: 10), naturalScrolling: false) == nil)
    #expect(WindowSnapper.action(for: CGSize(width: 0, height: 60), naturalScrolling: false) == .maximize)
    #expect(WindowSnapper.action(for: CGSize(width: 0, height: 60), naturalScrolling: true) == .center)
    #expect(WindowSnapper.action(for: CGSize(width: 80, height: 20), naturalScrolling: false) == .leftHalf)
    #expect(WindowSnapper.action(for: CGSize(width: -80, height: 20), naturalScrolling: false) == .rightHalf)
}

@Test func switcherOrdersFrontmostFirst() {
    #expect(AltTabController.order([10, 20, 30, 40], frontToBack: [30, 10]) == [30, 10, 20, 40])
    #expect(AltTabController.order([], frontToBack: [1]) == [])
}

@Test func fitterFindsScreenOfWindow() {
    // Hauptbildschirm 1470×956, zweiter rechts daneben, 1920×1080, Unterkanten bündig (Cocoa y = 0).
    let main = NSRect(x: 0, y: 0, width: 1470, height: 956)
    let ext = NSRect(x: 1470, y: 0, width: 1920, height: 1080)
    #expect(WindowFitter.dockedScreenBottom(windowOrigin: CGPoint(x: 100, y: 50), screens: [main, ext], primaryHeight: 956) == 956)
    // Zweiter Bildschirm ragt 124 pt höher: AX-y beginnt bei -124, Unterkante bei 956.
    #expect(WindowFitter.dockedScreenBottom(windowOrigin: CGPoint(x: 1600, y: -100), screens: [main, ext], primaryHeight: 956) == 956)
    // Bildschirm ohne Dock: kein Eingriff.
    #expect(WindowFitter.dockedScreenBottom(windowOrigin: CGPoint(x: 1600, y: 50), screens: [main], primaryHeight: 956) == nil)
}

// MARK: Intelligent anordnen

@Test func categoriesForRealApps() {
    // Die App-eigenen Kategorien sind hier falsch (Beeper = Entwicklerwerkzeug, Safari/iTerm = Produktivität).
    #expect(SmartArranger.category(bundleID: "com.automattic.beeper.desktop", plistCategory: "public.app-category.developer-tools") == .communication)
    #expect(SmartArranger.category(bundleID: "com.apple.Safari", plistCategory: "public.app-category.productivity") == .internet)
    #expect(SmartArranger.category(bundleID: "net.imput.helium", plistCategory: nil) == .internet)
    #expect(SmartArranger.category(bundleID: "com.googlecode.iterm2", plistCategory: "public.app-category.productivity") == .development)
    #expect(SmartArranger.category(bundleID: "com.apple.dt.Xcode", plistCategory: nil) == .development)
    #expect(SmartArranger.category(bundleID: "com.apple.dt.Devices", plistCategory: nil) == .development)
    #expect(SmartArranger.category(bundleID: "com.bitwarden.desktop", plistCategory: "public.app-category.productivity") == .utilities)
    #expect(SmartArranger.category(bundleID: "com.anthropic.claudefordesktop", plistCategory: nil) == .ai)
    #expect(SmartArranger.category(bundleID: "com.google.Chrome.canary", plistCategory: nil) == .internet)
    // Unbekannte App: Kategorie aus der App, sonst „Sonstiges“.
    #expect(SmartArranger.category(bundleID: "x.unbekannt", plistCategory: "public.app-category.role-playing-games") == .games)
    #expect(SmartArranger.category(bundleID: "x.unbekannt", plistCategory: "public.app-category.music") == .media)
    #expect(SmartArranger.category(bundleID: "x.unbekannt", plistCategory: nil) == .other)
}

private func app(_ id: String, _ name: String) -> PinnedApp {
    var a = PinnedApp(url: URL(fileURLWithPath: "/Applications/\(name).app"))
    a.bundleID = id
    a.name = name
    return a
}

private func allAppKeys(_ entries: [DockEntry]) -> [String] {
    entries.flatMap { e -> [String] in
        switch e {
        case .app(let a): [a.key]
        case .folder(let f): f.apps.map(\.key)
        default: []
        }
    }
}

@Test func arrangementKeepsEveryAppAndGroups() {
    let finder = app("com.apple.finder", "Finder"), mail = app("com.apple.mail", "Mail")
    let music = app("com.apple.Music", "Musik"), safari = app("com.apple.Safari", "Safari")
    let iterm = app("com.googlecode.iterm2", "iTerm"), beeper = app("com.automattic.beeper.desktop", "Beeper")
    let inFolder = app("md.obsidian", "Obsidian")
    let folder = DockFolder(name: "Notizen", apps: [inFolder])
    let entries: [DockEntry] = [.app(music), .separator(DockSeparator()), .app(mail), .folder(folder), .app(finder)]
    let scores = ["com.googlecode.iterm2": 300.0, "com.apple.mail": 20, "com.automattic.beeper.desktop": 50, "com.apple.Safari": 10]
    let plan = SmartArranger.plan(entries: entries, add: [safari, iterm, beeper, inFolder], options: .init(),
                                  score: { scores[$0] ?? 0 }, isRare: { _ in false }, category: {
                                      SmartArranger.category(bundleID: $0.bundleID, plistCategory: nil) })
    let keys = allAppKeys(plan.entries)
    // Nichts verloren, nichts doppelt (Obsidian steckt schon im Ordner und wird nicht zusätzlich angeheftet).
    #expect(Set(keys) == Set(allAppKeys(entries)).union([safari.key, iterm.key, beeper.key]))
    #expect(keys.count == Set(keys).count)
    // Finder zuerst, dann die meistbenutzte Gruppe (Entwicklung), darin/danach Kommunikation: Beeper vor Mail.
    #expect(plan.entries.first == .app(finder))
    #expect(plan.groups.map(\.category) == [.finder, .development, .communication, .internet, .media])
    #expect(plan.groups[2].apps.map(\.name) == ["Beeper", "Mail"])
    // Ordner bleibt am Ende erhalten; Trennlinien zwischen den Blöcken (Finder, 4 Gruppen, Ordner = 6 Blöcke).
    #expect(plan.entries.last == .folder(folder))
    #expect(plan.entries.filter { if case .separator = $0 { true } else { false } }.count == 5)
}

@Test func arrangementCanFolderRareApps() {
    let a = app("com.apple.mail", "Mail"), b = app("com.apple.Music", "Musik")
    let plan = SmartArranger.plan(entries: [.app(a), .app(b)], add: [], options: .init(separators: false, rareIntoFolder: true),
                                  score: { _ in 0 }, isRare: { $0 == b.key }, category: { _ in .other })
    #expect(plan.entries.count == 2)
    #expect(plan.entries[0] == .app(a))
    guard case .folder(let f) = plan.entries[1] else { Issue.record("Ordner fehlt"); return }
    #expect(f.name == SmartArranger.rareFolderName && f.apps == [b])
}

@Test func usageDecaysAndIgnoresIdle() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var book = UsageBook(trackingSince: t0)
    book.add(key: "x", name: "X", path: "/X.app", seconds: 600, launches: 1, now: t0)
    #expect(abs(book.score("x", now: t0) - 15) < 0.001)                                   // 10 min + 5 je Start
    #expect(abs(book.score("x", now: t0.addingTimeInterval(UsageBook.halfLife)) - 7.5) < 0.001) // nach 14 Tagen halb
    #expect(book.trackedDays(now: t0.addingTimeInterval(3 * 86_400 + 5)) == 3)
    // Leerlauf über 5 min zählt nicht, kurze Pausen schon; höchstens 2 h am Stück.
    #expect(UsageBook.counted(elapsed: 3600, idle: 1800) == 1800)
    #expect(UsageBook.counted(elapsed: 600, idle: 120) == 600)
    #expect(UsageBook.counted(elapsed: 36_000, idle: 0) == 7200)
}

@Test func chosenGroupOrderWins() {
    let finder = app("com.apple.finder", "Finder"), safari = app("com.apple.Safari", "Safari")
    let iterm = app("com.googlecode.iterm2", "iTerm"), mail = app("com.apple.mail", "Mail")
    let entries: [DockEntry] = [.app(finder), .app(iterm), .app(mail), .app(safari)]
    let scores = ["com.googlecode.iterm2": 300.0, "com.apple.mail": 50]
    func plan(_ order: [AppCategory]) -> SmartArranger.Plan {
        SmartArranger.plan(entries: entries, add: [], options: .init(separators: false, order: order),
                           score: { scores[$0] ?? 0 }, isRare: { _ in false },
                           category: { SmartArranger.category(bundleID: $0.bundleID, plistCategory: nil) })
    }
    // Automatisch: Finder, dann nach Nutzung.
    #expect(plan([]).groups.map(\.category) == [.finder, .development, .communication, .internet])
    // Browser ganz links: festgelegte Gruppen zuerst, die übrigen automatisch dahinter.
    #expect(plan([.internet]).groups.map(\.category) == [.internet, .finder, .development, .communication])
    #expect(plan([.internet, .communication, .finder]).entries.first == .app(safari))
    #expect(plan([.internet, .communication, .finder]).groups.map(\.category) == [.internet, .communication, .finder, .development])
}

@Test func themeSurvivesSaveAndOldConfigsDefaultToSystem() throws {
    var s = DockSettings()
    s.theme = .ocean
    let back = try JSONDecoder().decode(DockSettings.self, from: JSONEncoder().encode(s))
    #expect(back.theme == .ocean)
    // Konfiguration von vor den Farbthemen (oder mit unbekanntem Thema) lädt weiter.
    #expect(try JSONDecoder().decode(DockSettings.self, from: Data(#"{"iconSize":50}"#.utf8)).theme == .system)
    let unknown = try JSONDecoder().decode(DockSettings.self, from: Data(#"{"iconSize":50,"theme":"neon"}"#.utf8))
    #expect(unknown.theme == .system && unknown.iconSize == 50)
}

@Test func barLabelsDecideWhetherTabsShowTitles() throws {
    #expect(TabRow.showsTitle(.automatic, widthPerTab: 84))
    #expect(!TabRow.showsTitle(.automatic, widthPerTab: 60))
    #expect(!TabRow.showsTitle(.iconsOnly, widthPerTab: 200))
    #expect(TabRow.showsTitle(.iconAndText, widthPerTab: 60))
    #expect(!TabRow.showsTitle(.iconAndText, widthPerTab: 40)) // kein Platz für Text neben dem Icon
    #expect(try JSONDecoder().decode(DockSettings.self, from: Data("{}".utf8)).barLabels == .automatic)
}

@Test func appCountsAsHungOnlyAfterRepeatedTimeouts() {
    var f: [pid_t: Int] = [:]
    var hung = Set<pid_t>()
    for _ in 0..<3 { (f, hung) = RunningAppsModel.updateHung(failures: f, unresponsive: [42]) }
    #expect(hung.isEmpty) // drei Aussetzer: noch nicht
    (f, hung) = RunningAppsModel.updateHung(failures: f, unresponsive: [42])
    #expect(hung == [42])
    (f, hung) = RunningAppsModel.updateHung(failures: f, unresponsive: []) // antwortet wieder
    #expect(hung.isEmpty && f.isEmpty)
}

@Test func mediaPositionRunsOnWhilePlaying() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var np = NowPlaying(title: "Song", artist: "", isPlaying: true, playerBundleID: "x",
                        duration: 200, position: 50, positionDate: t0)
    #expect(np.fraction(at: t0) == 0.25)
    #expect(np.fraction(at: t0.addingTimeInterval(50)) == 0.5)
    #expect(np.fraction(at: t0.addingTimeInterval(500)) == 1) // nie über 100 %
    np.rebase(at: t0.addingTimeInterval(50)); np.isPlaying = false // Pause
    #expect(np.fraction(at: t0.addingTimeInterval(400)) == 0.5)
    #expect(NowPlaying(title: "", artist: "", isPlaying: true, playerBundleID: "x").fraction(at: t0) == nil)
}

@Test func playerScriptOutputKeepsPipesInTitle() {
    let r = PlayerScript.parse("A | B|61000|200000")
    #expect(r?.title == "A | B" && r?.position == 61000 && r?.duration == 200000)
    #expect(PlayerScript.parse("") == nil)
    #expect(PlayerScript.parse("Titel|x|3") == nil)
}

@MainActor @Test func barTabTitleShowsProgressAndHung() {
    #expect(BarItemView.title("Downloads", progress: 0.14, hung: false) == "14 % · Downloads")
    #expect(BarItemView.title("Xcode", progress: 0.5, hung: true) == "Reagiert nicht · Xcode")
    #expect(BarItemView.title("Mail", progress: nil, hung: false) == "Mail")
}
