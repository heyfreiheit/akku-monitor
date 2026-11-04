import Charts
import ServiceManagement
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview = "Übersicht"
    case history = "Verlauf"
    case apps = "Apps"
    case chrome = "Chrome-Tabs"
    case sleep = "Ruhezustand"
    case health = "Akku-Zustand"
    case settings = "Einstellungen"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .history: "chart.xyaxis.line"
        case .apps: "square.grid.2x2"
        case .chrome: "globe"
        case .sleep: "moon"
        case .health: "heart.text.square"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var m: Monitor
    @State private var section: Section? = .overview

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollView {
                Group {
                    switch section ?? .overview {
                    case .overview: OverviewView()
                    case .history: HistoryView()
                    case .apps: AppsView()
                    case .chrome: ChromeView()
                    case .sleep: SleepView()
                    case .health: HealthView()
                    case .settings: SettingsView()
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            .navigationTitle((section ?? .overview).rawValue)
        }
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Übersicht

struct OverviewView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        let week = Date().addingTimeInterval(-7 * 86400)
        let r = m.reading
        let avg = m.batteryAverage(since: week)
        let logRate = m.logAwakeRate(since: week)
        let fullWh = r?.fullWh ?? 90
        let avgW: Double? = avg?.watts ?? logRate.map { $0.pctPerHour / 100 * fullWh }
        let now = m.recentAverage(seconds: 30) ?? m.live.last?.sysW

        VStack(alignment: .leading, spacing: 20) {
            Panel {
                HStack(alignment: .top, spacing: 24) {
                    Metric(label: "Verbrauch gerade", value: now.map(Fmt.watts) ?? "…",
                           sub: r.map { $0.ac ? "am Netzteil" : (m.remainingHours.map { "noch etwa \(Fmt.hours($0))" } ?? "auf Akku") })
                    Divider().frame(height: 56)
                    Metric(label: "Ø auf Akku, 7 Tage", value: avgW.map(Fmt.watts) ?? "–",
                           sub: avg != nil ? "eigene Messung" : (logRate != nil ? "aus macOS-Protokoll" : "noch keine Daten"))
                    Divider().frame(height: 56)
                    Metric(label: "Laufzeit mit voller Ladung", value: avgW.map { Fmt.hours(fullWh / $0) } ?? "–",
                           sub: "bei deinem Ø-Verbrauch")
                    Divider().frame(height: 56)
                    Metric(label: "Akku-Gesundheit", value: r.map { "\(Int($0.healthPct)) %" } ?? "–",
                           sub: r.map { "\($0.cycles) Zyklen" })
                }
            }

            Panel {
                SectionHeader(title: "Diagnose", note: "Was die Messwerte über deinen Akku sagen")
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Diagnosis.findings(m)) { FindingRow(f: $0) }
                }
            }

            Panel {
                SectionHeader(title: "Leistung der letzten 24 Stunden",
                              note: "Fahr mit der Maus über das Diagramm für Details. Flächen fallen auf null, wenn der Mac schläft.")
                let data = m.powerSeries(range: 86400)
                if data.count > 2 {
                    PowerChart(samples: data, height: 240, domain: Date().addingTimeInterval(-86400)...Date())
                } else {
                    EmptyHint(text: "Die App sammelt gerade die ersten Messwerte. In ein paar Minuten steht hier der Verlauf.")
                }
                PartLegend()
            }
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Verlauf

struct HistoryView: View {
    @EnvironmentObject var m: Monitor
    @State private var range: Double = 86400

    var body: some View {
        let from = Date().addingTimeInterval(-range)
        let step = ChartData.step(for: range)
        let power = m.powerSeries(range: range)

        VStack(alignment: .leading, spacing: 20) {
            Picker("Zeitraum", selection: $range) {
                Text("2 Std").tag(2.0 * 3600)
                Text("6 Std").tag(6.0 * 3600)
                Text("24 Std").tag(86400.0)
                Text("7 Tage").tag(7.0 * 86400)
                Text("30 Tage").tag(30.0 * 86400)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            Panel {
                SectionHeader(title: "Ladestand", note: "Graue Flächen: am Netzteil. Vor dem ersten Start der App stammen die Punkte aus dem macOS-Energieprotokoll.")
                let pts = chargePoints(from: from, step: step)
                if pts.count > 1 { ChargeChart(points: pts, height: 180, domain: from...Date()) } else { EmptyHint(text: "Noch keine Daten für diesen Zeitraum.") }
            }

            Panel {
                SectionHeader(title: "Leistung nach Bereich")
                if power.count > 2 { PowerChart(samples: power, height: 240, domain: from...Date()) } else { EmptyHint(text: "Noch keine Messwerte für diesen Zeitraum.") }
                PartLegend()
            }

            Panel {
                SectionHeader(title: "Akku-Sitzungen", note: "Vom Abstecken bis zum Einstecken. Verbrauch und Laufzeit zählen nur die wache Zeit.")
                let sessions = m.sessions(since: from)
                if sessions.isEmpty {
                    EmptyHint(text: "Noch keine Akku-Sitzung gemessen. Zieh das Kabel und arbeite ganz normal.")
                } else {
                    SessionTable(sessions: sessions)
                }
            }

            let logAwake = m.log.awake.filter { $0.start >= from }.reversed()
            if !logAwake.isEmpty {
                Panel {
                    SectionHeader(title: "Wache Akku-Phasen laut macOS", note: "Aus dem Energieprotokoll, nur auf ganze Prozent genau.")
                    LogPhaseTable(phases: Array(logAwake))
                }
            }
        }
    }

    private func chargePoints(from: Date, step: TimeInterval) -> [ChargePoint] {
        let own = ChartData.buckets(m.history + m.live.suffix(3), from: from, step: min(step, 1800)).filter { $0.sysW > 0 }
        let firstOwn = own.first?.t ?? Date()
        let fromLog = m.log.charge.filter { $0.date >= from && $0.date < firstOwn }.map { ChargePoint(t: $0.date, pct: $0.pct, ac: !$0.onBattery) }
        return fromLog + own.map { ChargePoint(t: $0.t, pct: $0.pct, ac: $0.ac) }
    }
}

struct SessionTable: View {
    let sessions: [BatterySession]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("Start"); Text("Wach auf Akku"); Text("Ladestand"); Text("Ø Leistung"); Text("Spitze"); Text("pro Stunde"); Text("Volle Ladung reicht")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(sessions.prefix(40)) { s in
                GridRow {
                    Text(Fmt.dayTime.string(from: s.start))
                    Text(Fmt.hours(s.awakeHours))
                    Text("\(s.startPct) → \(s.endPct) %")
                    Text(Fmt.watts(s.avgW)).foregroundStyle(color(s.avgW))
                    Text(Fmt.watts(s.peakW)).foregroundStyle(.secondary)
                    Text("\(Fmt.num(s.pctPerHour)) %")
                    Text(s.avgW > 0 ? Fmt.hours((Monitor.shared.reading?.fullWh ?? 90) / s.avgW) : "–")
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }

    private func color(_ w: Double) -> Color { w > 15 ? Theme.critical : (w > 9 ? Color.primary : Color.primary) }
}

struct LogPhaseTable: View {
    let phases: [LogPhase]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("Start"); Text("Dauer"); Text("Ladestand"); Text("Verlust"); Text("pro Stunde")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(phases.prefix(40)) { p in
                GridRow {
                    Text(Fmt.dayTime.string(from: p.start))
                    Text(Fmt.hours(p.hours))
                    Text("\(p.startPct) → \(p.endPct) %")
                    Text("\(p.drop) %")
                    Text("\(Fmt.num(p.pctPerHour)) %")
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }
}

// MARK: - Apps

struct AppsView: View {
    @EnvironmentObject var m: Monitor
    @State private var range: Double = 86400
    @State private var batteryOnly = true

    var body: some View {
        let totals = m.appTotals(since: Date().addingTimeInterval(-range), batteryOnly: batteryOnly)
        let top = Array(totals.prefix(14))
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Picker("Zeitraum", selection: $range) {
                    Text("24 Std").tag(86400.0)
                    Text("7 Tage").tag(7.0 * 86400)
                    Text("30 Tage").tag(30.0 * 86400)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Toggle("Nur Akkubetrieb", isOn: $batteryOnly)
            }

            Panel {
                SectionHeader(title: "Prozessor-Energie pro App",
                              note: "macOS misst pro App nur den Prozessor. Grafik und Bildschirm lassen sich keiner App zuordnen, die siehst du im Verlauf.")
                if top.isEmpty {
                    EmptyHint(text: batteryOnly ? "Noch keine Messung im Akkubetrieb. Zieh das Kabel und arbeite eine Weile." : "Noch keine Messwerte.")
                } else {
                    Chart(top) { a in
                        BarMark(x: .value("Wh", a.wh), y: .value("App", a.name), width: .fixed(14))
                            .foregroundStyle(Theme.single)
                            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                            .annotation(position: .trailing, spacing: 6) {
                                Text("\(Fmt.wh(a.wh)) · \(Int((a.share * 100).rounded())) %")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                    }
                    .chartXAxis {
                        AxisMarks { v in
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.wh(d)) } }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { v in
                            AxisValueLabel {
                                if let n = v.as(String.self) {
                                    HStack(spacing: 6) { AppIcon(name: n, paths: m.bundlePaths, size: 14); Text(n) }
                                }
                            }
                        }
                    }
                    .chartXScale(range: .plotDimension(endPadding: 90))
                    .frame(height: CGFloat(top.count) * 28 + 30)
                }
            }

            Panel {
                SectionHeader(title: "Gerade jetzt", note: "Mittel der letzten 5 Minuten")
                let live = m.appAverages().filter { $0.watts >= 0.05 }.prefix(12)
                if live.isEmpty { EmptyHint(text: "Messe …") }
                ForEach(Array(live)) { a in
                    HStack(spacing: 10) {
                        AppIcon(name: a.name, paths: m.bundlePaths)
                        Text(a.name)
                        Spacer()
                        Text(Fmt.watts(a.watts)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Ruhezustand

struct SleepView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        let week = Date().addingTimeInterval(-7 * 86400)
        let rate = m.logSleepRate(since: week)
        VStack(alignment: .leading, spacing: 20) {
            Panel {
                HStack(alignment: .top, spacing: 24) {
                    Metric(label: "Verlust im Ruhezustand", value: rate.map { "\(Fmt.num($0.pctPerHour)) %/h" } ?? "–",
                           sub: rate.map { "über \(Fmt.hours($0.hours)) in 7 Tagen" } ?? "noch keine Daten")
                    Divider().frame(height: 56)
                    Metric(label: "Bewertung", value: rate.map { $0.pctPerHour <= 0.6 ? "Sauber" : ($0.pctPerHour <= 1.5 ? "Okay" : "Zu hoch") } ?? "–",
                           sub: "normal sind unter 0,5 % pro Stunde")
                    Divider().frame(height: 56)
                    Metric(label: "Schlafphasen auf Akku", value: "\(m.log.sleeps.filter { $0.start >= week }.count)", sub: "letzte 7 Tage")
                }
            }

            Panel {
                SectionHeader(title: "Wer hält den Mac gerade wach",
                              note: "Diese Apps verhindern, dass der Mac von selbst einschläft, wenn er offen herumsteht. Zuklappen schickt ihn trotzdem schlafen.")
                if m.blockers.isEmpty {
                    Text("Niemand. Der Mac darf jederzeit schlafen.").foregroundStyle(.secondary)
                }
                ForEach(m.blockers) { b in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: b.preventsDisplaySleep ? "display" : "moon.zzz").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(b.process) \(b.typeText)").fontWeight(.medium)
                            Text(b.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("seit \(b.durationText)").monospacedDigit().foregroundStyle(b.seconds > 3600 ? Color.primary : .secondary)
                    }
                }
            }

            Panel {
                SectionHeader(title: "Schlafphasen auf Akku", note: "Aus dem macOS-Energieprotokoll. Kurze Phasen sind wegen der Rundung auf ganze Prozent ungenau.")
                let sleeps = m.log.sleeps.reversed()
                if sleeps.isEmpty { EmptyHint(text: "Keine Schlafphase auf Akku im Protokoll.") } else { LogPhaseTable(phases: Array(sleeps)) }
            }
        }
    }
}

// MARK: - Akku-Zustand

struct HealthView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        if let r = m.reading {
            VStack(alignment: .leading, spacing: 20) {
                Panel {
                    HStack(alignment: .top, spacing: 24) {
                        Metric(label: "Gesundheit", value: "\(Int(r.healthPct)) %", sub: "aktuelle Kapazität zu Neuzustand")
                        Divider().frame(height: 56)
                        Metric(label: "Ladezyklen", value: "\(r.cycles)", sub: "ausgelegt auf 1000")
                        Divider().frame(height: 56)
                        Metric(label: "Temperatur", value: "\(Fmt.num(r.tempC)) °C", sub: r.tempC > 40 ? "warm" : "normal")
                        Divider().frame(height: 56)
                        Metric(label: "Spannung", value: "\(Fmt.num(r.voltage, 2)) V")
                    }
                }
                Panel {
                    SectionHeader(title: "Kapazität")
                    CapacityBar(design: Double(r.designMAh), max: Double(r.rawMaxMAh), current: Double(r.rawMAh))
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow { Text("Neuzustand").foregroundStyle(.secondary); Text("\(r.designMAh) mAh"); Text("≈ \(Fmt.num(r.designWh, 0)) Wh").foregroundStyle(.secondary) }
                        GridRow { Text("Heute maximal").foregroundStyle(.secondary); Text("\(r.rawMaxMAh) mAh"); Text("≈ \(Fmt.num(r.fullWh, 0)) Wh").foregroundStyle(.secondary) }
                        GridRow { Text("Gerade geladen").foregroundStyle(.secondary); Text("\(r.rawMAh) mAh"); Text("≈ \(Fmt.num(r.remainingWh, 0)) Wh").foregroundStyle(.secondary) }
                    }
                    .monospacedDigit()
                }
                Panel {
                    SectionHeader(title: "Strom")
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow { Text("Netzteil").foregroundStyle(.secondary); Text(r.adapterName.map { "\($0) (\(r.adapterW ?? 0) W)" } ?? "nicht angeschlossen") }
                        GridRow { Text("Akku-Strom").foregroundStyle(.secondary); Text(r.batteryW >= 0 ? "lädt mit \(Fmt.watts(r.batteryW))" : "entlädt mit \(Fmt.watts(-r.batteryW))") }
                        GridRow { Text("Systemleistung").foregroundStyle(.secondary); Text(Fmt.watts(r.systemW)) }
                        GridRow { Text("Stromsparmodus").foregroundStyle(.secondary); Text(ProcessInfo.processInfo.isLowPowerModeEnabled ? "an" : "aus") }
                        GridRow { Text("Externe Bildschirme").foregroundStyle(.secondary); Text("\(m.externalDisplays)") }
                    }
                    .monospacedDigit()
                }
            }
        } else {
            EmptyHint(text: "Kein Akku gefunden.")
        }
    }
}

struct CapacityBar: View {
    let design: Double
    let max: Double
    let current: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.18)).frame(width: g.size.width * max / design)
                RoundedRectangle(cornerRadius: 4).fill(Theme.single).frame(width: g.size.width * current / design)
            }
        }
        .frame(height: 14)
        .help("Blau: aktuell geladen · Dunkelgrau: maximal möglich · Hellgrau: verloren gegenüber Neuzustand")
    }
}

