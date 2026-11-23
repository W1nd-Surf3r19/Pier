import AppKit
import SwiftUI

// MARK: Wurzel

struct DockRootView: View {
    @ObservedObject var store = DockStore.shared
    @ObservedObject var theme = ThemeModel.shared
    let fit: DockFit
    var onSize: (CGSize) -> Void

    var body: some View {
        let s = store.settings
        Group {
            if s.style == .pill {
                PillDockView(settings: s, fit: fit).fixedSize()
            } else {
                BarDockView(settings: s)
            }
        }
        .environment(\.dockEdge, s.effectiveEdge)
        .environment(\.dockTheme, theme.colors)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .dropDestination(for: URL.self) { urls, _ in Coordinator.shared.drop(urls, onto: nil) }
        .contextMenu {
            Button("Apps öffnen…") { Coordinator.shared.toggleLauncher() }
            Button("Intelligent anordnen…") { Coordinator.shared.openArrange() }
            Button("Einstellungen…") { Coordinator.shared.openSettings() }
            Divider()
            Button("Pier beenden") { NSApp.terminate(nil) }
        }
    }
}

// MARK: Stil 1 – schwebende Pille

struct PillDockView: View {
    let settings: DockSettings
    @ObservedObject var store = DockStore.shared
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var widgets = WidgetModel.shared
    @ObservedObject var devices = DevicesModel.shared   // Geräte-Kachel kommt und geht mit Laufwerken
    @ObservedObject var fit: DockFit

    var body: some View {
        let size = (CGFloat(settings.iconSize) * fit.scale).rounded()
        let extra = settings.showRunningApps ? running.unpinnedApps(pinned: store.topLevelKeys) : []
        let placed = SmartArranger.placeRunning(extra, in: store.entries, settings: settings)
        let vertical = settings.effectiveEdge.isVertical
        let strip = WidgetStrip(settings: settings, compact: true, vertical: vertical)
        let outer = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        let inner = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))

        // Drei schwebende Inseln: Launcher (Kreis) · Apps · Widgets – unten waagerecht, seitlich senkrecht.
        outer {
            if settings.isFree {
                GlassIsland {
                    Image(systemName: "line.3.horizontal")
                        .rotationEffect(.degrees(vertical ? 0 : 90))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: vertical ? size + 8 : 14, height: vertical ? 14 : size + 8)
                        .overlay(MoveHandle { w in Coordinator.shared.dockMoved(w) })
                        .help("Ziehen, um das Dock zu verschieben")
                        .accessibilityLabel("Dock verschieben")
                }
            }
            if settings.showLauncher {
                GlassIsland {
                    DockIcon(size: size, state: .none, hover: .label("Apps"), action: { Coordinator.shared.toggleLauncher() }) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: size * 0.42, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.85))
                    }
                }
            }
            GlassIsland(endInset: 6) {
                inner {
                    EntryIcons(entries: store.entries, size: size, running: placed.after)
                    if !placed.rest.isEmpty {
                        DockDivider(height: size * 0.55, horizontal: vertical).padding(vertical ? .vertical : .horizontal, 7)
                        ForEach(placed.rest, id: \.processIdentifier) { RunningAppIcon(app: $0, size: size) }
                    }
                }
            }
            if strip.hasContent {
                GlassIsland {
                    if vertical {
                        strip.padding(.vertical, 10).frame(minWidth: size + 8)
                    } else {
                        strip.padding(.horizontal, 10).frame(height: size + 8)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.entries)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: extra.map(\.processIdentifier))
    }
}

// MARK: Stil 2 – schlanke Leiste (eine durchgehende Tab-Reihe)

enum BarItem: Identifiable {
    case launcher
    case pinned(PinnedApp)
    case folder(DockFolder)
    case stack(DockStack)
    case file(DockFile)
    case separator(UUID)
    case task(TaskItem)

    var id: String {
        switch self {
        case .launcher: "launcher"
        case .pinned(let a): "p-\(a.id)"
        case .folder(let f): "f-\(f.id)"
        case .stack(let s): "s-\(s.id)"
        case .file(let f): "d-\(f.id)"
        case .separator(let id): "sep-\(id)"
        case .task(let t): t.id
        }
    }

    /// Nicht laufende Einträge sind immer kompakte Icon-Tabs.
    var isCompact: Bool { if case .task = self { false } else { true } }
    var isMedia: Bool { if case .task(let t) = self { t.media } else { false } }
    var isSeparator: Bool { if case .separator = self { true } else { false } }
}

struct BarDockView: View {
    let settings: DockSettings
    @ObservedObject var store = DockStore.shared
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var widgets = WidgetModel.shared
    @ObservedObject var devices = DevicesModel.shared

