import AppKit
import SwiftUI

enum HoverTarget: Equatable {
    case app(key: String, name: String)
    case window(WindowRef)
    case label(String)
}

enum PopupContent: Equatable {
    case preview(HoverTarget)
    case folder(DockFolder)
}

/// Kleines schwebendes Fenster über dem Dock: Name, Fenster-Vorschau oder Ordner-Inhalt.
@MainActor
final class PopupController {
    let panel: PassivePanel
    private let hosting: FirstMouseHostingView<PopupRootView>
    private(set) var content: PopupContent?
    private var anchor: CGRect = .zero
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var popupHovered = false
    private var monitors: [Any] = []

    var isVisible: Bool { panel.isVisible }

    init() {
        let (panel, effect) = PanelFactory.makeGlass(PassivePanel.self, level: PanelFactory.dockLevel + 1,
                                                     radius: DockMetrics.popupRadius)
        self.panel = panel
        hosting = FirstMouseHostingView(rootView: PopupRootView(content: nil, onSize: { _ in }))
        hosting.sizingOptions = []
        PanelFactory.embed(hosting, in: effect)
    }

    // MARK: Hover

    func hoverBegan(_ target: HoverTarget, anchor: CGRect) {
        if case .folder = content, panel.isVisible { return }
        hideTimer?.invalidate()
        showTimer?.invalidate()
        self.anchor = anchor
        if panel.isVisible {
            present(.preview(target))
        } else {
            showTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.present(.preview(target)) }
            }
        }
    }

    func hoverEnded() {
        showTimer?.invalidate()
        if case .folder = content { return }
        scheduleHide()
    }

    func setPopupHovered(_ h: Bool) {
        popupHovered = h
        if h {
            hideTimer?.invalidate()
        } else if case .preview = content {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.popupHovered else { return }
                self.hide()
            }
        }
    }

    // MARK: Ordner

    func toggleFolder(_ folder: DockFolder, anchor: CGRect) {
        if case .folder(let f) = content, f.id == folder.id, panel.isVisible {
            hide()
            return
        }
        showTimer?.invalidate()
        hideTimer?.invalidate()
        self.anchor = anchor
        present(.folder(folder))
        installOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeMonitors()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                if e.window !== self.panel && e.window !== Coordinator.shared.dock.panel { self.hide() }
            }
            return e
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    // MARK: Anzeigen

    private func present(_ c: PopupContent) {
        var c = c
        if case .preview(.window(let w)) = c, !(RunningAppsModel.shared.screenRecording && DockStore.shared.settings.windowPreviews) {
            // Ohne Vorschaubild reicht der Fenstertitel.
            let name = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "Fenster"
            c = .preview(.label(w.title.isEmpty ? name : w.title))
        }
        content = c
        hosting.rootView = PopupRootView(content: c, onSize: { [weak self] size in self?.resize(to: size) })
        hosting.layoutSubtreeIfNeeded()
        resize(to: hosting.fittingSize)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    private func resize(to size: CGSize) {
        guard size.width > 1, size.height > 1, let screen = PanelFactory.mainScreen else { return }
        let dockTop = Coordinator.shared.dock.panel.frame.maxY
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x.rounded(), y: (dockTop + 8).rounded(), width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    func hide() {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        removeMonitors()
        content = nil
        popupHovered = false
        panel.orderOut(nil)
    }
}

// MARK: Ansichten

struct PopupRootView: View {
    let content: PopupContent?
    var onSize: (CGSize) -> Void

    var body: some View {
        Group {
            switch content {
            case .preview(let t)?: PreviewView(target: t)
            case .folder(let f)?: FolderGridView(folder: f)
            case nil: EmptyView()
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .onHoverAlways { h, _ in Coordinator.shared.popup.setPopupHovered(h) }
    }
}

struct PreviewView: View {
    let target: HoverTarget
    @ObservedObject var running = RunningAppsModel.shared
    @ObservedObject var store = DockStore.shared

    var body: some View {
        let thumbs = running.screenRecording && store.settings.windowPreviews
        switch target {
        case .label(let text):
            NameLabel(text: text)
        case .window(let w):
            WindowCard(window: w, thumbnails: true).padding(10)
        case .app(let key, let name):
            let wins = store.settings.windowPreviews ? running.windows(forKey: key) : []
            if wins.isEmpty {
                NameLabel(text: name)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(name).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 16)
                        Text(wins.count == 1 ? "1 Fenster" : "\(wins.count) Fenster")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                    if thumbs {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(wins.prefix(5)) { WindowCard(window: $0, thumbnails: true) }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(wins.prefix(10)) { WindowCard(window: $0, thumbnails: false) }
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

struct NameLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
    }
}

struct WindowCard: View {
    let window: WindowRef
    let thumbnails: Bool
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var hovering = false

    private var title: String {
        window.title.isEmpty ? (NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "Fenster") : window.title
    }

    var body: some View {
        Group {
            if thumbnails { card } else { row }
        }
        .contentShape(Rectangle())
        .onTapGesture { Coordinator.shared.focusWindow(window) }
        .onHoverAlways { h, _ in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(7)
                } else if loaded {
                    if let app = NSRunningApplication(processIdentifier: window.pid) {
                        Image(nsImage: IconCache.icon(for: app)).resizable().frame(width: 44, height: 44).opacity(0.8)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 208, height: 130)
            .overlay(alignment: .bottomTrailing) {
                if window.isMinimized {
                    Text("Minimiert")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if hovering { closeButton.padding(6) }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 2)
            )
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 208, alignment: .leading)
                .padding(.horizontal, 2)
        }
        .task(id: window.windowID) {
            image = await ThumbnailService.shared.thumbnail(for: window.windowID)
            loaded = true
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: window.isMinimized ? "minus.rectangle" : "macwindow")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.10 : 0)))
    }

    private var closeButton: some View {
        Button { WindowService.close(window) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .help("Fenster schließen")
    }
}

struct FolderGridView: View {
    let folder: DockFolder
    private let columns = 4

    var body: some View {
        let rows = stride(from: 0, to: folder.apps.count, by: columns).map { Array(folder.apps[$0..<min($0 + columns, folder.apps.count)]) }
        VStack(alignment: .leading, spacing: 10) {
            Text(folder.name)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 6)
            if folder.apps.isEmpty {
                Text("Noch leer – Apps fügst du in den Einstellungen hinzu.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(rows[r]) { FolderAppCell(app: $0) }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct FolderAppCell: View {
    let app: PinnedApp
    @State private var hovering = false
    @ObservedObject var running = RunningAppsModel.shared

    var body: some View {
        Button { Coordinator.shared.launchFromFolder(app) } label: {
            VStack(spacing: 5) {
                Image(nsImage: IconCache.icon(forPath: app.path))
                    .resizable().interpolation(.high).frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                RunIndicator(state: running.state(forKey: app.key))
            }
            .frame(width: 84, height: 88)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .onHoverAlways { h, _ in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}
