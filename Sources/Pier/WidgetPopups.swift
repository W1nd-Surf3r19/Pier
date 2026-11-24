import AppKit
import CoreAudio
import EventKit
import SwiftUI

// MARK: Kalender mit Zifferblatt (beim Überfahren der Uhr)

enum MonthGrid {
    /// Deutscher Kalender: Woche beginnt am Montag.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = 2
        return c
    }

    /// Zellen eines Monats, zeilenweise ab Montag; nil = leere Zelle vor dem 1.
    static func cells(for date: Date, calendar: Calendar = MonthGrid.calendar) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let first = interval.start
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let dates = days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
        return Array(repeating: nil, count: leading) + dates.map { Optional($0) }
    }
}

/// Ein Termin aus der Kalender-App, auf das Nötige reduziert.
struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: CGColor?

    /// Verschiedene Kalenderfarben in Terminreihenfolge (nil = Kalender ohne Farbe).
    static func colors(of events: [CalEvent]) -> [CGColor?] {
        events.reduce(into: []) { out, e in if !out.contains(where: { $0 == e.color }) { out.append(e.color) } }
    }

    /// Termine eines Tages, Ganztägiges zuerst. Für heute nur, was noch nicht vorbei ist.
    static func on(_ day: Date, from events: [CalEvent], now: Date, calendar: Calendar = MonthGrid.calendar) -> [CalEvent] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let isToday = calendar.isDate(day, inSameDayAs: now)
        return events
            .filter { $0.start < dayEnd && $0.end > dayStart && (!isToday || $0.end > now) }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }
}

/// Liest Termine aus der Kalender-App (EventKit). Fragt erst, wenn der Nutzer im Popup darauf klickt.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    private let store = EKEventStore()
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)
    /// Termine des angezeigten Monats.
    @Published private(set) var events: [CalEvent] = []
    private var month = Date()

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarModel.shared.load() }
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { CalendarModel.shared.load() } }
        }
    }

    func show(month: Date) {
        self.month = month
        load()
    }

    func load() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess, let range = MonthGrid.calendar.dateInterval(of: .month, for: month) else {
            events = []
            return
        }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        let new = store.events(matching: predicate).map {
            CalEvent(id: ($0.eventIdentifier ?? UUID().uuidString) + "\($0.startDate.timeIntervalSince1970)",
                     title: $0.title ?? "Ohne Titel", start: $0.startDate, end: $0.endDate,
                     allDay: $0.isAllDay, color: $0.calendar?.cgColor)
        }
        if new != events { events = new }
    }
}

private func formatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateFormat = format
    return f
}

private let monthTitle = formatter("LLLL yyyy")
private let longDate = formatter("EEEE, d. MMMM")
private let shortTime = formatter("HH:mm")