    var body: some View {
        let plain = items(grouped: false)
        let grouped = settings.windowGrouping == .never ? nil : items(grouped: true)
        let edge = settings.effectiveEdge
        // Spielt Musik und hat der Player einen Tab, zeigt der Tab sie – das Widget entfällt.
        let strip = WidgetStrip(settings: settings, compact: edge.isVertical, vertical: edge.isVertical,
                                hideNowPlaying: plain.contains(where: \.isMedia),
                                narrow: edge.isVertical && settings.barLabels == .iconsOnly)
        let tab = DockMetrics.barTabHeight(settings)

        Group {
            if edge.isVertical {
                // Seitlich: eine Spalte voller Tabs, Widgets unten.
                VStack(spacing: 0) {
                    TabColumn(items: plain, groupedItems: grouped, grouping: settings.windowGrouping,
                              width: DockMetrics.barWidth(settings) - 12, tabHeight: tab,
                              showTitles: settings.barLabels != .iconsOnly)
                        .padding(.vertical, 8)
                        .frame(maxHeight: .infinity, alignment: .top)
                    if strip.hasContent {
                        strip.padding(.vertical, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    TabRow(items: plain, groupedItems: grouped, grouping: settings.windowGrouping,
                           height: tab, labels: settings.barLabels, rows: DockMetrics.barRows(settings))
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if strip.hasContent {
                        strip.padding(.horizontal, 16)
                    }
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Am Innenrand ziehen ändert die Zahl der Zeilen.
                .overlay(alignment: edge == .top ? .bottom : .top) {
                    BarResizeHandle(edge: edge, rows: settings.barRows,
                                    step: tab + DockMetrics.barRowSpacing) { rows, done in
                        Coordinator.shared.resizeBar(rows: rows, done: done)
                    }
                    .frame(height: 5)
                    .accessibilityLabel("Zeilen der Leiste ändern")
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// Angepinnte Apps in deiner Reihenfolge – laufen sie, stehen ihre Fenster an genau dieser Stelle.
    /// Danach alle übrigen laufenden Apps (bei „In Gruppen einsortieren“ hinter ihrer Gruppe, sonst hinten).
    private func items(grouped: Bool) -> [BarItem] {
        var result: [BarItem] = settings.showLauncher ? [.launcher] : []
        let extra = settings.showRunningApps ? running.unpinnedApps(pinned: store.topLevelKeys) : []
        let placed = SmartArranger.placeRunning(extra, in: store.entries, settings: settings)
        for app in placed.after[-1] ?? [] { result += running.tasks(for: app, grouped: grouped).map(BarItem.task) }
        for (i, entry) in store.entries.enumerated() {
            switch entry {
            case .folder(let f):
                result.append(.folder(f))
            case .stack(let s):
                result.append(.stack(s))
            case .file(let f):
                result.append(.file(f))
            case .separator(let s):
                result.append(.separator(s.id))
            case .app(let a):
                if let app = running.app(forKey: a.key) {
                    result += running.tasks(for: app, grouped: grouped).map(BarItem.task)
                } else {
                    result.append(.pinned(a))
                }
            }
            for app in placed.after[i] ?? [] { result += running.tasks(for: app, grouped: grouped).map(BarItem.task) }
        }
        for app in placed.rest { result += running.tasks(for: app, grouped: grouped).map(BarItem.task) }
        // Schmale seitliche Leiste („Nur Icons“): kein Platz für den Musik-Tab – dann bleibt das Widget.
        let narrow = settings.effectiveEdge.isVertical && settings.barLabels == .iconsOnly
        if settings.showNowPlaying, !narrow, let player = widgets.nowPlaying?.playerBundleID,
           let i = result.firstIndex(where: { if case .task(let t) = $0 { AppName.key(t.app) == player } else { false } }),
           case .task(var t) = result[i] {
            t.media = true
            result[i] = .task(t)
        }
        return result
    }
}

struct TabRow: View {
    let items: [BarItem]
    /// Dieselben Tabs mit gruppierten Fenstern – für „Immer“ und für „Automatisch“, wenn es eng wird.
    var groupedItems: [BarItem]? = nil
    var grouping: WindowGrouping = .never
    let height: CGFloat
    var labels: BarLabels = .automatic
    /// Zeilen (1…5); die Tabs verteilen sich der Reihe nach gleichmäßig.
    var rows = 1
    static let compactWidth: CGFloat = 40
    static let mediaWidth: CGFloat = 250
    static let separatorWidth: CGFloat = 9
    static let spacing: CGFloat = 4
    private var separatorWidth: CGFloat { Self.separatorWidth }
    private var spacing: CGFloat { Self.spacing }

    /// Breite je Tab mit Titel, wenn die Zeile `width` breit ist.
    static func widthPerTab(_ items: [BarItem], width: CGFloat) -> CGFloat {
        let seps = CGFloat(items.filter(\.isSeparator).count)
        let media = CGFloat(items.filter(\.isMedia).count)
        let compact = CGFloat(items.filter(\.isCompact).count) - seps
        let wide = CGFloat(items.count) - compact - seps - media
        let free = width - compact * compactWidth - seps * separatorWidth - media * mediaWidth
            - spacing * CGFloat(max(items.count - 1, 0))
        return wide > 0 ? (free / wide).rounded(.down) : 0
    }

    /// „Automatisch“ gruppiert erst, wenn die Tabs sonst keinen lesbaren Titel mehr hätten.
    static func useGrouped(_ grouping: WindowGrouping, widthPerTab: CGFloat) -> Bool {
        switch grouping {
        case .never: false
        case .always: true
        case .automatic: widthPerTab < 84
        }
    }

    /// Teilt die Tabs der Reihe nach möglichst gleichmäßig auf `rows` Zeilen auf (vordere bekommen je einen mehr).
    static func split(_ items: [BarItem], rows: Int) -> [[BarItem]] {
        let rows = min(rows, items.count)
        guard rows > 1 else { return [items] }
        let base = items.count / rows, extra = items.count % rows
        var result: [[BarItem]] = [], start = 0
        for r in 0..<rows {
            let n = base + (r < extra ? 1 : 0)
            result.append(Array(items[start..<start + n]))
            start += n
        }
        return result
    }

    /// Gezeichnete Zeilen: aufgeteilt, ohne Trennlinien am Rand, ohne leere Zeilen.
    static func lines(_ items: [BarItem], rows: Int) -> [[BarItem]] {
        let l = split(items, rows: rows).map(trimSeparators).filter { !$0.isEmpty }
        return l.isEmpty ? [[]] : l
    }

    static func trimSeparators(_ line: [BarItem]) -> [BarItem] {
        Array(line.drop(while: \.isSeparator).reversed().drop(while: \.isSeparator).reversed())
    }

    /// Schmalste Tab-Breite über alle Zeilen – alle Zeilen zeigen damit gleich breite Tabs.
    /// Zeilen nur mit Icons (ohne breite Tabs) zählen nicht mit.
    static func widthPerTab(_ items: [BarItem], rows: Int, width: CGFloat) -> CGFloat {
        lines(items, rows: rows).filter { $0.contains { !$0.isCompact && !$0.isMedia } }
            .map { widthPerTab($0, width: width) }.min() ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let items = groupedItems.map { g in
                Self.useGrouped(grouping, widthPerTab: Self.widthPerTab(self.items, rows: rows, width: geo.size.width)) ? g : self.items
            } ?? self.items
            let per = Self.widthPerTab(items, rows: rows, width: geo.size.width)
            let showTitle = TabRow.showsTitle(labels, widthPerTab: per)
            // Trennlinien am Anfang oder Ende einer Zeile trennen nichts – weglassen.
            let lines = Self.lines(items, rows: rows)
            VStack(alignment: .leading, spacing: DockMetrics.barRowSpacing) {
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: spacing) {
                        ForEach(lines[i]) { item in
                            BarItemView(item: item, height: height,
                                        width: item.isSeparator ? separatorWidth
                                            : item.isMedia ? Self.mediaWidth
                                            : (item.isCompact || !showTitle ? Self.compactWidth : min(210, per)),
                                        showTitle: item.isMedia || (!item.isCompact && showTitle))
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: CGFloat(rows) * height + CGFloat(rows - 1) * DockMetrics.barRowSpacing)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: items.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: groupedItems?.map(\.id))
    }

    /// Automatisch: Text nur, wenn jeder Tab mindestens 84 pt bekommt. „Icon und Text“ zeigt ihn immer (notfalls gekürzt).
    static func showsTitle(_ labels: BarLabels, widthPerTab: CGFloat) -> Bool {
        switch labels {
        case .automatic: widthPerTab >= 84
        case .iconsOnly: false
        case .iconAndText: widthPerTab > compactWidth
        }
    }
}

/// Seitliche Leiste: Tabs untereinander, so hoch wie möglich, aber alle passen hinein (kein Scrollen –
/// Scrollen über einem Tab wechselt Fenster).
struct TabColumn: View {
    let items: [BarItem]
    var groupedItems: [BarItem]?
    var grouping: WindowGrouping
    let width: CGFloat
    let tabHeight: CGFloat
    let showTitles: Bool
    private let spacing: CGFloat = 3

    /// Höhe je Tab, damit `items` in `height` passen (Trennlinien 9 pt), höchstens `tabHeight`, mindestens 16.
    static func fittedHeight(_ items: [BarItem], height: CGFloat, tabHeight: CGFloat, spacing: CGFloat = 3) -> CGFloat {
        let seps = CGFloat(items.filter(\.isSeparator).count)
        let tabs = CGFloat(items.count) - seps
        guard tabs > 0 else { return tabHeight }
        let free = height - seps * 9 - spacing * CGFloat(max(items.count - 1, 0))
        return min(tabHeight, max(16, (free / tabs).rounded(.down)))
    }

    var body: some View {
        GeometryReader { geo in
            let natural = Self.fittedHeight(items, height: geo.size.height, tabHeight: tabHeight)
            // „Automatisch“ gruppiert, sobald die Tabs sonst schrumpfen müssten.
            let useGrouped = groupedItems != nil && (grouping == .always || (grouping == .automatic && natural < tabHeight))
            let list = useGrouped ? groupedItems! : items
            let h = Self.fittedHeight(list, height: geo.size.height, tabHeight: tabHeight)
            VStack(spacing: spacing) {
                ForEach(list) { item in
                    BarItemView(item: item, height: item.isSeparator ? 9 : h, width: width,
                                showTitle: showTitles && !item.isSeparator)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Mehr Tabs als selbst 16 pt hohe hineinpassen: unten abschneiden statt über die Widgets zu zeichnen.
        .clipped()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: items.map(\.id))
    }
}

struct BarItemView: View {
    let item: BarItem
    let height: CGFloat
    let width: CGFloat
    let showTitle: Bool
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var store = DockStore.shared
    @ObservedObject var widgets = WidgetModel.shared
    @Environment(\.dockTheme) private var theme
    @Environment(\.dockEdge) private var edge
    @State private var anchor: CGRect = .zero

    /// Name neben dem Icon – nur in der seitlichen Leiste mit Titeln (oben/unten sind diese Tabs kompakt).
    @ViewBuilder private func sideTitle(_ name: String) -> some View {
        if showTitle {
            Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).dockTextShadow()
        }
    }

    var body: some View {
        switch item {
        case .launcher:
            BarTab(height: height, width: width, filled: false, hover: .label("Apps"),
                   action: { Coordinator.shared.toggleLauncher() }) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(width: 20)
                sideTitle("Apps")
            }
        case .pinned(let a):
            BarTab(height: height, width: width, filled: false,
                   launching: running.isLaunching(a.key), hover: .label(running.label(a.name, key: a.key)),
                   action: { Coordinator.shared.clickApp(key: a.key, url: a.url) }) {
                TabIcon(image: IconCache.icon(forPath: a.path)).dockBadge(a.key, inBar: true)
                sideTitle(a.name)
            }
            .dropDestination(for: URL.self) { urls, _ in Coordinator.shared.drop(urls, onto: a.url) }
            .contextMenu { PinnedAppMenu(app: a) }
        case .folder(let f):
            BarTab(height: height, width: width, filled: false, hover: .label(f.name),
                   action: { Coordinator.shared.toggleFolder(f, anchor: anchor) }) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                    .frame(width: 20)
                sideTitle(f.name)
            }
            .onHoverAlways { h, r in if h { anchor = r } }
        case .separator:
            if edge.isVertical {
                DockDivider(height: width * 0.6, horizontal: true).frame(width: width, height: height)
            } else {
                DockDivider(height: height * 0.5).frame(width: width, height: height)
            }
        case .stack(let s):
            BarTab(height: height, width: width, filled: false, hover: .label(s.name),
                   action: { Coordinator.shared.toggleStack(s, anchor: anchor) }) {
                TabIcon(image: IconCache.icon(forPath: s.path))
                sideTitle(s.name)
            }
            .onHoverAlways { h, r in if h { anchor = r } }
            .contextMenu { StackMenu(stack: s) }
        case .file(let f):
            BarTab(height: height, width: width, filled: false, hover: .label(f.name),
                   action: { Coordinator.shared.openFile(f) }) {
                TabIcon(image: IconCache.icon(forPath: f.path))
                sideTitle(f.name)
            }
            .contextMenu { FileMenu(file: f) }
        case .task(let t):
            // Badge, Fortschritt und Blinken gehören zur App – sie erscheinen nur am ersten Tab.
            let key = AppName.key(t.app)
            let first = isFirstTab(t)
            let hung = running.hung.contains(t.app.processIdentifier)
            let progress = first && store.settings.showBadges ? running.progress[key] : nil
            BarTab(height: height, width: width, filled: true, active: t.isActive,
                   dimmed: t.isMinimized || t.app.isHidden, hung: hung,
                   attention: first && running.attention.contains(key),
                   progress: progress, mediaKey: first ? key : nil,
                   badge: first && showTitle && store.settings.showBadges ? running.badges[key] : nil,
                   hover: t.window.map { .window($0) }
                    ?? (t.groupedCount != nil ? .app(key: key, name: t.title) : .label(running.label(t.title, key: key))),
                   hoverAlways: !showTitle || t.groupedCount != nil,
                   action: { Coordinator.shared.clickTask(t) }) {
                let cover = t.media ? widgets.artwork : nil
                TabIcon(image: cover ?? IconCache.icon(for: t.app), cover: cover != nil).dockBadge(first ? key : nil, inBar: true, wide: showTitle)
                if t.media, let np = widgets.nowPlaying {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(np.title).font(.system(size: 12, weight: .semibold))
                        if !np.artist.isEmpty {
                            Text(np.artist).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .dockTextShadow()
                    // Platz für die Tasten, die über dem Tab liegen.
                    .padding(.trailing, 52)
                } else if showTitle {
                    Text(Self.title(t.title, progress: progress, hung: hung))
                        .font(.system(size: 12, weight: t.isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .dockTextShadow()
                    if let n = t.groupedCount {
                        Text("\(n)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .accessibilityLabel("\(n) Fenster")
                    }
                }
            }
            // Steuerung liegt über dem Tab statt darin – Tasten in einem Button bekämen keine Klicks.
            .overlay(alignment: .trailing) { if t.media { MediaControls().padding(.trailing, 8) } }
            .dropDestination(for: URL.self) { urls, _ in Coordinator.shared.drop(urls, onto: t.app.bundleURL) }
            .contextMenu { RunningAppMenu(app: t.app, window: t.window) }
        }
    }

    /// „14 % · Downloads“ bzw. „Reagiert nicht · Xcode“.
    static func title(_ title: String, progress: Double?, hung: Bool) -> String {
        if hung { return "Reagiert nicht · \(title)" }
        if let progress { return "\(Int((progress * 100).rounded())) % · \(title)" }
        return title
    }

    private func isFirstTab(_ t: TaskItem) -> Bool {
        guard let w = t.window else { return true }
        return running.shownWindows(of: t.app).first?.id == w.id
    }
}

struct TabIcon: View {
    let image: NSImage
    /// Album-Cover statt App-Icon: eckig, daher leicht abgerundet.
    var cover = false
    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: cover ? 4 : 0))
    }
}

/// Ein Tab der Leiste. Laufende Einträge haben eine Fläche, angepinnte (nicht laufende) nur beim Hover.
struct BarTab<Label: View>: View {
    let height: CGFloat
    let width: CGFloat
    var filled: Bool
    var active = false
    var dimmed = false
    var launching = false
    var hung = false
    var attention = false
    /// Download-/Kopier-Fortschritt der App (0…1) – füllt den Tab von links.
    var progress: Double? = nil
    /// Bundle-ID für die Titelposition eines Players (grüner Balken).
    var mediaKey: String? = nil
    /// Großes Badge rechts im Tab (nur bei Tabs mit Titel).
    var badge: String? = nil
    let hover: HoverTarget
    var hoverAlways = true
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.dockTheme) private var theme

    @State private var hovering = false
    @State private var blink = false

    var body: some View {
        let compact = width <= 40
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 7) {
                label
                if let badge, !compact {
                    Spacer(minLength: 0)
                    BigBadge(text: badge)
                }
            }
                .padding(.horizontal, compact ? 0 : 10)
                .frame(width: width, height: height, alignment: compact ? .center : .leading)
                .background(
                    ZStack(alignment: .leading) {
                        shape.fill(Color.primary.opacity(active ? 0.15 : (hovering ? 0.09 : (filled ? 0.045 : 0))))
                        if let progress {
                            Rectangle().fill(theme.accent.opacity(0.2))
                                .frame(width: width * progress)
                                .animation(.easeOut(duration: 0.3), value: progress)
                        }
                        if launching || hung { StatusStripes(hung: hung) }
                        shape.fill(theme.accent.opacity(blink ? 0.4 : 0))
                    }
                    .clipShape(shape)
                )
                .overlay(alignment: .bottom) {
                    // Fortschritt (Akzent) bzw. Titelposition (grün) als Balken am Fuß des Tabs.
                    Group {
                        if let progress {
                            GeometryReader { g in
                                Capsule().fill(theme.accent).frame(width: max(3, g.size.width * progress))
                            }
                            .frame(height: 3)
                        } else if let mediaKey {
                            MediaProgressBar(bundleID: mediaKey)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 1.5)
                }
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: active ? 24 : 0, height: 3.5)
                        .shadow(color: theme.accent.opacity(0.6), radius: 4)
                        .padding(.bottom, 1)
                }
                .opacity(dimmed ? 0.5 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .onHoverAlways { h, rect in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
            let wantsPopup: Bool = { if case .window = hover { true } else { hoverAlways } }()
            guard wantsPopup else { return }
            h ? Coordinator.shared.hoverBegan(hover, rect: rect) : Coordinator.shared.hoverEnded()
        }
        // Aufmerksamkeit: die ganze Kachel blinkt ein paar Mal.
        .onChange(of: attention) { _, now in
            withAnimation(.easeInOut(duration: 0.3).repeatCount(now ? 7 : 1, autoreverses: true)) { blink = now }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
    }
}

// MARK: Icons

struct EntryIcons: View {
    let entries: [DockEntry]
    let size: CGFloat
    /// Laufende Apps, die hinter dem Eintrag mit diesem Index einsortiert werden.
    var running: [Int: [NSRunningApplication]] = [:]
    @Environment(\.dockEdge) private var edge

    var body: some View {
        ForEach(running[-1] ?? [], id: \.processIdentifier) { RunningAppIcon(app: $0, size: size) }
        ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
            switch entry {
            case .app(let app): PinnedAppIcon(app: app, size: size)
            case .folder(let f): FolderTile(folder: f, size: size)
            case .stack(let s): StackTile(stack: s, size: size)
            case .file(let f): FileTile(file: f, size: size)
            case .separator:
                DockDivider(height: size * 0.55, horizontal: edge.isVertical)
                    .padding(edge.isVertical ? .vertical : .horizontal, 7)
            }
            ForEach(running[i] ?? [], id: \.processIdentifier) { RunningAppIcon(app: $0, size: size) }
        }
    }
}

struct PinnedAppIcon: View {
    let app: PinnedApp
    let size: CGFloat
    @ObservedObject var running = RunningAppsModel.shared

    var body: some View {
        DockIcon(image: IconCache.icon(forPath: app.path), size: size,
                 state: running.state(forKey: app.key),
                 hover: .app(key: app.key, name: app.name)) {
            Coordinator.shared.clickApp(key: app.key, url: app.url)
        }
        .dockBadge(app.key)
        .dropDestination(for: URL.self) { urls, _ in Coordinator.shared.drop(urls, onto: app.url) }
        .contextMenu {
            if let r = running.app(forKey: app.key) {
                RunningAppMenu(app: r, window: nil)
            } else {
                PinnedAppMenu(app: app)
            }
        }
    }
}

struct RunningAppIcon: View {
    let app: NSRunningApplication
    let size: CGFloat
    @ObservedObject var running = RunningAppsModel.shared

    var body: some View {
        let key = AppName.key(app)
        DockIcon(image: IconCache.icon(for: app), size: size, state: running.state(forKey: key),
                 hover: .app(key: key, name: app.localizedName ?? "App")) {
            Coordinator.shared.clickApp(key: key, url: app.bundleURL)
        }
        .dockBadge(key)
        .dropDestination(for: URL.self) { urls, _ in Coordinator.shared.drop(urls, onto: app.bundleURL) }
        .contextMenu { RunningAppMenu(app: app, window: nil) }
    }
}

/// Kontextmenü einer angepinnten, nicht laufenden App.
struct PinnedAppMenu: View {
    let app: PinnedApp

    var body: some View {
        Button("Öffnen") { Coordinator.shared.clickApp(key: app.key, url: app.url) }
        Button("Im Finder zeigen") { AppActions.revealInFinder(app.url) }
        Divider()
        Button("Aus dem Dock entfernen") { Coordinator.shared.unpin(key: app.key) }
    }
}

struct RunningAppMenu: View {
    let app: NSRunningApplication
    let window: WindowRef?
    @ObservedObject var store = DockStore.shared

    var body: some View {
        if let window {
            Button("Fenster schließen") { WindowService.close(window) }
            Divider()
        }
        Button(app.isHidden ? "Einblenden" : "Ausblenden") { _ = app.isHidden ? app.unhide() : app.hide() }
        if let url = app.bundleURL {
            Button("Im Finder zeigen") { AppActions.revealInFinder(url) }
        }
        if store.topLevelKeys.contains(AppName.key(app)) {
            Button("Aus dem Dock entfernen") { Coordinator.shared.unpin(key: AppName.key(app)) }
        } else {
            if let url = app.bundleURL {
                Button("Im Dock behalten") { Coordinator.shared.pin(url) }
            }
            Button("In Pier nicht anzeigen") {
                store.settings.excludedApps[AppName.key(app)] = app.localizedName ?? AppName.key(app)
            }
        }
        Divider()
        Button("Beenden") { app.terminate() }
        Button("Sofort beenden…") { Coordinator.shared.forceQuit(app) }
    }
}

/// Ein Dock-Icon mit Hover-Effekt, Lauf-Indikator und Start-Animation.
struct DockIcon<Icon: View>: View {
    let icon: Icon
    let size: CGFloat
    let state: RunState
    let hover: HoverTarget
    let action: () -> Void

    @Environment(\.dockEdge) private var edge
    @State private var hovering = false

    init(size: CGFloat, state: RunState, hover: HoverTarget, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.icon = icon()
        self.size = size
        self.state = state
        self.hover = hover
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // Statt Apple-Vergrößerung: Icon liegt in einer weichen „Mulde“, die bei Hover/aktiv aufleuchtet.
            icon
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .offset(hoverLift)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .fill(Color.primary.opacity(state == .active ? 0.15 : (hovering ? 0.08 : 0)))
                )
                .overlay(alignment: indicatorAlignment) {
                    RunIndicator(state: state, vertical: edge.isVertical).offset(indicatorOffset)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .onHoverAlways { h, rect in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) { hovering = h }
            h ? Coordinator.shared.hoverBegan(hover, rect: rect) : Coordinator.shared.hoverEnded()
        }
    }
}

extension DockIcon {
    /// Hover hebt das Icon von der Bildschirmkante weg; der Lauf-Punkt sitzt an der Kante.
    fileprivate var hoverLift: CGSize {
        guard hovering else { return .zero }
        switch edge {
        case .bottom: return CGSize(width: 0, height: -2)
        case .top: return CGSize(width: 0, height: 2)
        case .left: return CGSize(width: 2, height: 0)
        case .right: return CGSize(width: -2, height: 0)
        }
    }

    fileprivate var indicatorAlignment: Alignment {
        switch edge {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    fileprivate var indicatorOffset: CGSize {
        switch edge {
        case .bottom: CGSize(width: 0, height: 6)
        case .top: CGSize(width: 0, height: -6)
        case .left: CGSize(width: -6, height: 0)
        case .right: CGSize(width: 6, height: 0)
        }
    }
}

extension DockIcon where Icon == AppIconImage {
    init(image: NSImage, size: CGFloat, state: RunState, hover: HoverTarget, action: @escaping () -> Void) {
        self.init(size: size, state: state, hover: hover, action: action) { AppIconImage(image: image) }
    }
}

struct AppIconImage: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
    }
}

struct RunIndicator: View {
    let state: RunState
    var vertical = false
    @Environment(\.dockTheme) private var theme
    var body: some View {
        let long: CGFloat = state == .active ? 14 : 4
        let short: CGFloat = state == .active ? 3.5 : 4
        Capsule()
            .fill(state == .active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.primary.opacity(opacity)))
            .frame(width: vertical ? short : long, height: vertical ? long : short)
            .shadow(color: state == .active ? theme.accent.opacity(0.7) : .clear, radius: 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: state)
    }

    private var opacity: Double {
        switch state {
        case .none: 0
        case .running: 0.45
        case .active: 0.9
        case .launching: 0.25
        }
    }
}

struct LauncherTile: View {
    let size: CGFloat
    var body: some View {
        DockIcon(size: size, state: .none, hover: .label("Apps"), action: { Coordinator.shared.toggleLauncher() }) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.8))
            }
            .padding(size * 0.06)
        }
    }
}

