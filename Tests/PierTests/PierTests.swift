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
    #expect(WindowFitter.dockedScreen(windowOrigin: CGPoint(x: 100, y: 50), screens: [main, ext], primaryHeight: 956)?.maxY == 956)
    // Zweiter Bildschirm ragt 124 pt höher: AX-y beginnt bei -124, Unterkante bei 956.
    let second = WindowFitter.dockedScreen(windowOrigin: CGPoint(x: 1600, y: -100), screens: [main, ext], primaryHeight: 956)
    #expect(second == CGRect(x: 1470, y: -124, width: 1920, height: 1080))
    // Bildschirm ohne Dock: kein Eingriff.
    #expect(WindowFitter.dockedScreen(windowOrigin: CGPoint(x: 1600, y: 50), screens: [main], primaryHeight: 956) == nil)
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

// MARK: Block 1 + 2 (uBar-Funktionen)

@Test func newSettingsSurviveRoundTrip() throws {
    var s = DockSettings()
    s.screenUUID = "ABC-123"
    s.placement = .free
    s.freeOrigin = CGPoint(x: 0.25, y: 0.75)
    s.runningOrder = .alphabetical
    s.windowGrouping = .always
    s.customColor = "#FF8800"
    s.showSound = false
    s.showDevices = false
    s.showBluetooth = true
    s.launcherFolders = ["/tmp/a"]
    s.theme = .nowPlaying
    let back = try JSONDecoder().decode(DockSettings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}

@Test func oldConfigFallsBackToDefaults() throws {
    let back = try JSONDecoder().decode(DockSettings.self, from: Data(#"{"style":"bar"}"#.utf8))
    var expected = DockSettings()
    expected.style = .bar
    #expect(back == expected)
}

@Test func pinnedFileRoundTripsAndSurvivesArranging() throws {
    let file = DockFile(url: URL(fileURLWithPath: "/tmp/Notiz.txt"))
    let entries: [DockEntry] = [.file(file)]
    #expect(try JSONDecoder().decode([DockEntry].self, from: JSONEncoder().encode(entries)) == entries)
    let plan = SmartArranger.plan(entries: entries, add: [], options: .init(), score: { _ in 0 },
                                  isRare: { _ in false }, category: { _ in .other })
    #expect(plan.entries.contains(.file(file)))
}

@Test func monthGridStartsOnMonday() {
    let cal = MonthGrid.calendar
    let nov = cal.date(from: DateComponents(year: 2026, month: 11, day: 15))!
    let cells = MonthGrid.cells(for: nov, calendar: cal)
    // 1.11.2026 ist ein Sonntag → 7. Spalte.
    #expect(cells.prefix(6).allSatisfy { $0 == nil })
    #expect(cells[6].map { cal.component(.day, from: $0) } == 1)
    #expect(cells.count == 6 + 30)
    let jun = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!   // Montag
    #expect(MonthGrid.cells(for: jun, calendar: cal).first! != nil)
}

@Test func pillPlacementAlongEdges() {
    let sf = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let vf = CGRect(x: 0, y: 0, width: 1000, height: 770)
    let size = CGSize(width: 200, height: 60)
    func o(_ e: DockEdge, _ p: PillPlacement) -> CGPoint {
        DockController.pillOrigin(edge: e, placement: p, size: size, screen: sf, visible: vf, gap: 8)
    }
    #expect(o(.bottom, .start) == CGPoint(x: 8, y: 8))
    #expect(o(.bottom, .center) == CGPoint(x: 400, y: 8))
    #expect(o(.bottom, .end) == CGPoint(x: 792, y: 8))
    #expect(o(.top, .end) == CGPoint(x: 792, y: 702))
    let tall = CGSize(width: 60, height: 200)
    #expect(DockController.pillOrigin(edge: .left, placement: .start, size: tall, screen: sf, visible: vf, gap: 8) == CGPoint(x: 8, y: 562))
    #expect(DockController.pillOrigin(edge: .right, placement: .end, size: tall, screen: sf, visible: vf, gap: 8) == CGPoint(x: 932, y: 8))
}

@Test func freePositionStaysOnScreen() {
    let vf = CGRect(x: 100, y: 50, width: 1000, height: 700)
    let size = CGSize(width: 200, height: 60)
    let frame = CGRect(x: 500, y: 300, width: 200, height: 60)
    let f = DockController.freeFraction(of: frame, visible: vf)
    #expect(DockController.freeOrigin(f, size: size, visible: vf) == frame.origin)
    // Weit außerhalb gezogen → an den Rand geklemmt.
    let off = DockController.freeFraction(of: CGRect(x: -900, y: 5000, width: 200, height: 60), visible: vf)
    #expect(DockController.freeOrigin(off, size: size, visible: vf) == CGPoint(x: 100, y: 690))
    #expect(DockController.freeOrigin(nil, size: size, visible: vf) == nil)
}

@Test func runningAppsOrder() {
    let items: [(String, Date?)] = [("Zed", Date(timeIntervalSince1970: 10)), ("arc", Date(timeIntervalSince1970: 30)),
                                    ("Mail", nil), ("Bär", Date(timeIntervalSince1970: 20))]
    let byLaunch = RunningAppsModel.ordered(items, by: .launch, name: \.0, launched: \.1).map(\.0)
    #expect(byLaunch == ["Mail", "Zed", "Bär", "arc"])
    let byName = RunningAppsModel.ordered(items, by: .alphabetical, name: \.0, launched: \.1).map(\.0)
    #expect(byName == ["arc", "Bär", "Mail", "Zed"])
}

@Test func batteryCapacityPercent() {
    // Werte dieses Macs: Systemeinstellungen zeigen 100 %.
    #expect(BatteryHealth.percent(nominal: 4718, design: 4629) == 100)
    #expect(BatteryHealth.percent(nominal: 3700, design: 4629) == 80)
    #expect(BatteryHealth.percent(nominal: 0, design: 4629) == nil)
}

@Test func windowGroupingDecision() {
    #expect(!TabRow.useGrouped(.never, widthPerTab: 10))
    #expect(TabRow.useGrouped(.always, widthPerTab: 500))
    #expect(TabRow.useGrouped(.automatic, widthPerTab: 60))
    #expect(!TabRow.useGrouped(.automatic, widthPerTab: 120))
}

@Test func colorHelpers() {
    #expect(NSColor(hex: "#3478F6")?.hexString == "#3478F6")
    #expect(NSColor(hex: "nope") == nil)
    var b: CGFloat = 0
    ArtworkColor.accent(.black).usingColorSpace(.sRGB)!.getHue(nil, saturation: nil, brightness: &b, alpha: nil)
    #expect(b >= 0.54)
    #expect(DockTheme.system.colors(custom: .red, artwork: .blue) == ThemeColors.fallback)
    #expect(DockTheme.custom.colors(custom: .red, artwork: nil).accent == .red)
    #expect(DockTheme.nowPlaying.colors(custom: .red, artwork: nil) == ThemeColors.fallback)
}

@Test func artworkAverageFindsDominantColor() {
    let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        r.fill()
        return true
    }
    let c = ArtworkColor.average(img)!.usingColorSpace(.sRGB)!
    #expect(c.redComponent > 0.8 && c.greenComponent < 0.2 && c.blueComponent < 0.2)
}

@Test func artworkAverageMixesWholeImage() {
    // Halb schwarz, halb weiß → mittleres Grau, nicht die Farbe eines einzelnen Punkts.
    let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 4, height: 8).fill()
        NSColor.white.setFill(); NSRect(x: 4, y: 0, width: 4, height: 8).fill()
        return true
    }
    let c = ArtworkColor.average(img)!
    #expect(c.redComponent > 0.35 && c.redComponent < 0.65)
}