struct CalendarPopup: View {
    @State private var month = Date()
    @State private var selected = Date()
    @ObservedObject private var model = CalendarModel.shared
    @Environment(\.dockTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            monthView
            Divider()
            agenda.frame(width: 348, alignment: .leading)   // Breite der Zeile darüber (130 + 18 + 200)
        }
        .padding(14)
        .onAppear { model.show(month: month) }
        .onChange(of: month) {
            // Geladen wird nur der angezeigte Monat – die Auswahl wandert mit.
            if !MonthGrid.calendar.isDate(selected, equalTo: month, toGranularity: .month) { selected = month }
            model.show(month: month)
        }
    }

    private var monthView: some View {
        let cal = MonthGrid.calendar
        let cells = MonthGrid.cells(for: month, calendar: cal)
        let today = Date()
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                AnalogClock().frame(width: 116, height: 116)
                Text(longDate.string(from: today))
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .frame(width: 130)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(monthTitle.string(from: month)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    monthButton("chevron.left", help: "Vorheriger Monat", by: -1)
                    Button { month = Date(); selected = Date() } label: { Image(systemName: "circle.fill").font(.system(size: 6)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Heute").accessibilityLabel("Heute")
                    monthButton("chevron.right", help: "Nächster Monat", by: 1)
                }
                let columns = Array(repeating: GridItem(.fixed(26), spacing: 2), count: 7)
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"], id: \.self) {
                        Text($0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day, today: today, cal: cal)
                        } else {
                            Color.clear.frame(width: 24, height: 27)
                        }
                    }
                }
            }
            .frame(width: 200)
        }
    }

    private func dayCell(_ day: Date, today: Date, cal: Calendar) -> some View {
        let isToday = cal.isDate(day, inSameDayAs: today)
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let dayEvents = CalEvent.on(day, from: model.events, now: .distantPast, calendar: cal)
        let busy = !dayEvents.isEmpty
        return Button { selected = day } label: {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 11.5, weight: isToday ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : Color.primary)
                .frame(width: 24, height: 22)
                .background(Circle().fill(isToday ? theme.accent : .clear))
                .overlay(Circle().strokeBorder(theme.accent, lineWidth: isSelected && !isToday ? 1.5 : 0))
                // Ein Punkt je Kalenderfarbe (höchstens 3), unter der Zahl.
                .frame(height: 27, alignment: .top)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 2) {
                        ForEach(Array(CalEvent.colors(of: dayEvents).prefix(3).enumerated()), id: \.offset) { _, c in
                            Circle().fill(c.map { Color(cgColor: $0) } ?? theme.accent).frame(width: 4, height: 4)
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(longDate.string(from: day) + (busy ? ", mit Terminen" : ""))
    }

    @ViewBuilder private var agenda: some View {
        let isToday = MonthGrid.calendar.isDateInToday(selected)
        VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "Heute noch" : longDate.string(from: selected))
                .font(.system(size: 12, weight: .semibold))
            switch model.status {
            case .fullAccess:
                let list = CalEvent.on(selected, from: model.events, now: Date())
                if list.isEmpty {
                    Text(isToday ? "Keine Termine mehr" : "Keine Termine")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    ForEach(list.prefix(6)) { eventRow($0) }
                    if list.count > 6 {
                        Text("+ \(list.count - 6) weitere").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            case .notDetermined:
                Button("Termine aus der Kalender-App anzeigen") { model.requestAccess() }
                    .controlSize(.small)
            default:
                Text("Pier hat keinen Zugriff auf deine Kalender.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button("Systemeinstellungen öffnen") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func eventRow(_ e: CalEvent) -> some View {
        let color = e.color.map { Color(cgColor: $0) } ?? theme.accent
        let now = Date()
        let running = !e.allDay && e.start <= now && e.end > now
        return HStack(spacing: 7) {
            Capsule().fill(color).frame(width: 3)
            Text(e.allDay ? "ganztägig" : "\(shortTime.string(from: e.start))–\(shortTime.string(from: e.end))")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(e.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if running {
                Text("jetzt").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(color))
            }
        }
        .padding(.vertical, 4).padding(.leading, 4).padding(.trailing, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(running ? 0.32 : 0.18)))
        .accessibilityElement(children: .combine)
    }

    private func monthButton(_ symbol: String, help: String, by delta: Int) -> some View {
        Button { month = MonthGrid.calendar.date(byAdding: .month, value: delta, to: month) ?? month } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct AnalogClock: View {
    @Environment(\.dockTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let c = MonthGrid.calendar.dateComponents([.hour, .minute, .second], from: ctx.date)
            let s = Double(c.second ?? 0), m = Double(c.minute ?? 0) + s / 60, h = Double((c.hour ?? 0) % 12) + m / 60
            Canvas { g, size in
                let r = min(size.width, size.height) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                g.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: size.width, height: size.height)), with: .color(.primary.opacity(0.07)))
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * .pi
                    let long = i % 5 == 0
                    let inner = r - (long ? 10 : 5), outer = r - 3
                    var p = Path()
                    p.move(to: point(center, inner, a))
                    p.addLine(to: point(center, outer, a))
                    g.stroke(p, with: .color(.primary.opacity(long ? 0.7 : 0.25)), lineWidth: long ? 2 : 1)
                }
                func hand(_ fraction: Double, _ length: CGFloat, _ width: CGFloat, _ color: Color) {
                    var p = Path()
                    p.move(to: center)
                    p.addLine(to: point(center, length, fraction * 2 * .pi))
                    g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                hand(h / 12, r * 0.5, 3.5, .primary)
                hand(m / 60, r * 0.75, 2.5, .primary)
                hand(s / 60, r * 0.82, 1, theme.accent)
                g.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(theme.accent))
            }
        }
        .accessibilityLabel("Uhr")
    }

    /// Winkel 0 = 12 Uhr, im Uhrzeigersinn.
    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
    }
}

// MARK: Akku (beim Überfahren der Akku-Anzeige)