struct FolderTile: View {
    let folder: DockFolder
    let size: CGFloat
    @ObservedObject var running = RunningAppsModel.shared
    @State private var rect: CGRect = .zero

    var body: some View {
        let anyRunning = folder.apps.contains { running.app(forKey: $0.key) != nil }
        DockIcon(size: size, state: anyRunning ? .running : .none, hover: .label(folder.name),
                 action: { Coordinator.shared.toggleFolder(folder, anchor: rect) }) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.primary.opacity(0.11))
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                let mini = size * 0.32
                VStack(spacing: size * 0.06) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: size * 0.06) {
                            ForEach(0..<2, id: \.self) { col in
                                let i = row * 2 + col
                                if i < folder.apps.count {
                                    Image(nsImage: IconCache.icon(forPath: folder.apps[i].path))
                                        .resizable().interpolation(.high).frame(width: mini, height: mini)
                                } else {
                                    Color.clear.frame(width: mini, height: mini)
                                }
                            }
                        }
                    }
                }
            }
            .padding(size * 0.06)
        }
        .onHoverAlways { h, r in if h { rect = r } }
    }
}

// MARK: Badge (Mitteilungszahl aus dem Mac-Dock)

extension View {
    /// Badge, Fortschrittsbalken und kurzes Aufleuchten bei neuen Mitteilungen.
    /// In der Leiste zeichnet der Tab Fortschritt, Streifen und Blinken selbst; das große Badge steht im breiten Tab.
    func dockBadge(_ key: String?, inBar: Bool = false, wide: Bool = false) -> some View {
        modifier(DockStatusModifier(key: key, inBar: inBar, wide: wide))
    }
}

