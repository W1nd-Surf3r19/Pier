import AppKit
import Carbon
import SwiftUI

struct SwitcherItem: Identifiable, Equatable {
    let window: WindowRef
    let app: NSRunningApplication
    var id: String { window.id }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
}

/// ⌥Tab-Fensterumschalter: ⌥ halten, mit Tab (⇧Tab rückwärts) wählen, ⌥ loslassen wechselt, ⌥Esc bricht ab.
@MainActor
final class AltTabController {
    let panel: PassivePanel
    private let model = SwitcherModel()
    private var hotKeys: [HotKey] = []
    private var cancelKey: HotKey?
    private var monitors: [Any] = []

    var isVisible: Bool { panel.isVisible }

    init() {
        let (panel, effect) = PanelFactory.makeGlass(PassivePanel.self, level: .popUpMenu, radius: 18)
        self.panel = panel
        let hosting = FirstMouseHostingView(rootView: SwitcherView(model: model))
        hosting.sizingOptions = []
        PanelFactory.embed(hosting, in: effect)
    }

    func setEnabled(_ on: Bool) {
        guard on != !hotKeys.isEmpty else { return }
        if on {
            hotKeys = [
                HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)) { Coordinator.shared.altTab.step(1) },
                HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey)) { Coordinator.shared.altTab.step(-1) },
            ]
        } else {
            hotKeys = []
            close(commit: false)
        }
    }

    func step(_ delta: Int) {
        if !panel.isVisible {
            open()
            guard !model.items.isEmpty else { return }
            // Erstes ⌥Tab springt zum zuletzt benutzten Fenster (Index 1), ⇧ zum ältesten.
            model.selection = delta > 0 ? min(1, model.items.count - 1) : model.items.count - 1
            // ⌥ schon wieder losgelassen (sehr schneller Tastendruck)? Dann direkt wechseln.
            if !NSEvent.modifierFlags.contains(.option) { close(commit: true) }
            return
        }
        guard !model.items.isEmpty else { return }
        model.selection = (model.selection + delta + model.items.count) % model.items.count
    }

    func choose(_ item: SwitcherItem) {
        if let i = model.items.firstIndex(of: item) { model.selection = i }
        close(commit: true)
    }

    private func open() {
        Coordinator.shared.popup.hide()
        model.items = Self.items()
        guard !model.items.isEmpty else { return }
        layoutPanel()
        panel.orderFrontRegardless()
        cancelKey = HotKey(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey)) {
            Coordinator.shared.altTab.close(commit: false)
        }
        let handler: (NSEvent) -> Void = { e in
            MainActor.assumeIsolated {
                if !e.modifierFlags.contains(.option) { Coordinator.shared.altTab.close(commit: true) }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    func close(commit: Bool) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        cancelKey = nil
        let chosen = model.items.indices.contains(model.selection) ? model.items[model.selection] : nil
        panel.orderOut(nil)
        model.items = []
        if commit, let chosen { Coordinator.shared.focusWindow(chosen.window) }
    }

    private func layoutPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? PanelFactory.mainScreen
        guard let vf = screen?.visibleFrame else { return }
        let thumbs = RunningAppsModel.shared.screenRecording
        let cell = SwitcherView.cellSize(thumbnails: thumbs)
        let perRow = max(1, min(model.items.count, Int((vf.width - 80) / (cell.width + SwitcherView.spacing))))
        let rows = min(3, (model.items.count + perRow - 1) / perRow)
        let w = CGFloat(perRow) * (cell.width + SwitcherView.spacing) - SwitcherView.spacing + 2 * SwitcherView.padding
        let h = CGFloat(rows) * (cell.height + SwitcherView.spacing) - SwitcherView.spacing + 2 * SwitcherView.padding
        panel.setFrame(NSRect(x: (vf.midX - w / 2).rounded(), y: (vf.midY - h / 2).rounded(), width: w, height: h), display: true)
    }

    /// Alle gezeigten Fenster, vorderstes zuerst. Nicht sichtbare (minimiert, andere Spaces) kommen ans Ende.
    private static func items() -> [SwitcherItem] {
        let running = RunningAppsModel.shared
        let all = running.otherApps.flatMap { app in running.shownWindows(of: app).map { SwitcherItem(window: $0, app: app) } }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let ordered = order(all.map(\.window.windowID), frontToBack: front)
        let byID = Dictionary(all.map { ($0.window.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        return ordered.compactMap { byID[$0] }
    }

    /// Sortiert nach Position in `frontToBack`; Unbekannte behalten ihre Reihenfolge und kommen ans Ende.
    nonisolated static func order(_ ids: [CGWindowID], frontToBack: [CGWindowID]) -> [CGWindowID] {
        let rank = Dictionary(frontToBack.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated()
            .sorted { (rank[$0.element] ?? Int.max, $0.offset) < (rank[$1.element] ?? Int.max, $1.offset) }
            .map(\.element)
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var running = RunningAppsModel.shared
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 18

    static func cellSize(thumbnails: Bool) -> CGSize {
        thumbnails ? CGSize(width: 200, height: 160) : CGSize(width: 120, height: 104)
    }

    var body: some View {
        let thumbs = running.screenRecording
        let size = Self.cellSize(thumbnails: thumbs)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size.width, maximum: size.width), spacing: Self.spacing)],
                          spacing: Self.spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        SwitcherCell(item: item, selected: i == model.selection, thumbnails: thumbs, size: size)
                            .id(i)
                    }
                }
                .padding(Self.padding)
            }
            .onChange(of: model.selection) { _, s in proxy.scrollTo(s, anchor: .center) }
        }
    }
}

struct SwitcherCell: View {
    let item: SwitcherItem
    let selected: Bool
    let thumbnails: Bool
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        let title = item.window.title.isEmpty ? (item.app.localizedName ?? "Fenster") : item.window.title
        VStack(spacing: 6) {
            ZStack {
                if thumbnails, let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(nsImage: IconCache.icon(for: item.app)).resizable().frame(width: 56, height: 56)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if thumbnails {
                    Image(nsImage: IconCache.icon(for: item.app)).resizable().frame(width: 28, height: 28).offset(x: 4, y: 4)
                }
            }
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(item.window.isMinimized ? 0.6 : 1)
        }
        .padding(8)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(selected ? 0.16 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { Coordinator.shared.altTab.choose(item) }
        .task(id: item.window.windowID) {
            if thumbnails { image = await ThumbnailService.shared.thumbnail(for: item.window.windowID) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