struct BatteryPopup: View {
    @ObservedObject var model = WidgetModel.shared
    @State private var health = BatteryHealth.read()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let b = model.battery {
                HStack(alignment: .firstTextBaseline) {
                    Text("Akku").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 24)
                    Text("\(b.level) %").font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                Text(Self.status(b)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Divider()
            if let health {
                if let max = health.maxCapacity {
                    row("Maximale Kapazität", "\(max) %")
                    row("Zustand", max >= 80 ? "Normal" : "Wartung empfohlen")
                }
                if let cycles = health.cycles {
                    row("Ladezyklen", health.designCycles.map { "\(cycles) von \($0)" } ?? "\(cycles)")
                }
            } else {
                Text("Keine Akkudaten verfügbar.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Button("Batterie-Einstellungen…") {
                Coordinator.shared.popup.hide()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
        }
        .padding(12)
        .frame(width: 240)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }

    static func status(_ b: BatteryState) -> String {
        let time = b.minutes.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) + " Std." }
        if b.charging { return time.map { "Lädt – voll in \($0)" } ?? "Lädt" }
        if b.onPower { return "Am Netzteil" }
        return time.map { "Batterie – noch \($0)" } ?? "Batterie"
    }
}

// MARK: Ton (Klick auf das Lautsprecher-Symbol)

struct SoundPopup: View {
    @State private var devices: [AudioDevice] = []
    @State private var output: AudioDeviceID = 0
    @State private var input: AudioDeviceID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("Ausgang", devices.filter(\.hasOutput), selected: output, input: false)
            Divider().padding(.vertical, 2)
            section("Eingang", devices.filter(\.hasInput), selected: input, input: true)
            Divider().padding(.vertical, 2)
            Button("Ton-Einstellungen…") {
                Coordinator.shared.popup.hide()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
            .padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: 280)
        .onAppear(perform: reload)
    }

    private func reload() {
        devices = AudioDevices.all()
        output = AudioDevices.defaultDevice(input: false)
        input = AudioDevices.defaultDevice(input: true)
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [AudioDevice], selected: AudioDeviceID, input: Bool) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
        if list.isEmpty {
            Text("Keine Geräte").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 6)
        }
        ForEach(list) { d in
            PopupRow(symbol: d.id == selected ? "checkmark" : nil, title: d.name) {
                AudioDevices.setDefault(d.id, input: input)
                reload()
            }
        }
    }
}

// MARK: Geräte (Laufwerke auswerfen, Bluetooth)

struct DevicesPopup: View {
    @ObservedObject var model = DevicesModel.shared
    @ObservedObject var store = DockStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Laufwerke").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.volumes.count > 1 {
                    Button("Alle auswerfen") { model.ejectAll() }.buttonStyle(.link).font(.system(size: 11.5))
                }
            }
            .padding(.horizontal, 6)
            if model.volumes.isEmpty {
                Text("Keine externen Laufwerke").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            ForEach(model.volumes) { v in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.icon(forPath: v.url.path)).resizable().frame(width: 20, height: 20)
                    Text(v.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 12)
                    if model.ejecting.contains(v.url) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { model.eject(v) } label: { Image(systemName: "eject.fill").font(.system(size: 11)) }
                            .buttonStyle(.plain)
                            .help("„\(v.name)“ auswerfen")
                            .accessibilityLabel("„\(v.name)“ auswerfen")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(v.url) }
            }

            if store.settings.showBluetooth {
                Divider().padding(.vertical, 2)
                Text("Bluetooth").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
                if model.bluetooth.isEmpty {
                    Text("Keine gekoppelten Geräte – oder Pier darf Bluetooth nicht nutzen (Systemeinstellungen › Datenschutz).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.bluetooth) { d in
                    HStack(spacing: 8) {
                        Circle().fill(d.connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(d.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 12)
                        if model.busyBluetooth.contains(d.address) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(d.connected ? "Trennen" : "Verbinden") { model.toggle(d) }
                                .buttonStyle(.link).font(.system(size: 11.5))
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
            }

            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
            }
        }
        .padding(10)
        .frame(width: 290)
    }
}

/// Auswählbare Zeile in einem Widget-Popup.
struct PopupRow: View {
    let symbol: String?
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol ?? "checkmark").font(.system(size: 10, weight: .bold))
                    .opacity(symbol == nil ? 0 : 1).frame(width: 12)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverAlways { h, _ in hovering = h }
    }
}