struct DockStatusModifier: ViewModifier {
    let key: String?
    var inBar = false
    var wide = false
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var store = DockStore.shared
    @ObservedObject var activity = ActivityModel.shared
    @Environment(\.dockTheme) private var theme
    @State private var flash = false

    func body(content: Content) -> some View {
        let on = store.settings.showBadges
        let wantsAttention = !inBar && on && key.map { running.attention.contains($0) } == true
        let hung = key.map(running.isHung) ?? false
        let launching = key.map(running.isLaunching) ?? false
        content
            .shadow(color: theme.accent.opacity(flash ? 0.95 : 0), radius: 7)
            .scaleEffect(flash ? 1.08 : 1)
            .overlay {
                if !inBar, hung || launching {
                    StatusStripes(hung: hung).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .overlay(alignment: .bottom) {
                if !inBar, let key, running.progress[key] == nil {
                    MediaProgressBar(bundleID: key).padding(.horizontal, 6).offset(y: -1)
                }
            }
            .overlay(alignment: .bottom) {
                if !inBar, on, let key, let p = running.progress[key] {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.black.opacity(0.45))
                            Capsule().fill(theme.accent).frame(width: max(3, g.size.width * p))
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 3)
                    .offset(y: -1)
                    .animation(.easeOut(duration: 0.3), value: p)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Fortschritt \(Int(p * 100)) Prozent")
                }
            }
            .overlay(alignment: .topTrailing) { if !wide { DockBadge(key: key) } }
            .overlay(alignment: .bottom) {
                if activity.visible, let key, let app = running.app(forKey: key),
                   let stat = activity.stats[app.processIdentifier] {
                    VStack(spacing: 0) {
                        Text(ActivityModel.cpuText(stat))
                        Text(ActivityModel.memoryText(stat.memory))
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(stat.cpu >= 50 ? Color.red.opacity(0.85) : Color.black.opacity(0.72)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onChange(of: wantsAttention) { _, now in
                withAnimation(.easeInOut(duration: 0.3).repeatCount(now ? 5 : 1, autoreverses: true)) { flash = now }
            }
    }
}

/// Großes rotes Badge rechts in einem breiten Leisten-Tab.
struct BigBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Color.red))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("\(text) Mitteilungen")
    }
}

