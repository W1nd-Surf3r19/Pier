import AppKit
import SwiftUI

struct LaunchItem: Identifiable, Hashable {
    let id: String
    let name: String
    var url: URL { URL(fileURLWithPath: id) }
}

enum AppCatalog {
    static func scan() -> [LaunchItem] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var paths: [String] = []
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names where !n.hasPrefix(".") {
                let p = root + "/" + n
                if n.hasSuffix(".app") {
                    paths.append(p)
                } else if root != "/Applications/Utilities", root != "/System/Applications/Utilities",
                          let sub = try? fm.contentsOfDirectory(atPath: p) {
                    // Eine Ebene tiefer, z. B. „/Applications/Adobe Photoshop/…app“
                    paths.append(contentsOf: sub.filter { $0.hasSuffix(".app") }.map { p + "/" + $0 })
                }
            }
        }
        paths.append("/System/Library/CoreServices/Finder.app")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
            .map { LaunchItem(id: $0, name: AppName.display(forPath: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published private(set) var all: [LaunchItem] = []
    @Published var focusToken = 0
    /// Nur Tastatur-Navigation scrollt – Hover soll die Liste nicht verschieben.
    @Published var scrollTarget: String?

    static let columns = 6

    var results: [LaunchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let prefix = all.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        let contains = all.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil && !prefix.contains($0)
        }
        return prefix + contains
    }

    func reload() {
        Task.detached(priority: .userInitiated) {
            let items = AppCatalog.scan()
            await MainActor.run { self.all = items }
        }
    }

    func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selection = min(max(selection + delta, 0), n - 1)
        scrollTarget = results[selection].id
    }
}

/// Launchpad-Ersatz: Overlay mit Sofortsuche. Öffnet per Dock-Kachel oder ⌥ Leertaste.
@MainActor
final class LauncherController: NSObject, NSWindowDelegate {
    let panel: KeyPanel
    let model = LauncherModel()
    private var keyMonitor: Any?
    private let size = NSSize(width: 780, height: 560)

    var isVisible: Bool { panel.isVisible }

    override init() {
        let (panel, effect) = PanelFactory.makeGlass(KeyPanel.self, level: PanelFactory.dockLevel + 2, radius: 24)
        self.panel = panel
        super.init()
        effect.material = .popover
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        let hosting = FirstMouseHostingView(rootView: LauncherView(model: model, onLaunch: { [weak self] in self?.launch($0) }))
        hosting.sizingOptions = []
        PanelFactory.embed(hosting, in: effect)
        model.reload()
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let sf = PanelFactory.mainScreen?.visibleFrame else { return }
        model.query = ""
        model.selection = 0
        model.scrollTarget = nil
        model.reload()
        panel.setFrame(NSRect(x: (sf.midX - size.width / 2).rounded(), y: (sf.midY - size.height / 2 + 40).rounded(),
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func launch(_ item: LaunchItem) {
        hide()
        AppActions.launch(item.url)
    }

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.window === self.panel else { return e }
                let cols = LauncherModel.columns
                switch e.keyCode {
                case 53: self.hide()
                case 36, 76:
                    let r = self.model.results
                    if r.indices.contains(self.model.selection) { self.launch(r[self.model.selection]) }
                case 123: self.model.move(-1)
                case 124: self.model.move(1)
                case 125: self.model.move(cols)
                case 126: self.model.move(-cols)
                default: return e
                }
                return nil
            }
        }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    var onLaunch: (LaunchItem) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Apps durchsuchen", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                Button { Coordinator.shared.openSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Pier-Einstellungen")
            }
            .padding(.horizontal, 24)
            .frame(height: 66)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)

            if results.isEmpty {
                Spacer()
                Text("Keine Apps gefunden").font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(116), spacing: 4), count: LauncherModel.columns),
                                  spacing: 8) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                LauncherCell(item: item, selected: i == model.selection)
                                    .id(item.id)
                                    .onTapGesture { onLaunch(item) }
                                    .onHoverAlways { h, _ in if h { model.selection = i } }
                            }
                        }
                        .padding(18)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.scrollTarget) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.focusToken, initial: true) { DispatchQueue.main.async { focused = true } }
    }
}

struct LauncherCell: View {
    let item: LaunchItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: IconCache.icon(forPath: item.id))
                .resizable().interpolation(.high)
                .frame(width: 62, height: 62)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(item.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
