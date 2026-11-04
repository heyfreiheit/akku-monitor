import Foundation

// MARK: - macOS-Energieprotokoll (pmset -g log)

struct PowerLogEvent {
    enum Kind { case sleep, wake, darkWake }
    let date: Date
    let kind: Kind
    let onBattery: Bool
    let pct: Int
    let reason: String
}

/// Eine Phase auf Akku, entweder wach oder im Ruhezustand, rekonstruiert aus dem Protokoll.
struct LogPhase: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let startPct: Int
    let endPct: Int
    let reason: String
    var hours: Double { end.timeIntervalSince(start) / 3600 }
    var drop: Int { startPct - endPct }
    var pctPerHour: Double { hours > 0 ? Double(drop) / hours : 0 }
}

struct PowerLogSummary {
    var charge: [(date: Date, pct: Int, onBattery: Bool)] = []
    var awake: [LogPhase] = []
    var sleeps: [LogPhase] = []
}

enum PowerLog {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}) (Sleep|Wake|DarkWake)\s+(.*)Using (BATT|Batt|AC) \(Charge: ?(\d+)%\)"#)
    private static let reasonRegex = try! NSRegularExpression(pattern: #"due to '?([^':]+)"#)

    static func load() -> PowerLogSummary {
        let text = Shell.run("/usr/bin/pmset", ["-g", "log"])
        var events: [PowerLogEvent] = []
        text.enumerateLines { line, _ in
            guard line.contains("Charge:") else { return }
            let ns = line as NSString
            guard let m = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let date = formatter.date(from: ns.substring(with: m.range(at: 1))),
                  let pct = Int(ns.substring(with: m.range(at: 5))) else { return }
            let kindStr = ns.substring(with: m.range(at: 2))
            let rest = ns.substring(with: m.range(at: 3))
            var reason = ""
            let rns = rest as NSString
            if let r = reasonRegex.firstMatch(in: rest, range: NSRange(location: 0, length: rns.length)) {
                reason = rns.substring(with: r.range(at: 1)).trimmingCharacters(in: .whitespaces)
            }
            let kind: PowerLogEvent.Kind = kindStr == "Sleep" ? .sleep : (kindStr == "Wake" ? .wake : .darkWake)
            events.append(PowerLogEvent(date: date, kind: kind, onBattery: ns.substring(with: m.range(at: 4)) != "AC", pct: pct, reason: reason))
        }
        return summarize(events.sorted { $0.date < $1.date })
    }

    static func summarize(_ events: [PowerLogEvent]) -> PowerLogSummary {
        var s = PowerLogSummary()
        s.charge = events.map { ($0.date, $0.pct, $0.onBattery) }
        var awakeStart: PowerLogEvent?
        var sleepStart: PowerLogEvent?
        var sleepBroken = false
        for e in events {
            switch e.kind {
            case .wake:
                if let st = sleepStart, st.onBattery, e.onBattery, !sleepBroken, e.pct <= st.pct {
                    s.sleeps.append(LogPhase(start: st.date, end: e.date, startPct: st.pct, endPct: e.pct, reason: st.reason))
                }
                sleepStart = nil
                awakeStart = e
            case .darkWake:
                if !e.onBattery { sleepBroken = true }
            case .sleep:
                if let a = awakeStart, a.onBattery, e.onBattery, e.pct <= a.pct, e.date.timeIntervalSince(a.date) >= 15 * 60 {
                    s.awake.append(LogPhase(start: a.date, end: e.date, startPct: a.pct, endPct: e.pct, reason: a.reason))
                }
                awakeStart = nil
                if sleepStart == nil {
                    // Beginn einer Schlafphase. Wartungs-Schlaf nach DarkWake gehört zur laufenden Phase.
                    sleepStart = e
                    sleepBroken = !e.onBattery
                } else if !e.onBattery {
                    sleepBroken = true
                }
            }
        }
        s.sleeps = s.sleeps.filter { $0.hours >= 0.5 }
        return s
    }
}

// MARK: - Wer hält den Mac wach (pmset -g assertions)

struct SleepBlocker: Identifiable, Hashable {
    var id: String { "\(pid)-\(type)-\(label)" }
    let pid: Int
    let process: String
    let type: String
    let label: String
    let seconds: Int

    var preventsDisplaySleep: Bool { type.contains("Display") }
    var typeText: String { preventsDisplaySleep ? "hält den Bildschirm an" : "verhindert den Ruhezustand" }
    var durationText: String { Fmt.duration(Double(seconds)) }
}

enum Assertions {
    private static let regex = try! NSRegularExpression(
        pattern: #"pid (\d+)\((.+?)\): \[[^\]]+\] (\d+):(\d\d):(\d\d) (\w+) named: "(.*)""#)
    private static let relevant: Set<String> = [
        "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep",
        "NoDisplaySleepAssertion", "PreventUserIdleDisplaySleep",
    ]
    private static let ignoredProcesses: Set<String> = ["powerd", "WindowServer", "coreaudiod", "sharingd", "bluetoothd", "hidd", "runningboardd", "useractivityd"]

    static func load() -> [SleepBlocker] {
        let text = Shell.run("/usr/bin/pmset", ["-g", "assertions"])
        var out: [SleepBlocker] = []
        text.enumerateLines { line, _ in
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return }
            let type = ns.substring(with: m.range(at: 6))
            let proc = ns.substring(with: m.range(at: 2))
            guard relevant.contains(type), !ignoredProcesses.contains(proc) else { return }
            let secs = (Int(ns.substring(with: m.range(at: 3))) ?? 0) * 3600
                + (Int(ns.substring(with: m.range(at: 4))) ?? 0) * 60
                + (Int(ns.substring(with: m.range(at: 5))) ?? 0)
            out.append(SleepBlocker(pid: Int(ns.substring(with: m.range(at: 1))) ?? 0, process: proc, type: type,
                                    label: ns.substring(with: m.range(at: 7)), seconds: secs))
        }
        return out.sorted { $0.seconds > $1.seconds }
    }
}
