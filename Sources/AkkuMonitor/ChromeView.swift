import Charts
import SwiftUI

struct ChromeView: View {
    @EnvironmentObject var m: Monitor
    @State private var range: Double = 86400
    @State private var batteryOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if m.chromeConnected {
                connectedHeader
                tabsPanel
                sitesPanel
            } else {
                ChromeSetup()
            }
        }
    }

    // MARK: Kopf

    @ViewBuilder private var connectedHeader: some View {
        let b = m.chromeBreakdownAverage() ?? ChromeBreakdown()
        let tabs = m.chromeTabList
        let sleeping = tabs.filter(\.discarded).count
        Panel {
            HStack(alignment: .top, spacing: 24) {
                Metric(label: "Chrome gesamt", value: Fmt.watts(b.total), sub: "Prozessor, Mittel 5 min")
                Divider().frame(height: 56)
                Metric(label: "Davon Tabs", value: Fmt.watts(b.tabs), sub: "\(m.chromeTabs.mappedCount) von \(tabs.count - sleeping) Tabs zugeordnet")
                Divider().frame(height: 56)
                Metric(label: "Grafikprozess", value: Fmt.watts(b.gpu), sub: "Video, Scrollen, Animationen")
                Divider().frame(height: 56)
                Metric(label: "Browser & Rest", value: Fmt.watts(b.browser + b.unassigned), sub: "Erweiterungen, Werbung in Frames, Netzwerk")
            }
            ChromeShareBar(b: b)
            Text("Gezählt wird die Rechenarbeit der Tabs. Video-Dekodierung und das Zeichnen auf den Bildschirm laufen in Chromes gemeinsamem Grafikprozess und lassen sich keinem Tab zuordnen. \(sleeping > 0 ? "\(sleeping) Tabs schlafen gerade und verbrauchen nichts." : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Tabs

    @ViewBuilder private var tabsPanel: some View {
        let all = m.tabAverages()
        let list = all.filter { $0.watts >= 0.05 }
        let idle = all.count - list.count
        Panel {
            SectionHeader(title: "Tabs nach Verbrauch", note: "Mittel der letzten 5 Minuten. Alles ab 1 W ist auf Akku spürbar.")
            if list.isEmpty && idle > 0 {
                Text("Alle \(idle) wachen Tabs sind gerade fast im Leerlauf (unter 0,05 W). Spannend wird es, wenn Videos, Meetings oder Web-Apps laufen.")
                    .foregroundStyle(.secondary)
            } else if list.isEmpty {
                EmptyHint(text: "Die Tabs werden gerade zugeordnet. Nach etwa einer Minute stehen hier die ersten Werte.")
            } else {
                let maxW = max(list.first?.watts ?? 1, 0.5)
                VStack(spacing: 0) {
                    ForEach(Array(list.prefix(25))) { t in
                        TabRow(t: t, maxW: maxW)
                        Divider().opacity(0.5)
                    }
                }
                if idle > 0 {
                    Text("Dazu \(idle) \(idle == 1 ? "Tab" : "Tabs") fast im Leerlauf (unter 0,05 W).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Websites

    @ViewBuilder private var sitesPanel: some View {
        let totals = m.siteTotals(since: Date().addingTimeInterval(-range), batteryOnly: batteryOnly)
        let top = Array(totals.prefix(12))
        Panel {
            HStack {
                SectionHeader(title: "Websites nach Energie", note: "Alle Tabs einer Website zusammengezählt")
                Picker("Zeitraum", selection: $range) {
                    Text("24 Std").tag(86400.0)
                    Text("7 Tage").tag(7.0 * 86400)
                    Text("30 Tage").tag(30.0 * 86400)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Toggle("Nur Akku", isOn: $batteryOnly).toggleStyle(.checkbox)
            }
            if top.isEmpty {
                EmptyHint(text: "Noch keine Messwerte für diesen Zeitraum.")
            } else {
                Chart(top) { a in
                    BarMark(x: .value("Wh", a.wh), y: .value("Website", a.name), width: .fixed(14))
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
                .chartXScale(range: .plotDimension(endPadding: 100))
                .frame(height: CGFloat(top.count) * 28 + 30)
            }
        }
    }
}

struct TabRow: View {
    let t: TabPower
    let maxW: Double
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.tab.title.isEmpty ? t.tab.host : t.tab.title).lineLimit(1)
                HStack(spacing: 8) {
                    Text(t.tab.host)
                    if t.tab.audible { Label("spielt Ton", systemImage: "speaker.wave.2.fill") }
                    if t.tab.active { Label("sichtbar", systemImage: "eye") }
                    if t.sharedWith > 1 { Text("teilt Prozess mit \(t.sharedWith - 1) \(t.sharedWith == 2 ? "Tab" : "Tabs")") }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 12)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3).fill(Theme.single).frame(width: max(2, g.size.width * min(1, t.watts / maxW)))
                }
            }
            .frame(width: 120, height: 8)
            Text(Fmt.watts(t.watts)).monospacedDigit().frame(width: 56, alignment: .trailing)
                .foregroundStyle(t.watts >= 1 ? Color.primary : .secondary)
                .fontWeight(t.watts >= 1 ? .semibold : .regular)
        }
        .padding(.vertical, 7)
    }
}

/// Anteil von Tabs, Grafikprozess und Rest an Chromes Verbrauch. Eigene Grautöne,
/// damit die Farben der Bereichs-Diagramme (Prozessor, Grafik …) nicht doppelt belegt werden.
struct ChromeShareBar: View {
    let b: ChromeBreakdown
    var body: some View {
        let items: [(String, Double, Color)] = [
            ("Tabs", b.tabs, Theme.single),
            ("Grafikprozess", b.gpu, Color.primary.opacity(0.45)),
            ("Browser & Rest", b.browser + b.unassigned, Color.primary.opacity(0.2)),
        ]
        let total = max(b.total, 0.01)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(items, id: \.0) { i in
                        RoundedRectangle(cornerRadius: 3).fill(i.2)
                            .frame(width: max(0, (g.size.width - 4) * i.1 / total))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 16) {
                ForEach(items, id: \.0) { i in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(i.2).frame(width: 10, height: 10)
                        Text(i.0).foregroundStyle(.secondary)
                        Text("\(Int((i.1 / total * 100).rounded())) %").monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Einrichtung

struct ChromeSetup: View {
    @State private var copied = false

    var body: some View {
        Panel {
            SectionHeader(title: "Chrome verbinden",
                          note: "Damit die App sieht, welcher Tab wie viel Strom zieht, braucht Chrome eine kleine Erweiterung. Sie läuft nur lokal und schickt nichts ins Internet.")
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Öffne in Chrome die Adresse chrome://extensions") {
                    Button(copied ? "Kopiert" : "Adresse kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("chrome://extensions", forType: .string)
                        copied = true
                    }
                }
                step(2, "Schalte oben rechts den Entwicklermodus ein (englisch: Developer mode)") { EmptyView() }
                step(3, "Klick auf „Entpackte Erweiterung laden“ (Load unpacked) und wähl den Ordner „Chrome-Erweiterung“") {
                    Button("Ordner im Finder zeigen") {
                        ChromeExtension.install()
                        NSWorkspace.shared.activateFileViewerSelecting([ChromeExtension.installDir])
                    }
                }
                step(4, "Fertig. Nach ein paar Sekunden erscheinen hier deine Tabs.") { EmptyView() }
            }
            Text("Was die Erweiterung macht: Sie meldet der App Titel und Adresse deiner Tabs. Jeder Tab rechnet beim Laden einmal 0,15 Sekunden lang, daran erkennt die App, welcher Chrome-Prozess zu ihm gehört. Inhalte von Seiten liest sie nicht.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func step<V: View>(_ n: Int, _ text: String, @ViewBuilder action: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                .frame(width: 22, height: 22).background(Color.primary.opacity(0.08), in: Circle())
            Text(text)
            Spacer()
            action()
        }
    }
}
