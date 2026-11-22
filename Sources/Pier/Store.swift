import AppKit
import Combine

/// Angepinnte Apps, Ordner und Einstellungen. Wird als JSON in
/// ~/Library/Application Support/Pier/config.json gespeichert.
@MainActor
final class DockStore: ObservableObject {
    static let shared = DockStore()

    @Published var entries: [DockEntry] = [] { didSet { scheduleSave() } }
    @Published var settings = DockSettings() { didSet { scheduleSave() } }
    private(set) var isFirstLaunch = false

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private struct Persisted: Codable {
        var entries: [DockEntry]
        var settings: DockSettings
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pier", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            entries = p.entries
            settings = p.settings
        } else {
            isFirstLaunch = true
            entries = Self.importFromSystemDock()
            save()
        }
    }

    // MARK: Speichern

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Persisted(entries: entries, settings: settings)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Abfragen

    var folders: [DockFolder] {
        entries.compactMap { if case .folder(let f) = $0 { f } else { nil } }
    }

    /// Schlüssel aller direkt (nicht in Ordnern) angepinnten Apps.
    var topLevelKeys: Set<String> {
        Set(entries.compactMap { if case .app(let a) = $0 { a.key } else { nil } })
    }

    // MARK: Änderungen

    func addApps(_ urls: [URL], toFolder folderID: UUID? = nil) {
        let apps = urls.map(PinnedApp.init(url:))
        if let folderID, let i = folderIndex(folderID), case .folder(var f) = entries[i] {
            f.apps.append(contentsOf: apps.filter { a in !f.apps.contains { $0.path == a.path } })
            entries[i] = .folder(f)
        } else {
            let existing = topLevelKeys
            entries.append(contentsOf: apps.filter { !existing.contains($0.key) }.map(DockEntry.app))
        }
    }

    func removeEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func moveEntries(from: IndexSet, to: Int) {
        entries.move(fromOffsets: from, toOffset: to)
    }

    @discardableResult
    func addFolder(name: String = "Neuer Ordner") -> UUID {
        let f = DockFolder(name: name)
        entries.append(.folder(f))
        return f.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = folderIndex(id), case .folder(var f) = entries[i] else { return }
        f.name = name
        entries[i] = .folder(f)
    }

    func removeApp(_ appID: UUID, fromFolder folderID: UUID) {
        guard let i = folderIndex(folderID), case .folder(var f) = entries[i] else { return }
        f.apps.removeAll { $0.id == appID }
        entries[i] = .folder(f)
    }

    /// Verschiebt eine App (oben oder aus einem Ordner) in einen Ordner oder nach oben (nil).
    func moveApp(_ appID: UUID, toFolder target: UUID?) {
        var app: PinnedApp?
        var newEntries: [DockEntry] = []
        for e in entries {
            switch e {
            case .app(let a) where a.id == appID:
                app = a
            case .folder(var f):
                if let idx = f.apps.firstIndex(where: { $0.id == appID }) {
                    app = f.apps.remove(at: idx)
                }
                newEntries.append(.folder(f))
            default:
                newEntries.append(e)
            }
        }
        guard let app else { return }
        if let target, let i = newEntries.firstIndex(where: { $0.id == target }), case .folder(var f) = newEntries[i] {
            f.apps.append(app)
            newEntries[i] = .folder(f)
        } else {
            newEntries.append(.app(app))
        }
        entries = newEntries
    }

    func resetFromSystemDock() {
        entries = Self.importFromSystemDock()
    }

    private func folderIndex(_ id: UUID) -> Int? {
        entries.firstIndex { if case .folder(let f) = $0 { f.id == id } else { false } }
    }

    // MARK: Import aus dem Mac-Dock

    static func importFromSystemDock() -> [DockEntry] {
        var urls = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        for tile in (defaults?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? [] {
            guard let td = tile["tile-data"] as? [String: Any],
                  let fd = td["file-data"] as? [String: Any],
                  let s = fd["_CFURLString"] as? String else { continue }
            let url = s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s)
            if let url, FileManager.default.fileExists(atPath: url.path), url.pathExtension == "app" {
                urls.append(url)
            }
        }
        if urls.count == 1 {
            for p in ["/Applications/Safari.app", "/System/Applications/Mail.app", "/System/Applications/Notes.app",
                      "/System/Applications/Music.app", "/System/Applications/System Settings.app"]
            where FileManager.default.fileExists(atPath: p) {
                urls.append(URL(fileURLWithPath: p))
            }
        }
        var seen = Set<String>()
        return urls.map(PinnedApp.init(url:)).filter { seen.insert($0.key).inserted }.map(DockEntry.app)
    }
}
