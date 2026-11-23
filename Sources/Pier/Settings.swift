import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(tab: SettingsNav.Tab? = nil, arrange: Bool = false) {
        if let tab { SettingsNav.shared.tab = tab }
        if arrange { SettingsNav.shared.showArrange = true }
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

@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    enum Tab: Hashable { case appearance, apps, widgets, general }
    @Published var tab: Tab = .appearance
    @Published var showArrange = false
}

struct SettingsView: View {
    @ObservedObject var nav = SettingsNav.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            AppearanceTab().tabItem { Label("Darstellung", systemImage: "paintbrush") }.tag(SettingsNav.Tab.appearance)
            AppsTab().tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(SettingsNav.Tab.apps)
            WidgetsTab().tabItem { Label("Widgets", systemImage: "clock") }.tag(SettingsNav.Tab.widgets)
            GeneralTab().tabItem { Label("Allgemein", systemImage: "gearshape") }.tag(SettingsNav.Tab.general)
        }
        .frame(width: 580, height: 540)
    }
}

// MARK: Darstellung

struct AppearanceTab: View {
    @ObservedObject var store = DockStore.shared
    @ObservedObject var widgets = WidgetModel.shared

    /// „main“, „all“ oder die UUID eines Bildschirms.
    private var screenChoice: Binding<String> {
        Binding(get: { store.settings.allScreens ? "all" : (store.settings.screenUUID ?? "main") },
                set: { v in
                    store.settings.allScreens = v == "all"
                    store.settings.screenUUID = v == "all" || v == "main" ? nil : v
                })
    }

    private var positionNote: String {
        if store.settings.style == .bar {
            return "Die schlanke Leiste sitzt immer unten – seitlich gibt es nur die Pille. Beschriftung „Automatisch“ zeigt den Namen nur, wenn genug Platz ist. „Fenster gruppieren: Automatisch“ fasst die Fenster einer App erst zusammen, wenn es eng wird."
        }
        if store.settings.isFree {
            return "Frei: Zieh die Pille am Griff (≡) an eine beliebige Stelle. Dort bleibt sie, auch nach einem Neustart."
        }
        return "Ausrichtung schiebt die Pille an den Anfang oder das Ende ihrer Kante, „Frei“ macht sie frei verschiebbar."
    }

