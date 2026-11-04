import SwiftUI

struct MenuLabel: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("menuMode") private var mode = "watt"
    @AppStorage("didShowWindow") private var didShowWindow = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let r = m.reading
        let w = m.recentAverage(seconds: 30) ?? m.live.last?.sysW
        let wattText = w.map { "\(Int($0.rounded())) W" } ?? "…"
        let pctText = r.map { "\($0.pct) %" } ?? ""
        HStack(spacing: 3) {
            Image(systemName: icon(r))
            switch mode {
            case "pct": Text(pctText)
            case "both": Text("\(wattText) · \(pctText)")
            default: Text(wattText)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            openWindow(id: "main")
            NSApp.activate()
        }
        .task {
            if !didShowWindow {
                didShowWindow = true
                try? await Task.sleep(for: .seconds(1))
                openWindow(id: "main")
                NSApp.activate()
            }
        }
    }

    private func icon(_ r: BatteryReading?) -> String {
        guard let r else { return "battery.100percent" }
        if r.ac { return "battery.100percent.bolt" }
        switch r.pct {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if m.live.count > 2 {
                Sparkline(samples: ChartData.buckets(m.live, from: Date().addingTimeInterval(-1800), step: 20))
                    .frame(height: 54)
            }
            if let s = smoothed {
                VStack(alignment: .leading, spacing: 8) {
                    ComponentBar(sample: s)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                        ForEach(Part.allCases) { p in
                            GridRow {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.color(p)).frame(width: 8, height: 8)
                                Text(p.rawValue).foregroundStyle(.secondary)
                                Text(Fmt.watts(p.value(s))).monospacedDigit().gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            Divider()
            topApps
            if !m.blockers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Halten den Mac wach").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(m.blockers.prefix(3))) { b in
                        HStack {
                            Text(b.process).lineLimit(1)
                            Spacer()
                            Text(b.durationText).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.caption)
                        .help("\(b.process) \(b.typeText): \(b.label)")
                    }
                }
            }
            Divider()
            HStack {
                Button("Analyse öffnen") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var smoothed: Sample? {
        let recent = m.live.filter { $0.t > Date().addingTimeInterval(-30) }
        return Sample.average(recent.isEmpty ? Array(m.live.suffix(1)) : recent)
    }

    @ViewBuilder private var header: some View {
        let r = m.reading
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(smoothed.map { Fmt.watts($0.sysW) } ?? "…")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Verbrauch gerade").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let r {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(r.pct) %").font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(stateText(r)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func stateText(_ r: BatteryReading) -> String {
        if r.ac {
            if r.charging, r.batteryW > 0.5 { return "Netzteil, lädt mit \(Fmt.watts(r.batteryW))" }
            if r.batteryW < -1 { return "Netzteil reicht nicht, Akku hilft mit" }
            return "Am Netzteil"
        }
        if let h = m.remainingHours { return "Akku, noch etwa \(Fmt.hours(h))" }
        return "Auf Akku"
    }

    @ViewBuilder private var topApps: some View {
        let apps = Array(m.liveApps.filter { $0.watts >= 0.05 }.prefix(5))
        VStack(alignment: .leading, spacing: 5) {
            Text("Größte Verbraucher (Prozessor)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if apps.isEmpty {
                Text("Messe …").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(apps) { a in
                HStack(spacing: 8) {
                    AppIcon(name: a.name, paths: m.bundlePaths, size: 16)
                    Text(a.name).lineLimit(1)
                    Spacer()
                    Text(Fmt.watts(a.watts)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
