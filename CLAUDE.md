# Anleitung für Claude Code und andere Coding-Agenten

Dieses Repo ist „Akku Monitor“, eine native macOS-Menüleisten-App (Swift, SwiftUI, Swift Package Manager), die den Akkuverbrauch eines MacBooks misst. Die Oberfläche ist deutsch. Antworte dem Nutzer in seiner Sprache.

## Wenn der Nutzer die App installieren will

1. Prüfe die Voraussetzungen und erkläre dem Nutzer verständlich, was fehlt:
   - Apple-Chip: `uname -m` muss `arm64` sein. Intel-Macs werden nicht unterstützt.
   - macOS 15 oder neuer: `sw_vers -productVersion`.
   - Swift 6 oder neuer: `swift --version`. Fehlt Swift, muss der Nutzer `xcode-select --install` selbst ausführen und den Dialog bestätigen. Das kannst du nicht für ihn erledigen.
   - Ein Akku sollte vorhanden sein (`ioreg -rc AppleSmartBattery | grep CurrentCapacity`). Auf einem Mac ohne Akku läuft die App, zeigt aber kaum etwas.
2. Baue und starte mit `./scripts/build.sh --open`. Das dauert beim ersten Mal 1 bis 2 Minuten, also mit ausreichend Timeout oder im Hintergrund ausführen. Das Skript prüft die Voraussetzungen auch selbst und bricht mit einer klaren Meldung ab.
3. Sag dem Nutzer, was jetzt passiert: Das Analysefenster öffnet sich, macOS fragt nach der Erlaubnis für Mitteilungen, und oben rechts in der Menüleiste erscheinen Ladestand und Watt. Die App trägt sich als Anmeldeobjekt ein, abschaltbar in ihren Einstellungen.
4. Biete an, die Chrome-Erweiterung einzurichten, wenn der Nutzer Chrome verwendet. Das muss der Nutzer selbst in Chrome klicken, Erweiterungen lassen sich nicht per Skript installieren:
   - `chrome://extensions` öffnen,
   - oben rechts den Entwicklermodus (Developer mode) einschalten,
   - „Entpackte Erweiterung laden“ (Load unpacked) und den Ordner `~/Library/Application Support/AkkuMonitor/Chrome-Erweiterung` wählen. Mit `open -R ~/Library/Application\ Support/AkkuMonitor/Chrome-Erweiterung` zeigst du ihn im Finder.
   - Prüfen, ob es geklappt hat: Im Bereich „Chrome-Tabs“ der App stehen nach etwa einer Minute die Tabs. Ein „!“ am Symbol der Erweiterung heißt, die App läuft nicht.
5. Empfiehl, ein, zwei Tage normal ohne Kabel zu arbeiten. Dann sind Diagnose, Akku-Sitzungen und Tab-Werte aussagekräftig.

## Aktualisieren und deinstallieren

Aktualisieren: `git pull`, dann `./scripts/build.sh --open`. Messwerte und Einstellungen bleiben erhalten.

Deinstallieren: `./scripts/uninstall.sh` entfernt App und Build-Ordner, `./scripts/uninstall.sh --all` zusätzlich Messwerte und Einstellungen. Frag vor `--all` nach, die Messwerte sind danach weg.

## Wo was liegt

- App: `~/Applications/Akku Monitor.app`, Bundle-ID `com.heyfreiheit.akkumonitor` (überschreibbar mit `BUNDLE_ID=… ./scripts/build.sh`).
- Build-Ordner: `~/Library/Caches/akku-monitor-build`, bewusst außerhalb des Repos, damit iCloud-Ordner nicht stören.
- Daten: `~/Library/Application Support/AkkuMonitor/` mit `samples.jsonl` (Minutenmittel, 60 Tage), `apps.json` (App-Energie pro Stunde), `sites.json` (Website-Energie pro Stunde).
- Lokale Schnittstelle für die Chrome-Erweiterung: `127.0.0.1:47830`, nur POST mit Header `X-Akku-Monitor: 1`.

## Beim Weiterentwickeln

- Quellcode in `Sources/AkkuMonitor/`, Aufteilung siehe README. Bauen mit `swift build -c release --scratch-path ~/Library/Caches/akku-monitor-build`, installieren und neu starten mit `./scripts/build.sh --open`.
- Messen ohne Root: Gesamtleistung aus `AppleSmartBattery › PowerTelemetryData › SystemLoad`, Aufteilung über IOReport „Energy Model“ (per `dlopen`), Energie pro Prozess über `proc_pid_rusage` (`ri_energy_nj`). Keine Funktionen einbauen, die `sudo` oder `powermetrics` brauchen.
- Texte in der Oberfläche auf Deutsch, du-Form, ohne Fachchinesisch.
- Nichts darf Daten vom Mac wegschicken.