    private var customColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: store.settings.customColor) ?? .systemBlue) },
                set: { store.settings.customColor = NSColor($0).hexString })
    }

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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 12) {
                    ForEach(DockTheme.allCases) { theme in
                        // Vorschau von „Now Playing“: aktuelles Cover, sonst eine Beispielfarbe.
                        let art = theme == .nowPlaying ? Color(nsColor: widgets.artworkColor ?? .systemPink) : nil
                        ThemeChoice(theme: theme, colors: theme.colors(custom: customColor.wrappedValue, artwork: art),
                                    selected: store.settings.theme == theme) {
                            store.settings.theme = theme
                        }
                    }
                }
                .padding(.vertical, 4)
                if store.settings.theme == .custom {
                    ColorPicker("Eigene Farbe", selection: customColor, supportsOpacity: false)
                }
            } header: { Text("Farbthema") } footer: {
                if store.settings.theme == .nowPlaying {
                    Text("Färbt Dock und Akzent nach dem Cover des Titels, der gerade in Music oder Spotify läuft. Ohne Musik sieht es aus wie „System“. Beim ersten Mal fragt macOS, ob Pier die App steuern darf.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

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
                Picker("Position", selection: $store.settings.edge) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(store.settings.style == .bar)
                Picker("Ausrichtung", selection: $store.settings.placement) {
                    ForEach(PillPlacement.allCases) { Text($0.title(vertical: store.settings.edge.isVertical)).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(store.settings.style == .bar)
                Picker("Beschriftung der Leiste", selection: $store.settings.barLabels) {
                    ForEach(BarLabels.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(store.settings.style != .bar)
                Picker("Fenster gruppieren", selection: $store.settings.windowGrouping) {
                    ForEach(WindowGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(store.settings.style != .bar)
                Picker("Bildschirm", selection: screenChoice) {
                    Text("Hauptbildschirm").tag("main")
                    ForEach(NSScreen.screens, id: \.displayID) { s in
                        if let uuid = s.uuid { Text(s.localizedName).tag(uuid) }
                    }
                    Text("Alle Bildschirme").tag("all")
                }
                Toggle("Dock automatisch ausblenden", isOn: $store.settings.autoHide)
                    .disabled(store.settings.isFree)
            } footer: {
                Text(positionNote).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Apps-Kachel (Launcher) anzeigen", isOn: $store.settings.showLauncher)
                Toggle("Laufende, nicht angepinnte Apps anzeigen", isOn: $store.settings.showRunningApps)
                Picker("Reihenfolge laufender Apps", selection: $store.settings.runningOrder) {
                    ForEach(RunningOrder.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!store.settings.showRunningApps)
                .help("Angepinnte Apps bleiben immer in deiner Reihenfolge.")
                Toggle("Fenster-Vorschau beim Darüberfahren", isOn: $store.settings.windowPreviews)
                Toggle("Klick auf aktive App blendet sie aus", isOn: $store.settings.clickHidesActiveApp)
                Toggle("Scrollen über einem Icon wechselt die Fenster", isOn: $store.settings.scrollCyclesWindows)
                Toggle("⌃ halten zeigt CPU und Speicher je App", isOn: $store.settings.showActivity)
                Toggle("Nur Fenster des aktuellen Schreibtischs zeigen", isOn: $store.settings.currentSpaceOnly)
                Toggle("Scrollen auf einer Titelleiste ordnet das Fenster an", isOn: $store.settings.titlebarScroll)
                    .help("Hoch: maximieren · Runter: zentrieren · Links/Rechts: Bildschirmhälfte")
            } header: { Text("Verhalten") }

            Section {
                Toggle("Fenster automatisch über dem Dock halten", isOn: $store.settings.fitWindows)
                    .disabled(store.settings.autoHide || store.settings.effectiveEdge != .bottom || store.settings.isFree)
            } footer: {
                Text("Wird ein Fenster so groß gezogen oder gezoomt, dass es unter das Dock reicht, kürzt Pier es bis zur Oberkante. Bei „automatisch ausblenden“ nicht nötig, und nur für das Dock unten (nicht frei schwebend).")
                    .font(.caption).foregroundStyle(.secondary)
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

/// Vorschau eines Farbthemas: getöntes Glas mit dem Akzent-Strich der aktiven App.
struct ThemeChoice: View {
    let theme: DockTheme
    let colors: ThemeColors
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    if theme.isClear {
                        // Transparent: angedeuteter Schreibtisch-Hintergrund statt Glas.
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.3)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
                    }
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: colors.glass.isEmpty ? [.clear] : colors.glass.map { $0.opacity(0.55) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Capsule().fill(colors.accent).frame(width: 22, height: 3.5)
                        .shadow(color: colors.accent.opacity(0.6), radius: 3)
                        .padding(.bottom, 7)
                }
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                )
                Text(theme.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Farbthema \(theme.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Apps & Ordner

struct AppsTab: View {
    @ObservedObject var store = DockStore.shared
    @ObservedObject var nav = SettingsNav.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { nav.showArrange = true } label: {
                    Label("Intelligent anordnen…", systemImage: "wand.and.stars")
                }
                .controlSize(.large)
                if store.undoEntries != nil {
                    Button("Rückgängig") { store.undoArrangement() }
                }
                Spacer()
            }
            .padding(12)
            List {
                ForEach(store.entries) { entry in
                    switch entry {
                    case .app(let app): AppRow(app: app, folderID: nil)
                    case .folder(let f): FolderRow(folder: f)
                    case .stack(let s): StackRow(stack: s)
                    case .separator(let s): SeparatorRow(separator: s)
                    case .file(let f): FileRow(file: f)
                    }
                }
                .onMove { store.moveEntries(from: $0, to: $1) }
            }
            .listStyle(.inset)
            .sheet(isPresented: $nav.showArrange) { ArrangeSheet() }

            Divider()
            HStack {
                Button { store.addApps(pickApps()) } label: { Label("App hinzufügen…", systemImage: "plus") }
                Button { store.addFolder() } label: { Label("Ordner erstellen", systemImage: "folder.badge.plus") }
                Button { store.addStacks(pickFolders()) } label: { Label("Stapel…", systemImage: "tray.full") }
                    .help("Einen Finder-Ordner (z. B. Downloads) als Stapel ins Dock legen")
                Spacer()
                Menu("Mehr") {
                    Button("Datei hinzufügen…") { store.addFiles(pickFiles()) }
                    Button("Trennlinie hinzufügen") { store.addSeparator() }
                    Button("Apps vom Mac-Dock übernehmen") { store.resetFromSystemDock() }
                }
                .fixedSize()
            }
            .padding(12)
            if !store.settings.excludedApps.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nicht angezeigte Apps").font(.callout.weight(.medium))
                    ForEach(store.settings.excludedApps.sorted { $0.value < $1.value }, id: \.key) { key, name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Wieder anzeigen") { store.settings.excludedApps[key] = nil }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 10)
            }
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

@MainActor
func pickFolders(prompt: String = "Als Stapel hinzufügen",
                 directory: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first) -> [URL] {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.directoryURL = directory
    p.prompt = prompt
    return p.runModal() == .OK ? p.urls : []
}

@MainActor
func pickFiles() -> [URL] {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = false
    p.prompt = "Ins Dock legen"
    return p.runModal() == .OK ? p.urls : []
}

struct FileRow: View {
    let file: DockFile
    @ObservedObject var store = DockStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forPath: file.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { store.removeEntry(file.id) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Datei entfernen")
        }
        .padding(.vertical, 2)
    }
}

struct StackRow: View {
    let stack: DockStack
    @ObservedObject var store = DockStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forPath: stack.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(stack.name)
                Text(stack.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { store.removeEntry(stack.id) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Stapel entfernen")
        }
        .padding(.vertical, 2)
    }
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
                Toggle("Akku (darüberfahren zeigt Zustand und Ladezyklen)", isOn: $store.settings.showBattery)
                Toggle("Ton: Ausgang und Eingang wechseln", isOn: $store.settings.showSound)
                Toggle("Geräte: externe Laufwerke auswerfen", isOn: $store.settings.showDevices)
                Toggle("Bluetooth-Geräte in der Geräte-Liste", isOn: $store.settings.showBluetooth)
                    .disabled(!store.settings.showDevices)
                Toggle("Aktuelle Musik (Apple Music, Spotify)", isOn: $store.settings.showNowPlaying)
                Toggle("Badges, Fortschritt und Hinweise an App-Icons", isOn: $store.settings.showBadges)
            } header: { Text("Im Dock anzeigen") } footer: {
                Text("Darüberfahren über die Uhr zeigt Kalender und Zifferblatt. Die Musik-Anzeige erscheint, sobald Music oder Spotify einen Titel startet oder pausiert. Badges übernimmt Pier vom ausgeblendeten Mac-Dock (braucht Bedienungshilfen). Die Geräte-Kachel erscheint, sobald ein Laufwerk angeschlossen ist oder Bluetooth eingeschaltet ist; macOS fragt beim ersten Öffnen nach der Bluetooth-Erlaubnis.")
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
                Toggle("Angepinnte Apps mit ⌃⌥1 … 9 öffnen", isOn: $store.settings.appHotKeys)
                Toggle("Fenster mit ⌥Tab wechseln", isOn: $store.settings.altTab)
                    .help("⌥ halten, Tab drücken (⇧ rückwärts), ⌥ loslassen wechselt. ⌥Esc bricht ab.")
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
                ForEach(store.settings.launcherFolders, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(nsImage: IconCache.icon(forPath: path)).resizable().frame(width: 20, height: 20)
                        Text(FileManager.default.displayName(atPath: path))
                        Spacer()
                        Button { store.settings.launcherFolders.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Aus dem Launcher entfernen")
                    }
                }
                Button { addLauncherFolders() } label: { Label("Ordner hinzufügen…", systemImage: "plus") }
            } header: { Text("Eigene Ordner im Launcher") } footer: {
                Text("Erscheinen im Launcher unter „Ordner“ neben Benutzerordner, Schreibtisch, Dokumenten, Downloads und Programmen.")
                    .font(.caption).foregroundStyle(.secondary)
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

extension GeneralTab {
    @MainActor
    func addLauncherFolders() {
        for u in pickFolders(prompt: "Hinzufügen", directory: nil) where !store.settings.launcherFolders.contains(u.standardizedFileURL.path) {
            store.settings.launcherFolders.append(u.standardizedFileURL.path)
        }
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

struct SeparatorRow: View {
    let separator: DockSeparator
    @ObservedObject var store = DockStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 24, height: 1.5)
            Text("Trennlinie").foregroundStyle(.secondary)
            Spacer()
            Button { store.removeEntry(separator.id) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Trennlinie entfernen")
        }
        .padding(.vertical, 2)
    }
}

// MARK: Intelligent anordnen

struct ArrangeSheet: View {
    @ObservedObject var store = DockStore.shared
    @ObservedObject var usage = UsageTracker.shared
    @Environment(\.dismiss) private var dismiss
    @State private var options = SmartArranger.Options()
    @State private var pinSuggestions = true
    @State private var declined: Set<String> = []
    @State private var suggestions: [PinnedApp] = []
    /// Gruppenreihenfolge, die du hier festlegst; leer = automatisch nach Nutzung.
    @State private var order: [AppCategory] = []
    @State private var orderChanged = false

    private var days: Int { usage.book.trackedDays(now: Date()) }
    private var canFindRare: Bool { days >= 14 }

    var body: some View {
        let plan = makePlan()
        // „neu“ nur für Apps, die noch nirgends im Dock liegen (auch nicht in einem Ordner).
        let existing = Set(store.entries.flatMap { e -> [String] in
            switch e {
            case .app(let a): [a.key]
            case .folder(let f): f.apps.map(\.key)
            default: []
            }
        })
        let newKeys = Set(suggestions.map(\.key)).subtracting(existing).subtracting(declined)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Intelligent anordnen").font(.title2.weight(.semibold))
                Text(learningNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Apps, die du gerade oder oft benutzt, anheften", isOn: $pinSuggestions)
                Toggle("Trennlinien zwischen den Gruppen", isOn: $options.separators)
                Toggle("Selten benutzte Apps in den Ordner „\(SmartArranger.rareFolderName)“", isOn: $options.rareIntoFolder)
                    .disabled(!canFindRare)
                    .help(canFindRare ? "" : "Pier braucht dafür mindestens 14 Tage Nutzungsdaten.")
            }

            HStack {
                Text("Gruppen ziehen oder mit den Pfeilen verschieben – oben in der Liste steht ganz links im Dock.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !order.isEmpty {
                    Button("Automatisch") {
                        order = []
                        orderChanged = true
                    }
                    .buttonStyle(.link).font(.caption)
                    .help("Gruppenreihenfolge wieder nach Nutzung bestimmen")
                }
            }

            List {
                ForEach(Array(plan.groups.enumerated()), id: \.element.id) { i, g in
                    PlanRow(title: g.category.title, symbol: g.category.symbol, apps: g.apps, newKeys: newKeys,
                            declined: $declined,
                            move: (up: i > 0 ? { moveGroup(from: i, to: i - 1, in: plan) } : nil,
                                   down: i < plan.groups.count - 1 ? { moveGroup(from: i, to: i + 2, in: plan) } : nil))
                }
                .onMove { from, to in
                    guard let i = from.first else { return }
                    moveGroup(from: i, to: to, in: plan)
                }
                if !plan.rare.isEmpty {
                    PlanRow(title: SmartArranger.rareFolderName, symbol: "folder", apps: plan.rare, newKeys: [],
                            declined: $declined, move: nil)
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)

            HStack {
                if pinSuggestions && !newKeys.isEmpty {
                    Text("„neu“ = wird angeheftet. Antippen, um eine App auszulassen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    if orderChanged { store.settings.groupOrder = order.map(\.rawValue) }
                    store.applyArrangement(plan.entries)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 520)
        .onAppear {
            suggestions = Self.suggestions(usage: usage)
            order = store.settings.groupOrder.compactMap(AppCategory.init(rawValue:))
        }
    }

    /// Verschiebt eine Gruppe; ab dann gilt die angezeigte Reihenfolge als festgelegt.
    private func moveGroup(from: Int, to: Int, in plan: SmartArranger.Plan) {
        var cats = plan.groups.map(\.category)
        cats.move(fromOffsets: IndexSet(integer: from), toOffset: to)
        // Gruppen, die gerade nicht vorkommen, behalten ihren Platz in der gespeicherten Reihenfolge (hinten).
        order = cats + order.filter { !cats.contains($0) }
        orderChanged = true
    }

    private var learningNote: String {
        let base = "Pier sortiert deine Apps in Gruppen – die meistbenutzte Gruppe und darin die meistbenutzte App zuerst."
        switch days {
        case 0: return base + " Pier hat gerade erst angefangen mitzulernen, wie lange du welche App nutzt – die Reihenfolge wird mit jedem Tag besser."
        case 1: return base + " Pier lernt seit einem Tag mit."
        default: return base + " Pier lernt seit \(days) Tagen mit."
        }
    }

    private func makePlan() -> SmartArranger.Plan {
        let now = Date()
        let book = usage.book
        let add = pinSuggestions ? suggestions.filter { !declined.contains($0.key) } : []
        var options = options
        options.order = order
        return SmartArranger.plan(entries: store.entries, add: add, options: options,
                                  score: { book.score($0, now: now) },
                                  isRare: { key in key != SmartArranger.finderID && book.score(key, now: now) < 2 },
                                  category: SmartArranger.category(of:))
    }

    /// Laufende Apps plus oft benutzte (auch gerade geschlossene), meistbenutzte zuerst, höchstens 12.
    static func suggestions(usage: UsageTracker) -> [PinnedApp] {
        let now = Date()
        let running = RunningAppsModel.shared.otherApps.compactMap { $0.bundleURL }
        let frequent = usage.book.apps.filter { usage.book.score($0.key, now: now) >= 30 }
            .map { URL(fileURLWithPath: $0.value.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        var seen = Set<String>()
        let apps = (running + frequent).map(PinnedApp.init(url:)).filter { seen.insert($0.key).inserted }
        return Array(apps.sorted { usage.book.score($0.key, now: now) > usage.book.score($1.key, now: now) }.prefix(12))
    }
}

struct PlanRow: View {
    let title: String
    let symbol: String
    let apps: [PinnedApp]
    let newKeys: Set<String>
    @Binding var declined: Set<String>
    /// Pfeile zum Verschieben (nil = Gruppe ist nicht verschiebbar bzw. steht schon am Rand).
    let move: (up: (() -> Void)?, down: (() -> Void)?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if move != nil {
                    Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
                }
                Label(title, systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let move {
                    Button { move.up?() } label: { Image(systemName: "chevron.up") }
                        .disabled(move.up == nil)
                        .help("Gruppe nach links (in der Liste nach oben)")
                        .accessibilityLabel("\(title) nach links")
                    Button { move.down?() } label: { Image(systemName: "chevron.down") }
                        .disabled(move.down == nil)
                        .help("Gruppe nach rechts (in der Liste nach unten)")
                        .accessibilityLabel("\(title) nach rechts")
                }
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(apps) { app in
                    let isNew = newKeys.contains(app.key)
                    VStack(spacing: 4) {
                        Image(nsImage: IconCache.icon(forPath: app.path)).resizable().interpolation(.high).frame(width: 40, height: 40)
                        Text(app.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(width: 74)
                    .overlay(alignment: .topTrailing) {
                        if isNew {
                            Text("neu").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if isNew { declined.insert(app.key) } }
                    .help(isNew ? "Antippen: nicht anheften" : "")
                }
            }
        }
    }
}
