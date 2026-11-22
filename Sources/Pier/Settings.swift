import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Pier"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceTab().tabItem { Label("Darstellung", systemImage: "paintbrush") }
            AppsTab().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            WidgetsTab().tabItem { Label("Widgets", systemImage: "clock") }
            GeneralTab().tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 580, height: 540)
    }
}

// MARK: Darstellung

struct AppearanceTab: View {
    @ObservedObject var store = DockStore.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ForEach(DockStyle.allCases) { style in
                        StyleChoice(style: style, selected: store.settings.style == style) {
                            store.settings.style = style
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: { Text("Stil") }

            Section {
                LabeledContent("Icon-Größe") {
                    HStack {
                        Slider(value: $store.settings.iconSize, in: 30...64, step: 2)
                        Text("\(Int(store.settings.iconSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                    }
                }
                Picker("Erscheinungsbild", selection: $store.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Dock automatisch ausblenden", isOn: $store.settings.autoHide)
            }

            Section {
                Toggle("Apps-Kachel (Launcher) anzeigen", isOn: $store.settings.showLauncher)
                Toggle("Laufende, nicht angepinnte Apps anzeigen", isOn: $store.settings.showRunningApps)
                Toggle("Fenster-Vorschau beim Darüberfahren", isOn: $store.settings.windowPreviews)
                Toggle("Klick auf aktive App blendet sie aus", isOn: $store.settings.clickHidesActiveApp)
            } header: { Text("Verhalten") }

            if store.settings.style == .bar {
                Section {
                    Text("Hinweis: macOS lässt Drittanbieter keinen Platz am Bildschirmrand reservieren. Maximierte Fenster reichen deshalb unter die Leiste. Wenn dich das stört, schalte „automatisch ausblenden“ ein.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct StyleChoice: View {
    let style: DockStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    if style == .pill {
                        HStack(spacing: 4) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.85)).frame(width: 12, height: 12)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.35)))
                        .padding(.bottom, 6)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.85)).frame(width: 9, height: 9)
                            }
                            ForEach(0..<2, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.35)).frame(width: 30, height: 9)
                            }
                            Spacer()
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.6)).frame(width: 18, height: 6)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Rectangle().fill(.black.opacity(0.35)))
                    }
                }
                .frame(height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                )
                Text(style.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Apps & Ordner

struct AppsTab: View {
    @ObservedObject var store = DockStore.shared

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.entries) { entry in
                    switch entry {
                    case .app(let app): AppRow(app: app, folderID: nil)
                    case .folder(let f): FolderRow(folder: f)
                    }
                }
                .onMove { store.moveEntries(from: $0, to: $1) }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button { store.addApps(pickApps()) } label: { Label("App hinzufügen…", systemImage: "plus") }
                Button { store.addFolder() } label: { Label("Ordner erstellen", systemImage: "folder.badge.plus") }
                Spacer()
                Menu("Mehr") {
                    Button("Apps vom Mac-Dock übernehmen") { store.resetFromSystemDock() }
                }
                .fixedSize()
            }
            .padding(12)
            Text("Reihenfolge per Ziehen ändern. Das Ordner-Symbol neben einer App verschiebt sie in einen Ordner.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

@MainActor
func pickApps() -> [URL] {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = false
    p.allowedContentTypes = [.application]
    p.directoryURL = URL(fileURLWithPath: "/Applications")
    p.prompt = "Hinzufügen"
    return p.runModal() == .OK ? p.urls : []
}

struct AppRow: View {
    let app: PinnedApp
    let folderID: UUID?
    @ObservedObject var store = DockStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forPath: app.path)).resizable().frame(width: 24, height: 24)
            Text(app.name)
            Spacer()
            Menu {
                if folderID != nil {
                    Button("Direkt ins Dock") { store.moveApp(app.id, toFolder: nil) }
                }
                ForEach(store.folders.filter { $0.id != folderID }) { f in
                    Button("In „\(f.name)“") { store.moveApp(app.id, toFolder: f.id) }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(folderID == nil && store.folders.isEmpty)
            .help("In Ordner verschieben")

            Button {
                if let folderID { store.removeApp(app.id, fromFolder: folderID) } else { store.removeEntry(app.id) }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Entfernen")
        }
        .padding(.vertical, 2)
    }
}

struct FolderRow: View {
    let folder: DockFolder
    @ObservedObject var store = DockStore.shared
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(folder.apps) { AppRow(app: $0, folderID: folder.id) }
            Button { store.addApps(pickApps(), toFolder: folder.id) } label: {
                Label("App zum Ordner hinzufügen…", systemImage: "plus")
            }
            .buttonStyle(.link)
            .padding(.vertical, 2)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).frame(width: 24)
                TextField("Ordnername", text: Binding(get: { folder.name }, set: { store.renameFolder(folder.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                Text("\(folder.apps.count) Apps").foregroundStyle(.secondary).font(.callout)
                Button { store.removeEntry(folder.id) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Ordner entfernen")
            }
        }
    }
}

// MARK: Widgets

struct WidgetsTab: View {
    @ObservedObject var store = DockStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Uhrzeit", isOn: $store.settings.showClock)
                Toggle("Datum unter der Uhrzeit", isOn: $store.settings.showDate).disabled(!store.settings.showClock)
                Toggle("Akku", isOn: $store.settings.showBattery)
                Toggle("Aktuelle Musik (Apple Music, Spotify)", isOn: $store.settings.showNowPlaying)
            } header: { Text("Im Dock anzeigen") } footer: {
                Text("Die Musik-Anzeige erscheint, sobald Music oder Spotify einen Titel startet oder pausiert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Allgemein

struct GeneralTab: View {
    @ObservedObject var store = DockStore.shared
    @ObservedObject var running = RunningAppsModel.shared
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Mac-Dock ausblenden", isOn: $store.settings.hideSystemDock)
                Toggle("Launcher mit ⌥ Leertaste öffnen", isOn: $store.settings.launcherHotKey)
                Toggle("Beim Anmelden starten", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            loginItem = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                PermissionRow(title: "Bedienungshilfen", detail: "Für Fensterliste, Fenster nach vorne holen und Musiksteuerung.",
                              granted: running.axTrusted, request: Permissions.requestAccessibility)
                PermissionRow(title: "Bildschirmaufnahme", detail: "Nur für die Live-Vorschaubilder der Fenster.",
                              granted: running.screenRecording, request: Permissions.requestScreenRecording)
            } header: { Text("Berechtigungen") }

            Section {
                HStack {
                    Text("Beim Beenden wird das Mac-Dock wiederhergestellt.").foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button("Pier beenden") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Erlauben…", action: request) }
        }
    }
}