// MARK: Block 3 (Leiste an allen Kanten, mehrere Zeilen)

@Test func oneRowBarKeepsItsHeight() {
    var s = DockSettings()
    s.style = .bar
    #expect(DockMetrics.barThickness(s) == DockMetrics.barIcon(s) + 18)
    #expect(DockMetrics.barTabHeight(s) == DockMetrics.barIcon(s) + 6)
    s.barRows = 3
    #expect(DockMetrics.barThickness(s) == 3 * DockMetrics.barTabHeight(s) + 2 * 4 + 12)
    s.edge = .left   // seitlich: eine Spalte, Zeilen zählen nicht
    #expect(DockMetrics.barRows(s) == 1 && DockMetrics.barThickness(s) == 210)
    s.barLabels = .iconsOnly
    #expect(DockMetrics.barThickness(s) == DockMetrics.barIcon(s) + 18)
}

@Test func barRowsSurviveRoundTripAndClamp() throws {
    var s = DockSettings()
    s.barRows = 4
    #expect(try JSONDecoder().decode(DockSettings.self, from: JSONEncoder().encode(s)).barRows == 4)
    let wild = try JSONDecoder().decode(DockSettings.self, from: Data(#"{"barRows":9}"#.utf8))
    #expect(wild.barRows == 5)
}

@Test func fitterKeepsWindowsOutOfBarOnEveryEdge() {
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)   // AX
    let win = CGRect(x: 0, y: 37, width: 1470, height: 919)      // „Füllen“: ganzer Bildschirm unter der Menüleiste
    #expect(WindowFitter.fittedFrame(win, screen: screen, edge: .bottom, reserved: 46, previous: nil)
            == CGRect(x: 0, y: 37, width: 1470, height: 873))
    #expect(WindowFitter.fittedFrame(win, screen: screen, edge: .top, reserved: 83, previous: nil)
            == CGRect(x: 0, y: 83, width: 1470, height: 873))
    #expect(WindowFitter.fittedFrame(win, screen: screen, edge: .left, reserved: 210, previous: nil)
            == CGRect(x: 210, y: 37, width: 1260, height: 919))
    #expect(WindowFitter.fittedFrame(win, screen: screen, edge: .right, reserved: 210, previous: nil)
            == CGRect(x: 0, y: 37, width: 1260, height: 919))
    // Fenster außerhalb des Streifens bleiben, wie sie sind.
    let small = CGRect(x: 400, y: 300, width: 500, height: 400)
    for e in DockEdge.allCases { #expect(WindowFitter.fittedFrame(small, screen: screen, edge: e, reserved: 210, previous: nil) == nil) }
    // Fast ganz im Streifen (weniger als 150 pt blieben übrig): nicht anfassen.
    #expect(WindowFitter.fittedFrame(CGRect(x: 0, y: 100, width: 300, height: 400), screen: screen, edge: .left,
                                     reserved: 210, previous: nil) == nil)
}

