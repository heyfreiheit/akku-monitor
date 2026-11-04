import Foundation

/// Ein Messpunkt. Live alle 10 Sekunden, gespeichert als Minutenmittel.
struct Sample: Codable, Identifiable {
    var id: Date { t }
    var t: Date
    var pct: Int
    var mAh: Int
    var sysW: Double
    var batW: Double     // + lädt, - entlädt
    var cpuW: Double
    var gpuW: Double
    var memW: Double
    var chipW: Double
    var tempC: Double
    var ac: Bool
    var charging: Bool
    var lpm: Bool
    var bright: Double?

    /// Bildschirm-Hintergrundbeleuchtung, WLAN, SSD, Lautsprecher, USB-Geräte, Spannungswandler.
    var restW: Double { max(0, sysW - cpuW - gpuW - memW - chipW) }

    static func average(_ s: [Sample]) -> Sample? {
        guard let last = s.last else { return nil }
        let n = Double(s.count)
        func avg(_ k: KeyPath<Sample, Double>) -> Double { s.reduce(0) { $0 + $1[keyPath: k] } / n }
        let brights = s.compactMap(\.bright)
        return Sample(t: s[s.count / 2].t, pct: last.pct, mAh: last.mAh, sysW: avg(\.sysW), batW: avg(\.batW),
                      cpuW: avg(\.cpuW), gpuW: avg(\.gpuW), memW: avg(\.memW), chipW: avg(\.chipW),
                      tempC: avg(\.tempC), ac: s.filter(\.ac).count * 2 >= s.count, charging: last.charging,
                      lpm: last.lpm, bright: brights.isEmpty ? nil : brights.reduce(0, +) / Double(brights.count))
    }
}

/// Energie einer App in einer Stunde, getrennt nach Akku und Netzteil.
struct AppHour: Codable {
    var hour: Date
    var app: String
    var batJ: Double
    var acJ: Double
}

struct AppPower: Identifiable {
    var id: String { name }
    let name: String
    let watts: Double
}

struct AppTotal: Identifiable {
    var id: String { name }
    let name: String
    let wh: Double
    let share: Double
}

/// Akku-Sitzung aus den eigenen Messungen: vom Abstecken bis zum Einstecken.
struct BatterySession: Identifiable {
    var id: Date { start }
    var start: Date
    var end: Date
    var startPct: Int
    var endPct: Int
    var awakeSeconds: Double = 0
    var awakeDropPct: Double = 0
    var energyJ: Double = 0
    var peakW: Double = 0

    var awakeHours: Double { awakeSeconds / 3600 }
    var avgW: Double { awakeSeconds > 0 ? energyJ / awakeSeconds : 0 }
    var pctPerHour: Double { awakeHours > 0 ? awakeDropPct / awakeHours : 0 }
}

enum Part: String, CaseIterable, Identifiable {
    case cpu = "Prozessor"
    case gpu = "Grafik"
    case memory = "Speicher"
    case chip = "Medien & Display-Chip"
    case rest = "Bildschirm & Peripherie"
    var id: String { rawValue }

    func value(_ s: Sample) -> Double {
        switch self {
        case .cpu: s.cpuW
        case .gpu: s.gpuW
        case .memory: s.memW
        case .chip: s.chipW
        case .rest: s.restW
        }
    }

    var explanation: String {
        switch self {
        case .cpu: "Rechenarbeit aller Apps und Dienste"
        case .gpu: "Animationen, Video, Browser-Rendering, 3D"
        case .memory: "Arbeitsspeicher und Datenwege im Chip"
        case .chip: "Video-Engine, Kamera-Prozessor, Display-Controller, KI-Einheit, Thunderbolt"
        case .rest: "Hintergrundbeleuchtung, WLAN, SSD, Lautsprecher, angeschlossene Geräte"
        }
    }
}

// MARK: - Speicher

final class Store {
    let dir: URL
    private var samplesURL: URL { dir.appendingPathComponent("samples.jsonl") }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
    static let keepDays: Double = 60

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AkkuMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func loadSamples() -> [Sample] {
        guard let data = try? Data(contentsOf: samplesURL) else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.keepDays * 86400)
        var out: [Sample] = []
        var trimmed = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let s = try? decoder.decode(Sample.self, from: Data(line)) else { continue }
            if s.t < cutoff { trimmed = true; continue }
            out.append(s)
        }
        if trimmed { rewrite(out) }
        return out
    }

    func append(_ s: Sample) {
        guard var line = try? encoder.encode(s) else { return }
        line.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: samplesURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: samplesURL)
        }
    }

    private func rewrite(_ s: [Sample]) {
        var data = Data()
        for x in s { if let l = try? encoder.encode(x) { data.append(l); data.append(UInt8(ascii: "\n")) } }
        try? data.write(to: samplesURL, options: .atomic)
    }

    func loadApps(_ file: String = "apps.json") -> [AppHour] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
              let a = try? decoder.decode([AppHour].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.keepDays * 86400)
        return a.filter { $0.hour >= cutoff }
    }

    func saveApps(_ a: [AppHour], _ file: String = "apps.json") {
        if let data = try? encoder.encode(a) { try? data.write(to: dir.appendingPathComponent(file), options: .atomic) }
    }
}

// MARK: - Formatierung

enum Fmt {
    static func watts(_ w: Double) -> String {
        w < 10 ? String(format: "%.1f W", w).replacingOccurrences(of: ".", with: ",") : String(format: "%.0f W", w)
    }

    static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        if h >= 48 { return "\(h / 24) Tage" }
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static func hours(_ h: Double) -> String {
        guard h.isFinite, h > 0 else { return "–" }
        return duration(h * 3600)
    }

    static func wh(_ v: Double) -> String {
        if v == 0 { return "0 Wh" }
        if v < 0.001 { return "< 1 mWh" }
        if v < 0.1 { return "\(num(v * 1000, 0)) mWh" }
        return "\(num(v, v < 10 ? 1 : 0)) Wh"
    }

    static func num(_ v: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "HH:mm"; return f }()
    static let dayTime: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EE dd.MM., HH:mm"; return f }()
}