/// Diagonale Streifen: wandernd, solange eine App startet; still und rötlich, wenn sie nicht reagiert.
struct StatusStripes: View {
    let hung: Bool
    var body: some View {
        TimelineView(.animation(paused: hung)) { ctx in
            Canvas { g, size in
                let spacing: CGFloat = 11
                let shift = hung ? 0 : CGFloat(ctx.date.timeIntervalSinceReferenceDate * 16).truncatingRemainder(dividingBy: spacing)
                var path = Path()
                var x = -size.height - spacing + shift
                while x < size.width + spacing {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += spacing
                }
                g.stroke(path, with: .color(hung ? Color.red.opacity(0.4) : Color.primary.opacity(0.14)), lineWidth: 4)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(hung ? "Reagiert nicht" : "Wird gestartet")
    }
}

struct DockBadge: View {
    let key: String?
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var store = DockStore.shared

    var body: some View {
        if store.settings.showBadges, let key, let text = running.badges[key] {
            // Ein einzelnes „•“ zeigt das Mac-Dock bei Apps ohne Zahl.
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 4.5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Capsule().fill(Color.red))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .offset(x: 4, y: -2)
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("\(text) Mitteilungen")
        }
    }
}

// MARK: Stapel

struct StackTile: View {
    let stack: DockStack
    let size: CGFloat
    @State private var rect: CGRect = .zero