@Test func fitterFollowsBarWhenRowsShrink() {
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    // Fenster endete bündig über einer 3-zeiligen Leiste (120 pt); jetzt nur noch 46 pt → wächst mit nach unten.
    let docked = CGRect(x: 0, y: 37, width: 800, height: 956 - 120 - 37)
    #expect(WindowFitter.fittedFrame(docked, screen: screen, edge: .bottom, reserved: 46, previous: 120)
            == CGRect(x: 0, y: 37, width: 800, height: 873))
    // Ohne gleiche Kante (previous nil) kein Mitwandern.
    #expect(WindowFitter.fittedFrame(docked, screen: screen, edge: .bottom, reserved: 46, previous: nil) == nil)
    // Oben: Fenster begann bündig unter der alten Leiste → rückt mit nach oben.
    let top = CGRect(x: 0, y: 160, width: 800, height: 700)
    #expect(WindowFitter.fittedFrame(top, screen: screen, edge: .top, reserved: 83, previous: 160)
            == CGRect(x: 0, y: 83, width: 800, height: 777))
}

@Test func tabsSplitIntoRows() {
    let items: [BarItem] = (0..<7).map { _ in .separator(UUID()) }
    #expect(TabRow.split(items, rows: 1).map(\.count) == [7])
    #expect(TabRow.split(items, rows: 3).map(\.count) == [3, 2, 2])
    #expect(TabRow.split(items, rows: 5).map(\.count) == [2, 2, 1, 1, 1])   // alle 5 Zeilen genutzt
    #expect(TabRow.split(Array(items.prefix(3)), rows: 5).map(\.count) == [1, 1, 1])
    #expect(TabRow.split([], rows: 3).map(\.count) == [0])
    let line: [BarItem] = [.separator(UUID()), .launcher, .separator(UUID()), .launcher, .separator(UUID())]
    #expect(TabRow.trimSeparators(line).map(\.isSeparator) == [false, true, false])
}

@Test func resizeHandleStepsRows() {
    #expect(BarResizeHandle.rows(from: 1, drag: 70, step: 38, edge: .bottom) == 3)
    #expect(BarResizeHandle.rows(from: 3, drag: -40, step: 38, edge: .bottom) == 2)
    #expect(BarResizeHandle.rows(from: 1, drag: -80, step: 38, edge: .top) == 3)   // oben: nach unten ziehen
    #expect(BarResizeHandle.rows(from: 2, drag: 1000, step: 38, edge: .bottom) == 5)
    #expect(BarResizeHandle.rows(from: 2, drag: -1000, step: 38, edge: .bottom) == 1)
}

@Test func sideBarTabsShrinkToFit() {
    let tabs: [BarItem] = (0..<10).map { _ in .launcher }
    #expect(TabColumn.fittedHeight(tabs, height: 1000, tabHeight: 34) == 34)
    #expect(TabColumn.fittedHeight(tabs, height: 300, tabHeight: 34) == 27)   // (300 − 27) / 10
    #expect(TabColumn.fittedHeight(tabs, height: 50, tabHeight: 34) == 16)
}


@Test func iconOnlyRowDoesNotHideTitles() {
    // Zeile 1 nur kompakte Einträge, Zeile 2 ein breiter Tab: die Breite kommt von Zeile 2.
    let app = NSRunningApplication.current
    let task = BarItem.task(TaskItem(id: "w", app: app, window: nil, title: "X", isActive: false))
    let items: [BarItem] = [.launcher, .launcher, task]
    #expect(TabRow.widthPerTab(items, rows: 2, width: 500) > 84)
}

@Test func oldBarConfigStaysAtBottom() throws {
    // Vor Block 3 stand die Leiste immer unten, auch wenn „edge“ noch von der Pille links war.
    let old = try JSONDecoder().decode(DockSettings.self, from: Data(#"{"style":"bar","edge":"left"}"#.utf8))
    #expect(old.edge == .bottom)
    let new = try JSONDecoder().decode(DockSettings.self, from: Data(#"{"style":"bar","edge":"left","barRows":1}"#.utf8))
    #expect(new.edge == .left)
}
