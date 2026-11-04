import AppKit
import Charts
import SwiftUI

// MARK: - Farben (validierte Kategorie-Palette, Hell- und Dunkelmodus getrennt gewählt)

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { ap in
            NSColor(hex: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

enum Theme {
    static func color(_ p: Part) -> Color {
        switch p {
        case .cpu: Color(light: 0x2a78d6, dark: 0x3987e5)
        case .gpu: Color(light: 0xeb6834, dark: 0xd95926)
        case .memory: Color(light: 0x1baf7a, dark: 0x199e70)
        case .chip: Color(light: 0xeda100, dark: 0xc98500)
        case .rest: Color(light: 0xe87ba4, dark: 0xd55181)
        }
    }
    static let single = Color(light: 0x2a78d6, dark: 0x3987e5)
    static let good = Color(nsColor: NSColor(hex: 0x0ca30c))
    static let warning = Color(nsColor: NSColor(hex: 0xfab219))
    static let serious = Color(nsColor: NSColor(hex: 0xec835a))
    static let critical = Color(nsColor: NSColor(hex: 0xd03b3b))

    static func status(_ l: Finding.Level) -> (Color, String) {
        switch l {
        case .good: (good, "checkmark.circle.fill")
        case .info: (Color.secondary, "info.circle.fill")
        case .warning: (warning, "exclamationmark.triangle.fill")
        case .serious: (critical, "exclamationmark.octagon.fill")
        }
    }
}

// MARK: - Datenaufbereitung für Diagramme

enum ChartData {
    /// Mittelt Messwerte in Zeitfenster und setzt bei Lücken (Ruhezustand) Nullpunkte,
    /// damit das Diagramm dort sichtbar abfällt statt die Lücke zu überbrücken.
    static func buckets(_ s: [Sample], from: Date, step: TimeInterval) -> [Sample] {
        let filtered = s.filter { $0.t >= from }
        guard !filtered.isEmpty else { return [] }
        var groups: [Int: [Sample]] = [:]
        for x in filtered { groups[Int(x.t.timeIntervalSince1970 / step), default: []].append(x) }
        let avgs = groups.keys.sorted().compactMap { k -> Sample? in
            guard var a = Sample.average(groups[k]!) else { return nil }
            a.t = Date(timeIntervalSince1970: (Double(k) + 0.5) * step)
            return a
        }
        var out: [Sample] = []
        for (i, a) in avgs.enumerated() {
            if i > 0, a.t.timeIntervalSince(avgs[i - 1].t) > step * 2.5 {
                out.append(zero(avgs[i - 1], at: avgs[i - 1].t.addingTimeInterval(step)))
                out.append(zero(a, at: a.t.addingTimeInterval(-step)))
            }
            out.append(a)
        }
        return out
    }

    private static func zero(_ s: Sample, at t: Date) -> Sample {
        var z = s
        z.t = t; z.sysW = 0; z.cpuW = 0; z.gpuW = 0; z.memW = 0; z.chipW = 0
        return z
    }

    static func step(for range: TimeInterval) -> TimeInterval {
        switch range {
        case ..<(3 * 3600): 60
        case ..<(7 * 3600): 120
        case ..<(25 * 3600): 300
        case ..<(8 * 86400): 1800
        default: 7200
        }
    }
}

// MARK: - Leistungsdiagramm (gestapelte Fläche, Hover mit Werten)

struct PowerChart: View {
    let samples: [Sample]
    var height: CGFloat = 220
    @State private var selected: Date?

    private var nearest: Sample? {
        guard let selected else { return nil }
        return samples.filter { $0.sysW > 0 }.min { abs($0.t.timeIntervalSince(selected)) < abs($1.t.timeIntervalSince(selected)) }
    }

    var body: some View {
        Chart {
            ForEach(samples) { s in
                ForEach(Part.allCases) { p in
                    AreaMark(x: .value("Zeit", s.t), y: .value("Watt", p.value(s)), stacking: .standard)
                        .foregroundStyle(by: .value("Bereich", p.rawValue))
                        .interpolationMethod(.monotone)
                }
            }
            if let n = nearest {
                RuleMark(x: .value("Zeit", n.t))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        PowerTooltip(sample: n)
                    }
            }
        }
        .chartForegroundStyleScale(domain: Part.allCases.map(\.rawValue), range: Part.allCases.map(Theme.color))
        .chartLegend(.hidden)
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) W") } }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel()
            }
        }
        .frame(height: height)
    }
}

