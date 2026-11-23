import AppKit
import SwiftUI

// MARK: Wurzel

struct DockRootView: View {
    @ObservedObject var store = DockStore.shared
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
        .environment(\.dockTheme, s.theme)
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
    @ObservedObject var fit: DockFit

    var body: some View {
        let size = (CGFloat(settings.iconSize) * fit.scale).rounded()
        let extra = settings.showRunningApps ? running.unpinnedApps(pinned: store.topLevelKeys) : []
        let vertical = settings.effectiveEdge.isVertical
        let strip = WidgetStrip(settings: settings, compact: true, vertical: vertical)
        let outer = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        let inner = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))

        // Drei schwebende Inseln: Launcher (Kreis) · Apps · Widgets – unten waagerecht, seitlich senkrecht.
        outer {
            if settings.showLauncher {
                GlassIsland {
                    DockIcon(size: size, state: .none, hover: .label("Apps"), action: { Coordinator.shared.toggleLauncher() }) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: size * 0.42, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.85))
                    }
                }
            }
            GlassIsland {
                inner {
                    EntryIcons(entries: store.entries, size: size)
                    if !extra.isEmpty {
                        DockDivider(height: size * 0.55, horizontal: vertical).padding(vertical ? .vertical : .horizontal, 7)
                        ForEach(extra, id: \.processIdentifier) { RunningAppIcon(app: $0, size: size) }
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
    case separator(UUID)
    case task(TaskItem)

    var id: String {
        switch self {
        case .launcher: "launcher"
        case .pinned(let a): "p-\(a.id)"
        case .folder(let f): "f-\(f.id)"
        case .stack(let s): "s-\(s.id)"
        case .separator(let id): "sep-\(id)"
        case .task(let t): t.id
        }
    }

    /// Nicht laufende Einträge sind immer kompakte Icon-Tabs.
    var isCompact: Bool { if case .task = self { false } else { true } }
    var isSeparator: Bool { if case .separator = self { true } else { false } }
}

struct BarDockView: View {
    let settings: DockSettings
    @ObservedObject var store = DockStore.shared
    @ObservedObject var running = RunningAppsModel.shared

    var body: some View {
        let strip = WidgetStrip(settings: settings, compact: false)
        let height = DockMetrics.barHeight(settings) - 12

        HStack(spacing: 0) {
            TabRow(items: items, height: height, labels: settings.barLabels)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if strip.hasContent {
                strip.padding(.horizontal, 16)
            }
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// Angepinnte Apps in deiner Reihenfolge – laufen sie, stehen ihre Fenster an genau dieser Stelle.
    /// Danach alle übrigen laufenden Apps.
    private var items: [BarItem] {
        var result: [BarItem] = settings.showLauncher ? [.launcher] : []
        var used = Set<pid_t>()
        for entry in store.entries {
            switch entry {
            case .folder(let f):
                result.append(.folder(f))
            case .stack(let s):
                result.append(.stack(s))
            case .separator(let s):
                result.append(.separator(s.id))
            case .app(let a):
                if let app = running.app(forKey: a.key) {
                    used.insert(app.processIdentifier)
                    result += running.tasks(for: app).map(BarItem.task)
                } else {
                    result.append(.pinned(a))
                }
            }
        }
        if settings.showRunningApps {
            for app in running.otherApps where !used.contains(app.processIdentifier) {
                result += running.tasks(for: app).map(BarItem.task)
            }
        }
        return result
    }
}

struct TabRow: View {
    let items: [BarItem]
    let height: CGFloat
    var labels: BarLabels = .automatic
    static let compactWidth: CGFloat = 40
    private let separatorWidth: CGFloat = 9
    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let seps = CGFloat(items.filter(\.isSeparator).count)
            let compact = CGFloat(items.filter(\.isCompact).count) - seps
            let wide = CGFloat(items.count) - compact - seps
            let free = geo.size.width - compact * Self.compactWidth - seps * separatorWidth
                - spacing * CGFloat(max(items.count - 1, 0))
            let per = wide > 0 ? (free / wide).rounded(.down) : 0
            let showTitle = TabRow.showsTitle(labels, widthPerTab: per)
            HStack(spacing: spacing) {
                ForEach(items) { item in
                    BarItemView(item: item, height: height,
                                width: item.isSeparator ? separatorWidth
                                    : (item.isCompact || !showTitle ? Self.compactWidth : min(210, per)),
                                showTitle: !item.isCompact && showTitle)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: items.map(\.id))
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

struct BarItemView: View {
    let item: BarItem
    let height: CGFloat
    let width: CGFloat
    let showTitle: Bool
    @ObservedObject var running = RunningAppsModel.shared
    @Environment(\.dockTheme) private var theme
    @State private var anchor: CGRect = .zero

    var body: some View {
        switch item {
        case .launcher:
            BarTab(height: height, width: width, filled: false, hover: .label("Apps"),
                   action: { Coordinator.shared.toggleLauncher() }) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
        case .pinned(let a):
            BarTab(height: height, width: width, filled: false,
                   launching: running.state(forKey: a.key) == .launching, hover: .label(a.name),
                   action: { Coordinator.shared.clickApp(key: a.key, url: a.url) }) {
                TabIcon(image: IconCache.icon(forPath: a.path)).dockBadge(a.key)
            }
            .dropDestination(for: URL.self) { urls, _ in Coordinator.shared.drop(urls, onto: a.url) }
            .contextMenu { PinnedAppMenu(app: a) }
        case .folder(let f):
            BarTab(height: height, width: width, filled: false, hover: .label(f.name),
                   action: { Coordinator.shared.toggleFolder(f, anchor: anchor) }) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
            }
            .onHoverAlways { h, r in if h { anchor = r } }
        case .separator:
            DockDivider(height: height * 0.5).frame(width: width, height: height)
        case .stack(let s):
            BarTab(height: height, width: width, filled: false, hover: .label(s.name),
                   action: { Coordinator.shared.toggleStack(s, anchor: anchor) }) {
                TabIcon(image: IconCache.icon(forPath: s.path))
            }
            .onHoverAlways { h, r in if h { anchor = r } }
            .contextMenu { StackMenu(stack: s) }
        case .task(let t):
            BarTab(height: height, width: width, filled: true, active: t.isActive, dimmed: t.isMinimized,
                   hover: t.window.map { .window($0) } ?? .label(t.title), hoverAlways: !showTitle,
                   action: { Coordinator.shared.clickTask(t) }) {
                TabIcon(image: IconCache.icon(for: t.app)).dockBadge(isFirstTab(t) ? AppName.key(t.app) : nil)
                if showTitle {
                    Text(t.title)
                        .font(.system(size: 12, weight: t.isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in Coordinator.shared.drop(urls, onto: t.app.bundleURL) }
            .contextMenu { RunningAppMenu(app: t.app, window: t.window) }
        }
    }

    private func isFirstTab(_ t: TaskItem) -> Bool {
        guard let w = t.window else { return true }
        return running.shownWindows(of: t.app).first?.id == w.id
    }
}

struct TabIcon: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).frame(width: 20, height: 20)
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
    let hover: HoverTarget
    var hoverAlways = true
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.dockTheme) private var theme

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        let compact = width <= 40
        Button(action: action) {
            HStack(spacing: 7) { label }
                .padding(.horizontal, compact ? 0 : 10)
                .frame(width: width, height: height, alignment: compact ? .center : .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(active ? 0.15 : (hovering ? 0.09 : (filled ? 0.045 : 0))))
                )
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: active ? 24 : 0, height: 3.5)
                        .shadow(color: theme.accent.opacity(0.6), radius: 4)
                        .padding(.bottom, 1)
                }
                .opacity(dimmed ? 0.5 : (launching && pulse ? 0.45 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .onHoverAlways { h, rect in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
            let wantsPopup: Bool = { if case .window = hover { true } else { hoverAlways } }()
            guard wantsPopup else { return }
            h ? Coordinator.shared.hoverBegan(hover, rect: rect) : Coordinator.shared.hoverEnded()
        }
        .onChange(of: launching, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
    }
}

// MARK: Icons

struct EntryIcons: View {
    let entries: [DockEntry]
    let size: CGFloat
    @Environment(\.dockEdge) private var edge

    var body: some View {
        ForEach(entries) { entry in
            switch entry {
            case .app(let app): PinnedAppIcon(app: app, size: size)
            case .folder(let f): FolderTile(folder: f, size: size)
            case .stack(let s): StackTile(stack: s, size: size)
            case .separator:
                DockDivider(height: size * 0.55, horizontal: edge.isVertical)
                    .padding(edge.isVertical ? .vertical : .horizontal, 7)
            }
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
    @State private var pulse = false

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
                .opacity(state == .launching && pulse ? 0.45 : 1)
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
        .onChange(of: state == .launching, initial: true) { _, launching in
            if launching {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            }
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
    func dockBadge(_ key: String?) -> some View { modifier(DockStatusModifier(key: key)) }
}

struct DockStatusModifier: ViewModifier {
    let key: String?
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var store = DockStore.shared
    @ObservedObject var activity = ActivityModel.shared
    @Environment(\.dockTheme) private var theme
    @State private var flash = false

    func body(content: Content) -> some View {
        let on = store.settings.showBadges
        let wantsAttention = on && key.map { running.attention.contains($0) } == true
        content
            .shadow(color: theme.accent.opacity(flash ? 0.95 : 0), radius: 7)
            .scaleEffect(flash ? 1.08 : 1)
            .overlay(alignment: .bottom) {
                if on, let key, let p = running.progress[key] {
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
            .overlay(alignment: .topTrailing) { DockBadge(key: key) }
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

struct StackMenu: View {
    let stack: DockStack
    var body: some View {
        Button("Im Finder öffnen") { NSWorkspace.shared.open(stack.url) }
        Divider()
        Button("Aus dem Dock entfernen") { DockStore.shared.removeEntry(stack.id) }
    }
}

// MARK: Dock-Kante (für senkrechte Pille)

private struct DockEdgeKey: EnvironmentKey {
    static let defaultValue = DockEdge.bottom
}

extension EnvironmentValues {
    @Entry var dockTheme = DockTheme.system
    var dockEdge: DockEdge {
        get { self[DockEdgeKey.self] }
        set { self[DockEdgeKey.self] = newValue }
    }
}
