# Akku Monitor

Native Mac-App in der Menüleiste, die misst, wohin der Akku deines MacBook Pro geht. Gebaut für Tims MacBook Pro 16" mit M4 Max, läuft auf jedem Apple-Silicon-Mac ab macOS 15.

## Was sie misst

Alle 10 Sekunden, ohne Admin-Rechte:

- **Systemleistung in Watt** aus der Power-Telemetrie des Akkus (`AppleSmartBattery › PowerTelemetryData › SystemLoad`). Das ist der echte Gesamtverbrauch, auch am Netzteil.
- **Aufteilung nach Chip-Bereichen** über IOReport („Energy Model“): Prozessor, Grafik, Speicher, Medien & Display-Chip. Was übrig bleibt, landet in „Bildschirm & Peripherie“ (Hintergrundbeleuchtung, WLAN, SSD, Lautsprecher, USB-Geräte).
- **Prozessor-Energie pro App** über `proc_pid_rusage` (`ri_energy_nj`), gruppiert nach App-Bundle. Helper-Prozesse landen bei ihrer App (Chrome-Renderer bei Chrome). Systemprozesse anderer Nutzer (WindowServer, kernel_task) sind ohne Root nicht lesbar.
- **Bildschirmhelligkeit** (DisplayServices), **Stromsparmodus**, **externe Monitore**.
- **Wachhalter** aus `pmset -g assertions`, jede Minute.
- **Verlauf vor der Installation** aus `pmset -g log`: Ladestand bei jedem Schlafen und Aufwachen, daraus werden wache Akku-Phasen und Schlafphasen rekonstruiert (auf ganze Prozent genau).

Gespeichert wird ein Minutenmittel für 60 Tage in `~/Library/Application Support/AkkuMonitor/` (`samples.jsonl`, `apps.json`). Alles bleibt lokal.

## Was sie zeigt

- **Menüleiste:** Ladestand in Prozent und aktuelle Watt (umschaltbar direkt im Menü auf nur Prozent oder nur Watt), Klick öffnet Verbrauch, Restlaufzeit, Aufteilung, Top-Apps und Wachhalter.
- **Übersicht:** Kennzahlen, automatische Diagnose mit Empfehlungen, Leistung der letzten 24 Stunden.
- **Verlauf:** Ladestand, gestapelte Leistung nach Bereich, Akku-Sitzungen mit Ø-Watt und hochgerechneter Laufzeit.
- **Apps:** Prozessor-Energie pro App in Wh, wahlweise nur Akkubetrieb.
- **Ruhezustand:** Verlust pro Stunde im Schlaf, wer den Mac wachhält.
- **Akku-Zustand:** Gesundheit, Zyklen, Temperatur, Netzteil.
- **Mitteilungen:** bei hohem Verbrauch (Standard ab 20 W über 5 Minuten), wenn eine einzelne App über 4 W Prozessor zieht, bei auffälligem Verlust im Ruhezustand und unter 15 %.

## Chrome-Tabs

Pro Tab misst die App über die Erweiterung in `chrome-extension/` (Manifest V3, nur lokal). Die App legt sie beim Start nach `~/Library/Application Support/AkkuMonitor/Chrome-Erweiterung`, von dort wird sie in Chrome entpackt geladen (`chrome://extensions` › Developer mode › Load unpacked).

So funktioniert die Zuordnung: Chrome verrät in der normalen Version nicht, welcher Prozess zu welchem Tab gehört (`chrome.processes` gibt es nur im Dev-Kanal). Die Erweiterung schickt der App alle 30 Sekunden und bei Änderungen die Tab-Liste an `127.0.0.1:47830`. Für Tabs, deren Prozess die App noch nicht kennt, startet sie `/calib/start`, lässt im Tab 150 ms rechnen und meldet `/calib/end`. Die App nimmt den Renderer-Prozess mit dem klar größten Energiesprung (mindestens 15 mJ und 2,5-mal mehr als der zweitgrößte). Neu zugeordnet wird bei Wechsel der Website oder wenn der Prozess weg ist.

Gemessen wird die Prozessor-Energie der Renderer. Teilen sich mehrere Tabs einen Prozess, wird geteilt. Chromes Grafikprozess (Video, Scrollen) und Erweiterungen erscheinen getrennt. Websites werden stündlich in `sites.json` aufsummiert. Die Schnittstelle nimmt nur POSTs mit Header `X-Akku-Monitor: 1` und ohne fremden Origin an, Webseiten kommen also nicht durch.

Getestet am 04.11.2026: zwei Test-Tabs, je 5 von 5 Zuordnungen korrekt, bei 66 parallel laufenden Renderern.

## Bauen und installieren

```bash
./scripts/build.sh --open
```

Baut mit SwiftPM (Build-Ordner liegt in `~/Library/Caches/akku-monitor-build`, außerhalb von iCloud), packt `~/Applications/Akku Monitor.app`, signiert ad hoc und startet sie. Beim ersten Start trägt sie sich als Anmeldeobjekt ein (abschaltbar unter Einstellungen).

## Aufbau

| Datei | Inhalt |
|---|---|
| `Sensors.swift` | IOKit-Akku, IOReport-Energie, Energie pro Prozess, Helligkeit |
| `PowerLog.swift` | `pmset`-Protokoll und Wachhalter |
| `Model.swift` | Datenmodell, Speicher, Formatierung |
| `Monitor.swift` | Messschleife, Auswertung, Mitteilungen |
| `Diagnosis.swift` | Regeln, die aus Messwerten Aussagen machen |
| `Chrome.swift`, `ChromeView.swift` | Tab-Zuordnung, lokale Schnittstelle, Chrome-Bereich |
| `Components.swift`, `MenuView.swift`, `MainView.swift` | Oberfläche (SwiftUI, Swift Charts) |

Diagrammfarben: validierte Kategorie-Palette mit getrennten Hell- und Dunkelwerten, feste Reihenfolge Prozessor, Grafik, Speicher, Medien-Chip, Bildschirm.

## Grenzen

- Pro App gibt es nur den Prozessoranteil. Grafik und Bildschirm lassen sich unter macOS ohne Root keiner App zuordnen.
- IOReport und DisplayServices sind private Schnittstellen. Fallen sie nach einem macOS-Update weg, zeigt die App weiter Gesamtleistung und App-Werte, nur die Aufteilung fehlt.
- Die Protokoll-Auswertung ist auf ganze Prozent genau und sieht nur Phasen, die mit Aufwachen beginnen und mit Schlafen enden.