struct PowerTooltip: View {
    let sample: Sample
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Fmt.dayTime.string(from: sample.t)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(Fmt.watts(sample.sysW)).fontWeight(.semibold)
            }
            ForEach(Part.allCases.reversed()) { p in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.color(p)).frame(width: 8, height: 8)
                    Text(p.rawValue).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(Fmt.watts(p.value(sample))).monospacedDigit()
                }
            }
            HStack {
                Text(sample.ac ? "Netzteil" : "Akku").foregroundStyle(.secondary)
                Spacer()
                Text("\(sample.pct) %").monospacedDigit()
            }
        }
        .font(.caption)
        .padding(10)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct PartLegend: View {
    var sample: Sample?
    var body: some View {
        HStack(spacing: 16) {
            ForEach(Part.allCases) { p in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.color(p)).frame(width: 10, height: 10)
                    Text(p.rawValue).foregroundStyle(.secondary)
                    if let s = sample { Text(Fmt.watts(p.value(s))).monospacedDigit() }
                }
                .help(p.explanation)
            }
        }
        .font(.caption)
    }
}

// MARK: - Ladestand

struct ChargePoint: Identifiable {
    var id: Date { t }
    let t: Date
    let pct: Int
    let ac: Bool
}

struct ChargeChart: View {
    let points: [ChargePoint]
    var height: CGFloat = 160
    @State private var selected: Date?

    private var acBands: [(Date, Date)] {
        var out: [(Date, Date)] = []
        var start: Date?
        for (i, p) in points.enumerated() {
            if p.ac, start == nil { start = p.t }
            if let s = start, !p.ac || i == points.count - 1 { out.append((s, p.t)); start = nil }
        }
        return out
    }

    private var nearest: ChargePoint? {
        guard let selected else { return nil }
        return points.min { abs($0.t.timeIntervalSince(selected)) < abs($1.t.timeIntervalSince(selected)) }
    }

    var body: some View {
        Chart {
            ForEach(Array(acBands.enumerated()), id: \.offset) { _, b in
                RectangleMark(xStart: .value("Start", b.0), xEnd: .value("Ende", b.1), yStart: .value("", 0), yEnd: .value("", 100))
                    .foregroundStyle(Color.primary.opacity(0.07))
            }
            ForEach(points) { p in
                LineMark(x: .value("Zeit", p.t), y: .value("Ladestand", p.pct))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let n = nearest {
                PointMark(x: .value("Zeit", n.t), y: .value("Ladestand", n.pct))
                    .symbolSize(60)
                    .foregroundStyle(Color.primary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("\(Fmt.dayTime.string(from: n.t)) · \(n.pct) % · \(n.ac ? "Netzteil" : "Akku")")
                            .font(.caption).padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let d = v.as(Int.self) { Text("\(d) %") } }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Bausteine

struct ComponentBar: View {
    let sample: Sample
    var body: some View {
        GeometryReader { g in
            let total = max(sample.sysW, 0.01)
            let gap: CGFloat = 2
            let usable = g.size.width - gap * CGFloat(Part.allCases.count - 1)
            HStack(spacing: gap) {
                ForEach(Part.allCases) { p in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.color(p))
                        .frame(width: max(0, usable * CGFloat(p.value(sample) / total)))
                        .help("\(p.rawValue): \(Fmt.watts(p.value(sample)))")
                }
            }
        }
        .frame(height: 10)
    }
}

struct Sparkline: View {
    let samples: [Sample]
    var body: some View {
        Chart(samples) { s in
            AreaMark(x: .value("Zeit", s.t), y: .value("Watt", s.sysW))
                .foregroundStyle(Color.primary.opacity(0.08))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Zeit", s.t), y: .value("Watt", s.sysW))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) W").font(.system(size: 9)) } }
            }
        }
    }
}

struct Metric: View {
    let label: String
    let value: String
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            if let sub { Text(sub).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeader: View {
    let title: String
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct AppIcon: View {
    let name: String
    let paths: [String: String]
    var size: CGFloat = 18
    var body: some View {
        if let p = paths[name] {
            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape").font(.system(size: size * 0.7)).foregroundStyle(.tertiary).frame(width: size, height: size)
        }
    }
}

struct FindingRow: View {
    let f: Finding
    var body: some View {
        let (c, icon) = Theme.status(f.level)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(c).font(.system(size: 15)).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).fontWeight(.semibold)
                Text(f.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
