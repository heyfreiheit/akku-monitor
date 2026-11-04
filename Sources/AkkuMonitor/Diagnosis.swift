import Foundation

struct Finding: Identifiable {
    enum Level: Int { case good = 0, info = 1, warning = 2, serious = 3 }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String
}

/// Übersetzt die Messwerte in klare Aussagen. Die Verbrauchs-Schwellen hängen an der Akkugröße:
/// Bei leichter Arbeit verliert ein Apple-Silicon-MacBook etwa 5 bis 9 % pro Stunde
/// (16" MacBook Pro mit 100 Wh: 5 bis 9 W, MacBook Air mit 53 Wh: rund 3 bis 5 W).
@MainActor
enum Diagnosis {
    static func findings(_ m: Monitor) -> [Finding] {
        var out: [Finding] = []
        let week = Date().addingTimeInterval(-7 * 86400)
        let fullWh = m.reading?.fullWh ?? 90
        // Bezug ist die Neu-Kapazität, damit ein gealterter Akku die Schwellen nicht verschiebt.
        let designWh = (m.reading?.designWh).flatMap { $0 > 10 ? $0 : nil } ?? fullWh
        let normalLow = designWh * 0.05, normalHigh = designWh * 0.09, high = designWh * 0.15
        let normalText = "Bei leichter Arbeit sind auf deinem Mac etwa \(Fmt.num(normalLow, 0)) bis \(Fmt.num(normalHigh, 0)) W normal"

        // 1. Verbrauch im Akkubetrieb
        if let avg = m.batteryAverage(since: week) {
            let runtime = fullWh / avg.watts
            let base = "Im Akkubetrieb ziehst du im Schnitt \(Fmt.watts(avg.watts)) (gemessen über \(Fmt.hours(avg.hours))). Mit voller Ladung wären das rund \(Fmt.hours(runtime)) Laufzeit."
            if avg.watts > high {
                out.append(Finding(level: .serious, title: "Dein Verbrauch ist hoch", detail: base + " \(normalText), also \(Fmt.hours(fullWh / normalHigh)) bis \(Fmt.hours(fullWh / normalLow))."))
            } else if avg.watts > normalHigh {
                out.append(Finding(level: .warning, title: "Dein Verbrauch ist leicht erhöht", detail: base + " \(normalText)."))
            } else {
                out.append(Finding(level: .good, title: "Dein Verbrauch ist normal", detail: base))
            }
        } else if let rate = m.logAwakeRate(since: week) {
            let w = rate.pctPerHour / 100 * fullWh
            let runtime = rate.pctPerHour > 0 ? 100 / rate.pctPerHour : 0
            let level: Finding.Level = rate.pctPerHour > 15 ? .serious : (rate.pctPerHour > 9 ? .warning : .good)
            out.append(Finding(level: level, title: "Verbrauch laut macOS-Protokoll: \(Fmt.num(rate.pctPerHour, 0)) % pro Stunde",
                               detail: "In den letzten 7 Tagen hat dein Mac im wachen Akkubetrieb im Schnitt \(Fmt.num(rate.pctPerHour, 1)) % pro Stunde verloren, das sind rund \(Fmt.watts(w)) und \(Fmt.hours(runtime)) mit voller Ladung. Ab jetzt misst die App genauer mit."))
        } else {
            out.append(Finding(level: .info, title: "Noch zu wenig Akku-Daten", detail: "Arbeite eine Weile ohne Kabel. Nach 20 Minuten gibt es hier die erste Auswertung."))
        }

        // 2. Wohin geht die Energie (letzte 7 Tage, Akku)
        let batt = m.history.filter { !$0.ac && $0.t >= week }
        if batt.count >= 20 {
            let total = batt.reduce(0) { $0 + $1.sysW }
            if total > 0 {
                let shares = Part.allCases.map { p in (p, batt.reduce(0) { $0 + p.value($1) } / total) }.sorted { $0.1 > $1.1 }
                let top = shares[0]
                let brights = batt.compactMap(\.bright)
                let bright = brights.isEmpty ? nil : brights.reduce(0, +) / Double(brights.count)
                if top.0 == .rest, top.1 > 0.4 {
                    var d = "\(Int(top.1 * 100)) % deines Akkustroms landen außerhalb des Chips, vor allem im Bildschirm."
                    if let b = bright, b > 0.7 { d += " Deine Helligkeit liegt im Schnitt bei \(Int(b * 100)) %. Das XDR-Display ist der größte Einzelverbraucher, 20 % weniger Helligkeit bringen oft mehr als jede App-Optimierung." }
                    d += " Auch Kamera, USB-Geräte und eine hohe Lautstärke ziehen hier mit."
                    out.append(Finding(level: .warning, title: "Der Bildschirm frisst am meisten", detail: d))
                } else if top.0 == .cpu, top.1 > 0.35 {
                    out.append(Finding(level: .warning, title: "Der Prozessor arbeitet viel", detail: "\(Int(top.1 * 100)) % gehen in Rechenarbeit. Unter Apps siehst du, welche Programme dahinterstecken."))
                } else if top.0 == .gpu, top.1 > 0.25 {
                    out.append(Finding(level: .warning, title: "Die Grafik läuft viel", detail: "\(Int(top.1 * 100)) % gehen in die Grafik. Typisch für Videos, Browser-Tabs mit Animationen oder externe Monitore."))
                }
            }
        }

        // 3. Apps
        let apps = m.appTotals(since: week, batteryOnly: true)
        if let first = apps.first, first.share > 0.25, first.wh > 1 {
            var d = "\(first.name) verbraucht \(Int(first.share * 100)) % der gemessenen Prozessor-Energie auf Akku."
            if first.name.contains("Chrome") { d += " In Chrome hilft der Energiesparmodus (Einstellungen › Leistung) und das Schließen von Tabs mit Videos oder Live-Dashboards." }
            if first.name.contains("Claude") || first.name.contains("Electron") || first.name.contains("Grok") { d += " Electron-Apps laufen im Hintergrund weiter. Schließ sie ganz, wenn du sie nicht brauchst." }
            out.append(Finding(level: .warning, title: "\(first.name) ist der größte App-Verbraucher", detail: d))
        }
        let chromeIsBig = apps.prefix(3).contains { $0.name == "Google Chrome" }
        if m.chromeConnected {
            let sites = m.siteTotals(since: week, batteryOnly: false)
            if let s = sites.first, s.share > 0.3, s.wh > 0.3 {
                out.append(Finding(level: .warning, title: "\(s.name) ist dein teuerster Tab", detail: "Tabs von \(s.name) haben \(Int(s.share * 100)) % der gemessenen Tab-Energie gebraucht. Unter Chrome-Tabs siehst du, welcher Tab gerade wie viel zieht."))
            }
            if let t = m.tabAverages().first, t.watts > 1.5 {
                out.append(Finding(level: .warning, title: "Ein Tab zieht gerade \(Fmt.watts(t.watts))", detail: "„\(t.tab.title)“ (\(t.tab.host)) rechnet gerade dauerhaft. Auf Akku sind das allein über \(Int(t.watts / max(m.batteryAverage(since: week)?.watts ?? 16, 1) * 100)) % deines Verbrauchs."))
            }
        } else if chromeIsBig || m.liveApps.prefix(3).contains(where: { $0.name == "Google Chrome" }) {
            out.append(Finding(level: .info, title: "Chrome verbinden für Tab-Werte", detail: "Chrome gehört zu deinen größten Verbrauchern. Unter Chrome-Tabs kannst du die Erweiterung in zwei Minuten einrichten, dann siehst du, welcher Tab wie viel zieht."))
        }
        let heavy = apps.filter { ["Spotlight-Indexierung", "Fotos-Analyse", "iCloud Drive", "Google Drive", "Dropbox", "Time Machine"].contains($0.name) && $0.share > 0.08 }
        for h in heavy {
            out.append(Finding(level: .info, title: "\(h.name) läuft im Hintergrund", detail: "\(h.name) hat \(Int(h.share * 100)) % der Prozessor-Energie auf Akku gebraucht. Das ist meist vorübergehend, etwa nach großen Datei-Änderungen. Bleibt es dauerhaft hoch, lohnt ein Blick in die Einstellungen der App."))
        }

        // 4. Ruhezustand
        if let s = m.logSleepRate(since: week) {
            if s.pctPerHour > 1.5 {
                out.append(Finding(level: .serious, title: "Akku leert sich im Ruhezustand", detail: "Zugeklappt verlierst du \(Fmt.num(s.pctPerHour, 1)) % pro Stunde. Normal sind unter 0,5 %. Prüf unter Ruhezustand, wer den Mac weckt."))
            } else {
                out.append(Finding(level: .good, title: "Ruhezustand ist sauber", detail: "Zugeklappt verlierst du nur \(Fmt.num(s.pctPerHour, 1)) % pro Stunde (gemessen über \(Fmt.hours(s.hours))). Das Problem entsteht also beim Arbeiten."))
            }
        }

        // 5. Wachhalter
        let longBlockers = m.blockers.filter { $0.seconds > 3600 }
        if !longBlockers.isEmpty {
            let unique = Array(Set(longBlockers.map(\.process))).sorted()
            let names = unique.joined(separator: ", ")
            out.append(Finding(level: .info, title: unique.count == 1 ? "\(names) hält den Mac wach" : "Apps halten den Mac wach",
                               detail: "\(names) \(unique.count == 1 ? "verhindert" : "verhindern") seit über einer Stunde den automatischen Ruhezustand. Zugeklappt schläft der Mac trotzdem, aber wenn er offen herumsteht, läuft er durch."))
        }
        if m.blockers.contains(where: { $0.label.contains("camera") || $0.label.contains("Camera") }) {
            out.append(Finding(level: .warning, title: "Eine App hält die Kamera offen", detail: "Laut macOS nutzt gerade eine App die Kamera (\(m.blockers.first { $0.label.lowercased().contains("camera") }?.process ?? "")). Das kostet dauerhaft Strom. Beende den Anruf oder die App, wenn du sie nicht brauchst."))
        }

        // 6. Akku-Zustand
        if let r = m.reading {
            if r.healthPct < 80 {
                out.append(Finding(level: .serious, title: "Akku ist verschlissen", detail: "Der Akku hat nur noch \(Int(r.healthPct)) % seiner Originalkapazität. Unter 80 % empfiehlt Apple einen Tausch."))
            } else {
                out.append(Finding(level: .good, title: "Akku ist gesund", detail: "\(Int(r.healthPct)) % der Originalkapazität nach \(r.cycles) Ladezyklen. Am Akku selbst liegt es nicht."))
            }
            if let a = r.adapterW, a < 90, let peak = m.history.filter({ $0.ac }).map(\.sysW).max(), peak > Double(a) {
                out.append(Finding(level: .info, title: "Dein Netzteil ist zu schwach für Volllast", detail: "Angeschlossen ist ein \(a)-W-Netzteil, dein Mac hat schon \(Fmt.watts(peak)) gezogen. Unter Last entlädt sich der Akku dann trotz Kabel. Das Original-Netzteil hat 140 W."))
            }
        }
        if !(m.live.last?.lpm ?? true), let avg = m.batteryAverage(since: week), avg.watts > 9 {
            out.append(Finding(level: .info, title: "Stromsparmodus ausprobieren", detail: "Systemeinstellungen › Batterie › Stromsparmodus „Nur bei Batteriebetrieb“. Der Mac bleibt damit schnell genug für Browser, Mails und Schnitt-Vorschau und spart spürbar."))
        }
        if m.externalDisplays > 0 {
            out.append(Finding(level: .info, title: "Externer Monitor angeschlossen", detail: "Ein externer Bildschirm lässt Grafik und Display-Chip dauerhaft mitlaufen. Auf Akku kostet das schnell 3 bis 6 W extra."))
        }
        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }
}