    var body: some View {
        DockIcon(image: IconCache.icon(forPath: stack.path), size: size, state: .none, hover: .label(stack.name)) {
            Coordinator.shared.toggleStack(stack, anchor: rect)
        }
        .onHoverAlways { h, r in if h { rect = r } }
        .contextMenu { StackMenu(stack: stack) }
    }
}

/// Angepinnte Datei: Klick öffnet sie mit ihrer Standard-App.
struct FileTile: View {
    let file: DockFile
    let size: CGFloat

    var body: some View {
        DockIcon(image: IconCache.icon(forPath: file.path), size: size, state: .none, hover: .label(file.name)) {
            Coordinator.shared.openFile(file)
        }
        .contextMenu { FileMenu(file: file) }
    }
}

struct FileMenu: View {
    let file: DockFile
    var body: some View {
        Button("Öffnen") { Coordinator.shared.openFile(file) }
        Button("Im Finder zeigen") { AppActions.revealInFinder(file.url) }
        Divider()
        Button("Aus dem Dock entfernen") { DockStore.shared.removeEntry(file.id) }
    }
}

struct StackMenu: View {
    let stack: DockStack
    var body: some View {
        Button("Im Finder öffnen") { NSWorkspace.shared.open(stack.url) }
        Divider()
        Button("Aus dem Dock entfernen") { DockStore.shared.removeEntry(stack.id) }
    }
}

// MARK: Lesbarkeit beim transparenten Thema

/// Ohne Glas liegt Text direkt auf dem Hintergrund – ein leichter Schatten in Gegenfarbe hält ihn lesbar.
struct DockTextShadow: ViewModifier {
    @Environment(\.dockTheme) private var theme
    func body(content: Content) -> some View {
        content.shadow(color: theme.isClear ? Color(nsColor: .windowBackgroundColor).opacity(0.9) : .clear, radius: 2)
    }
}

extension View {
    func dockTextShadow() -> some View { modifier(DockTextShadow()) }
}

// MARK: Dock-Kante (für senkrechte Pille)

private struct DockEdgeKey: EnvironmentKey {
    static let defaultValue = DockEdge.bottom
}

extension EnvironmentValues {
    @Entry var dockTheme = ThemeColors.fallback
    var dockEdge: DockEdge {
        get { self[DockEdgeKey.self] }
        set { self[DockEdgeKey.self] = newValue }
    }
}
