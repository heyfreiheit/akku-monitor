import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var reading: BatteryReading?
    @Published private(set) var live: [Sample] = []          // 10-Sekunden-Werte, letzte 2 Stunden
    @Published private(set) var history: [Sample] = []       // Minutenmittel, bis 60 Tage
    @Published private(set) var liveApps: [AppPower] = []
    @Published private(set) var blockers: [SleepBlocker] = []
    @Published private(set) var log = PowerLogSummary()
    @Published private(set) var appHours: [String: AppHour] = [:]
    @Published private(set) var externalDisplays = 0

    let store = Store()
    private let energyModel = EnergyModelSampler()
    private let processes = ProcessEnergySampler()
    private var minuteBucket: [Sample] = []
    private var appWindow: [(Date, [String: Double])] = []   // App-Watt der letzten 5 Minuten
    private var timer: Timer?
    private var lastAppSave = Date()
    private var lastAssertionCheck = Date.distantPast
    private var lastLogRefresh = Date.distantPast
    private var lastAlert: [String: Date] = [:]
    private var started = false

    var bundlePaths: [String: String] { processes.bundlePaths }

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        history = store.loadSamples()
        for h in store.loadApps() { appHours[key(h.hour, h.app)] = h }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in Monitor.shared.tick() }
        }
        timer?.tolerance = 2
        refreshLog()
        refreshAssertions()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let m = Monitor.shared
                m.energyModel.reset(); m.processes.reset(); m.appWindow = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Task { @MainActor in m.refreshLog(checkSleep: true) } }
            }
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Monitor.shared.flushMinute(); Monitor.shared.saveApps() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Monitor.shared.flushMinute(); Monitor.shared.saveApps() }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: Messen

    func tick() {
        guard let r = Battery.read() else { return }
        reading = r
        let comps = energyModel.sample()
        let apps = processes.sample()
        externalDisplays = Brightness.externalDisplayCount()
        let now = Date()

        if let comps {
            let s = Sample(t: now, pct: r.pct, mAh: r.rawMAh, sysW: max(r.systemW, comps.total), batW: r.batteryW,
                           cpuW: comps.cpu, gpuW: comps.gpu, memW: comps.memory, chipW: comps.otherChip,
                           tempC: r.tempC, ac: r.ac, charging: r.charging,
                           lpm: ProcessInfo.processInfo.isLowPowerModeEnabled, bright: Brightness.builtIn())
            live.append(s)
            let cutoff = now.addingTimeInterval(-7200)
            if let i = live.firstIndex(where: { $0.t >= cutoff }), i > 0 { live.removeFirst(i) }
            if let first = minuteBucket.first, Calendar.current.component(.minute, from: first.t) != Calendar.current.component(.minute, from: now) || now.timeIntervalSince(first.t) > 90 {
                flushMinute()
            }
            minuteBucket.append(s)
        }

        if let (dt, joules) = apps {
            let hour = Calendar.current.dateInterval(of: .hour, for: now)!.start
            for (name, j) in joules {
                let k = key(hour, name)
                var h = appHours[k] ?? AppHour(hour: hour, app: name, batJ: 0, acJ: 0)
                if r.ac { h.acJ += j } else { h.batJ += j }
                appHours[k] = h
            }
            let watts = joules.mapValues { $0 / dt }
            liveApps = watts.filter { $0.value >= 0.01 }.map { AppPower(name: $0.key, watts: $0.value) }.sorted { $0.watts > $1.watts }
            appWindow.append((now, watts))
            appWindow.removeAll { now.timeIntervalSince($0.0) > 300 }
        }

        if now.timeIntervalSince(lastAppSave) > 300 { saveApps() }
        if now.timeIntervalSince(lastAssertionCheck) > 60 { refreshAssertions() }
        if now.timeIntervalSince(lastLogRefresh) > 3600 { refreshLog() }
        checkAlerts(r)
    }

    func flushMinute() {
        guard let avg = Sample.average(minuteBucket) else { return }
        minuteBucket = []
        history.append(avg)
        store.append(avg)
    }

    private func key(_ hour: Date, _ app: String) -> String { "\(Int(hour.timeIntervalSince1970))|\(app)" }

    func saveApps() {
        lastAppSave = Date()
        store.saveApps(Array(appHours.values))
    }

    func refreshAssertions() {
        lastAssertionCheck = Date()
        Task.detached(priority: .utility) {
            let b = Assertions.load()
            await MainActor.run { Monitor.shared.blockers = b }
        }
    }

    func refreshLog(checkSleep: Bool = false) {
        lastLogRefresh = Date()
        Task.detached(priority: .utility) {
            let l = PowerLog.load()
            await MainActor.run {
                Monitor.shared.log = l
                if checkSleep { Monitor.shared.checkSleepDrain() }
            }
        }
    }

    // MARK: Auswertung

    /// Durchschnittliche Systemleistung der letzten n Sekunden (Live-Werte).
    func recentAverage(seconds: Double, batteryOnly: Bool = false) -> Double? {
        let cutoff = Date().addingTimeInterval(-seconds)
        let s = live.filter { $0.t >= cutoff && (!batteryOnly || !$0.ac) }
        guard s.count >= 3 else { return nil }
        return s.reduce(0) { $0 + $1.sysW } / Double(s.count)
    }

    var currentSample: Sample? { live.last }

    /// Leistungsverlauf für Diagramme: gespeicherte Minutenwerte, bei kurzen Zeiträumen
    /// oder frischer Installation die 10-Sekunden-Werte.
    func powerSeries(range: TimeInterval) -> [Sample] {
        let from = Date().addingTimeInterval(-range)
        let longData = ChartData.buckets(history + live.suffix(6), from: from, step: ChartData.step(for: range))
        if range > 3 * 3600, longData.filter({ $0.sysW > 0 }).count >= 6 { return longData }
        // Wenig Daten: Minutenwerte in feinem Raster, bei kurzen Zeiträumen die 10-Sekunden-Werte.
        let minuteData = ChartData.buckets(history + live.suffix(6), from: from, step: 60)
        let liveData = ChartData.buckets(live, from: from, step: 30)
        if range <= 3 * 3600, live.first.map({ $0.t <= from.addingTimeInterval(900) }) == true || liveData.count >= minuteData.count * 2 {
            return liveData
        }
        return minuteData.count >= 3 ? minuteData : liveData
    }

    /// Geschätzte Restlaufzeit bei aktuellem Verbrauch (Mittel der letzten 5 Minuten).
    var remainingHours: Double? {
        guard let r = reading, !r.ac, let w = recentAverage(seconds: 300) ?? live.last?.sysW, w > 0.5 else { return nil }
        return r.remainingWh / w
    }

    func sessions(since: Date = .distantPast) -> [BatterySession] {
        var out: [BatterySession] = []
        var cur: BatterySession?
        var prev: Sample?
        let maxMAh = Double(reading?.rawMaxMAh ?? 7800)
        for s in history where s.t >= since {
            if s.ac {
                if let c = cur { out.append(c) }
                cur = nil
            } else {
                if cur == nil { cur = BatterySession(start: s.t, end: s.t, startPct: s.pct, endPct: s.pct) }
                if let p = prev, !p.ac, cur!.start <= p.t {
                    let dt = s.t.timeIntervalSince(p.t)
                    if dt <= 150 {
                        cur!.awakeSeconds += dt
                        cur!.energyJ += s.sysW * dt
                        cur!.awakeDropPct += Double(p.mAh - s.mAh) / maxMAh * 100
                    }
                }
                cur!.end = s.t
                cur!.endPct = s.pct
                cur!.peakW = max(cur!.peakW, s.sysW)
            }
            prev = s
        }
        if let c = cur { out.append(c) }
        return out.filter { $0.awakeSeconds >= 5 * 60 }.reversed()
    }

    /// Mittlere Leistung im Akkubetrieb (wach) in einem Zeitraum, aus eigenen Messungen.
    func batteryAverage(since: Date) -> (watts: Double, hours: Double)? {
        let ss = sessions(since: since)
        let secs = ss.reduce(0) { $0 + $1.awakeSeconds }
        guard secs >= 20 * 60 else { return nil }
        return (ss.reduce(0) { $0 + $1.energyJ } / secs, secs / 3600)
    }

    /// Akku-Verbrauch wach aus dem macOS-Protokoll (Prozent pro Stunde).
    func logAwakeRate(since: Date) -> (pctPerHour: Double, hours: Double)? {
        let a = log.awake.filter { $0.start >= since }
        let h = a.reduce(0) { $0 + $1.hours }
        guard h >= 0.5 else { return nil }
        return (Double(a.reduce(0) { $0 + $1.drop }) / h, h)
    }

    func logSleepRate(since: Date) -> (pctPerHour: Double, hours: Double)? {
        let a = log.sleeps.filter { $0.start >= since }
        let h = a.reduce(0) { $0 + $1.hours }
        guard h >= 1 else { return nil }
        return (Double(a.reduce(0) { $0 + $1.drop }) / h, h)
    }

    func appTotals(since: Date, batteryOnly: Bool) -> [AppTotal] {
        var sums: [String: Double] = [:]
        for h in appHours.values where h.hour >= since {
            let j = batteryOnly ? h.batJ : h.batJ + h.acJ
            if j > 0 { sums[h.app, default: 0] += j }
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return sums.map { AppTotal(name: $0.key, wh: $0.value / 3600, share: $0.value / total) }.sorted { $0.wh > $1.wh }
    }

    /// Mittel je App über die letzten 5 Minuten.
    func appAverages() -> [AppPower] {
        guard appWindow.count >= 3 else { return [] }
        var sums: [String: Double] = [:]
        for (_, w) in appWindow { for (k, v) in w { sums[k, default: 0] += v } }
        return sums.map { AppPower(name: $0.key, watts: $0.value / Double(appWindow.count)) }.sorted { $0.watts > $1.watts }
    }

    // MARK: Warnungen

    private func checkAlerts(_ r: BatteryReading) {
        let d = UserDefaults.standard
        guard d.object(forKey: "alertsEnabled") as? Bool ?? true, !r.ac else { return }
        let threshold = d.object(forKey: "alertWatts") as? Double ?? 20
        let appThreshold = d.object(forKey: "alertAppWatts") as? Double ?? 4

        if let w = recentAverage(seconds: 300, batteryOnly: true), live.filter({ !$0.ac && $0.t > Date().addingTimeInterval(-300) }).count >= 25, w > threshold {
            let top = appAverages().first
            var body = "Dein Mac zieht seit 5 Minuten im Schnitt \(Fmt.watts(w)) aus dem Akku."
            if let h = remainingHours { body += " So ist er in etwa \(Fmt.hours(h)) leer." }
            if let top, top.watts > 1 { body += " Größter Verbraucher: \(top.name) mit \(Fmt.watts(top.watts)) Prozessorlast." }
            notify(id: "highDraw", every: 45 * 60, title: "Hoher Verbrauch: \(Fmt.watts(w))", body: body)
        }
        if appWindow.count >= 25 {
            for a in appAverages().prefix(3) where a.watts > appThreshold && a.name != "Akku Monitor" {
                notify(id: "app-\(a.name)", every: 2 * 3600, title: "\(a.name) frisst Akku",
                       body: "\(a.name) zieht seit 5 Minuten rund \(Fmt.watts(a.watts)) nur für den Prozessor. Wenn du die App gerade nicht brauchst, beende sie.")
            }
        }
        if r.pct <= 15, let h = remainingHours {
            notify(id: "low", every: 3 * 3600, title: "Noch \(r.pct) %", body: "Bei aktuellem Verbrauch reicht das noch etwa \(Fmt.hours(h)).")
        }
    }

    private func checkSleepDrain() {
        guard UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true,
              let last = log.sleeps.last, last.end > Date().addingTimeInterval(-600), last.hours >= 1 else { return }
        if last.pctPerHour > 1.5 {
            notify(id: "sleep", every: 3600, title: "Akku im Ruhezustand verloren",
                   body: "Im Ruhezustand sind \(last.drop) % in \(Fmt.hours(last.hours)) weg. Das ist mehr als normal. Schau im Akku Monitor unter Ruhezustand nach, wer den Mac wachhält.")
        }
    }

    private func notify(id: String, every: TimeInterval, title: String, body: String) {
        if let t = lastAlert[id], Date().timeIntervalSince(t) < every { return }
        lastAlert[id] = Date()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id + UUID().uuidString, content: c, trigger: nil))
    }
}