// MARK: - Einstellungen

struct SettingsView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("alertsEnabled") private var alerts = true
    @AppStorage("alertWatts") private var alertWatts = 20.0
    @AppStorage("alertAppWatts") private var alertAppWatts = 4.0
    @AppStorage("alertTabWatts") private var alertTabWatts = 1.5
    @AppStorage("menuMode") private var menuMode = "both"
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Menüleiste zeigt", selection: $menuMode) {
                Text("Prozent").tag("pct")
                Text("Watt").tag("watt")
                Text("Beides").tag("both")
            }
            Toggle("Beim Anmelden starten", isOn: $loginItem)
                .onChange(of: loginItem) { _, on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }
            Toggle("Mitteilungen bei hohem Verbrauch", isOn: $alerts)
            HStack {
                Text("Warnen ab")
                Slider(value: $alertWatts, in: 8...40, step: 1).frame(maxWidth: 240)
                Text("\(Int(alertWatts)) W im Schnitt über 5 Minuten").monospacedDigit().foregroundStyle(.secondary)
            }
            .disabled(!alerts)
            HStack {
                Text("Einzelne App ab")
                Slider(value: $alertAppWatts, in: 1...15, step: 0.5).frame(maxWidth: 240)
                Text("\(Fmt.num(alertAppWatts)) W Prozessor").monospacedDigit().foregroundStyle(.secondary)
            }
            .disabled(!alerts)
            HStack {
                Text("Einzelner Chrome-Tab ab")
                Slider(value: $alertTabWatts, in: 0.5...6, step: 0.5).frame(maxWidth: 240)
                Text("\(Fmt.num(alertTabWatts)) W Prozessor").monospacedDigit().foregroundStyle(.secondary)
            }
            .disabled(!alerts)
            HStack {
                Text("Messdaten")
                Spacer()
                Button("Ordner zeigen") { NSWorkspace.shared.open(m.store.dir) }
            }
            Text("Gemessen wird alle 10 Sekunden, gespeichert wird ein Minutenmittel für 60 Tage. Alles bleibt lokal auf deinem Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
    }
}
