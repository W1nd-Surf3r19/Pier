import AppKit
import SwiftUI

// MARK: Wurzel

struct DockRootView: View {
    @ObservedObject var store = DockStore.shared
    var onSize: (CGSize) -> Void

    var body: some View {
        let s = store.settings
        Group {
            if s.style == .pill {
                PillDockView(settings: s).fixedSize()
            } else {
                BarDockView(settings: s)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .contextMenu {
            Button("Apps öffnen…") { Coordinator.shared.toggleLauncher() }
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
    @ObservedObject var fit = DockFit.shared

    var body: some View {
        let size = (CGFloat(settings.iconSize) * fit.scale).rounded()
        let extra = settings.showRunningApps ? running.unpinnedApps(pinned: store.topLevelKeys) : []
        let strip = WidgetStrip(settings: settings, compact: true)

        HStack(alignment: .center, spacing: (size * 0.2).rounded()) {
            if settings.showLauncher { LauncherTile(size: size) }
            EntryIcons(entries: store.entries, size: size)
            if !extra.isEmpty {
                DockDivider(height: size * 0.6)
                ForEach(extra, id: \.processIdentifier) { RunningAppIcon(app: $0, size: size) }
            }
            if strip.hasContent {
                DockDivider(height: size * 0.6)
                strip.padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: DockMetrics.pillRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.entries)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: extra.map(\.processIdentifier))
    }
}

// MARK: Stil 2 – schlanke Leiste

struct BarDockView: View {
    let settings: DockSettings
    @ObservedObject var store = DockStore.shared

    var body: some View {
        let icon = DockMetrics.barIcon(settings)
        let strip = WidgetStrip(settings: settings, compact: false)

        HStack(spacing: 0) {
            HStack(spacing: (icon * 0.3).rounded()) {
                if settings.showLauncher { LauncherTile(size: icon) }
                EntryIcons(entries: store.entries, size: icon)
            }
            .padding(.leading, 12)

            DockDivider(height: icon * 0.75).padding(.horizontal, 12)

            WindowStrip(height: DockMetrics.barHeight(settings) - 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            if strip.hasContent {
                strip.padding(.horizontal, 16)
            }
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1).allowsHitTesting(false)
        }
    }
}

struct WindowStrip: View {
    let height: CGFloat
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var store = DockStore.shared

    var body: some View {
        let items = running.taskItems(pinned: store.topLevelKeys)
        GeometryReader { geo in
            let n = CGFloat(max(items.count, 1))
            let per = ((geo.size.width - 4 * (n - 1)) / n).rounded(.down)
            let showTitle = per >= 84
            HStack(spacing: 4) {
                ForEach(items) {
                    TaskTab(item: $0, height: height, width: showTitle ? min(210, per) : 40, showTitle: showTitle)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height)
        .clipped()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: items.map(\.id))
    }
}

struct TaskTab: View {
    let item: TaskItem
    let height: CGFloat
    let width: CGFloat
    let showTitle: Bool
    @State private var hovering = false

    var body: some View {
        Button { Coordinator.shared.clickTask(item) } label: {
            HStack(spacing: 7) {
                Image(nsImage: IconCache.icon(for: item.app))
                    .resizable().interpolation(.high)
                    .frame(width: 18, height: 18)
                if showTitle {
                    Text(item.title)
                        .font(.system(size: 12, weight: item.isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, showTitle ? 10 : 0)
            .frame(width: width, height: height, alignment: showTitle ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(item.isActive ? 0.15 : (hovering ? 0.09 : 0.045)))
            )
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: item.isActive ? 18 : 0, height: 2.5)
                    .padding(.bottom, 1.5)
            }
            .opacity(item.isMinimized ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .onHoverAlways { h, rect in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
            let target: HoverTarget = item.window.map { .window($0) } ?? .label(item.title)
            if item.window != nil || !showTitle {
                h ? Coordinator.shared.hoverBegan(target, rect: rect) : Coordinator.shared.hoverEnded()
            }
        }
        .contextMenu { RunningAppMenu(app: item.app, window: item.window) }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: item.isActive)
    }
}

// MARK: Icons

struct EntryIcons: View {
    let entries: [DockEntry]
    let size: CGFloat

    var body: some View {
        ForEach(entries) { entry in
            switch entry {
            case .app(let app): PinnedAppIcon(app: app, size: size)
            case .folder(let f): FolderTile(folder: f, size: size)
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
        .contextMenu {
            if let r = running.app(forKey: app.key) {
                RunningAppMenu(app: r, window: nil)
            } else {
                Button("Öffnen") { Coordinator.shared.clickApp(key: app.key, url: app.url) }
                Button("Im Finder zeigen") { AppActions.revealInFinder(app.url) }
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
        .contextMenu { RunningAppMenu(app: app, window: nil) }
    }
}

struct RunningAppMenu: View {
    let app: NSRunningApplication
    let window: WindowRef?

    var body: some View {
        if let window {
            Button("Fenster schließen") { WindowService.close(window) }
            Divider()
        }
        Button(app.isHidden ? "Einblenden" : "Ausblenden") { _ = app.isHidden ? app.unhide() : app.hide() }
        if let url = app.bundleURL {
            Button("Im Finder zeigen") { AppActions.revealInFinder(url) }
        }
        Divider()
        Button("Beenden") { app.terminate() }
    }
}

/// Ein Dock-Icon mit Hover-Effekt, Lauf-Indikator und Start-Animation.
struct DockIcon<Icon: View>: View {
    let icon: Icon
    let size: CGFloat
    let state: RunState
    let hover: HoverTarget
    let action: () -> Void

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
            VStack(spacing: 3) {
                icon
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 6 : 2, y: hovering ? 2 : 1)
                    .scaleEffect(hovering ? 1.08 : 1)
                    .offset(y: hovering ? -1.5 : 0)
                    .opacity(state == .launching && pulse ? 0.45 : 1)
                RunIndicator(state: state)
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
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(opacity))
            .frame(width: state == .active ? 12 : 4, height: 4)
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
