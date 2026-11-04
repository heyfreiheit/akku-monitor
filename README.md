# Akku Monitor

Eine kleine Mac-App für die Menüleiste, die dir zeigt, wohin der Akku deines MacBooks geht. Sie misst alle 10 Sekunden, wie viel Strom dein Mac gerade zieht, teilt das auf Prozessor, Grafik, Speicher und Bildschirm auf, zeigt dir die Apps mit dem größten Verbrauch und auf Wunsch sogar einzelne Chrome-Tabs. Oben in der Menüleiste siehst du jederzeit Ladestand und Verbrauch, zum Beispiel „94 % · 12 W“.

Entstanden ist sie, weil ein MacBook Pro mit M4 Max ohne Kabel gefühlt viel zu schnell leer war und die Aktivitätsanzeige von macOS nicht verrät, warum. Alles bleibt lokal auf deinem Mac, die App schickt nichts ins Internet und braucht keine Admin-Rechte.

*English: A native macOS menu bar app that shows where your MacBook's battery goes (system power, chip components, per-app and per-Chrome-tab energy). The interface is German. Build it with `./scripts/build.sh --open` on an Apple Silicon Mac with macOS 15+.*

## Voraussetzungen

Du brauchst ein MacBook mit Apple-Chip (M1 oder neuer), macOS 15 Sequoia oder neuer und Swift 6, das mit den Xcode Command Line Tools kommt (`xcode-select --install`). Xcode selbst brauchst du nicht.

## Installieren mit Claude Code

Am einfachsten öffnest du Claude Code in einem beliebigen Ordner und schreibst:

> Klon https://github.com/heyfreiheit/akku-monitor und installier mir die App.

Claude Code liest dann die Anleitung in `CLAUDE.md`, prüft die Voraussetzungen, baut die App und hilft dir auf Wunsch, die Chrome-Erweiterung einzurichten.

## Installieren von Hand

```bash
git clone https://github.com/heyfreiheit/akku-monitor.git
cd akku-monitor
./scripts/build.sh --open
```

Das Skript baut die App (beim ersten Mal 1 bis 2 Minuten), legt sie nach `~/Applications/Akku Monitor.app` und startet sie. Beim ersten Start öffnet sich das Analysefenster, macOS fragt einmal, ob die App Mitteilungen schicken darf, und sie trägt sich als Anmeldeobjekt ein, damit sie nach jedem Neustart weitermisst. Das kannst du in den Einstellungen der App abschalten.

Aktualisieren geht mit `git pull` und noch einmal `./scripts/build.sh --open`. Deine Messwerte bleiben dabei erhalten.

## Was du siehst

In der Menüleiste stehen Ladestand und Verbrauch. Ein Klick zeigt den Verbrauch gerade, die Restlaufzeit, die Aufteilung nach Bereichen, die fünf größten Verbraucher, die größten Chrome-Tabs und wer den Mac gerade wachhält. Unten im Menü stellst du um, ob oben Prozent, Watt oder beides steht.

Das Analysefenster hat sieben Bereiche. Die Übersicht zeigt Kennzahlen, eine automatische Diagnose mit konkreten Empfehlungen und die Leistung der letzten 24 Stunden. Unter Verlauf findest du Ladestand und Leistung nach Bereich übereinander, dazu jede Akku-Sitzung mit Durchschnittsverbrauch und hochgerechneter Laufzeit. Apps zeigt die Prozessor-Energie pro App in Wh, wahlweise nur im Akkubetrieb. Chrome-Tabs zeigt den Verbrauch pro Tab und pro Website. Ruhezustand zeigt, wie viel Akku der Mac im Schlaf verliert und wer ihn wachhält. Akku-Zustand zeigt Gesundheit, Ladezyklen, Temperatur und Netzteil. In den Einstellungen legst du fest, ab wann die App dich warnt.

Mitteilungen bekommst du, wenn der Verbrauch 5 Minuten lang hoch ist (Standard ab 20 W), wenn eine einzelne App mehr als 4 W zieht, wenn ein Chrome-Tab mehr als 1,5 W zieht, wenn der Mac im Ruhezustand auffällig viel verliert und unter 15 % Ladestand.

Die App sieht auch die Zeit vor ihrer Installation: Aus dem Energieprotokoll von macOS (`pmset -g log`) rekonstruiert sie die letzten Tage, auf ganze Prozent genau.

## Chrome-Tabs messen

Chrome verrät in der normalen Version nicht, welcher Prozess zu welchem Tab gehört. Deshalb liegt eine kleine Erweiterung bei. So richtest du sie ein:

1. Öffne in Chrome `chrome://extensions`.
2. Schalte oben rechts den Entwicklermodus ein (englisch: Developer mode).
3. Klick auf „Entpackte Erweiterung laden“ (Load unpacked) und wähl den Ordner `~/Library/Application Support/AkkuMonitor/Chrome-Erweiterung`. Die App legt ihn beim Start an, im Bereich Chrome-Tabs gibt es einen Knopf, der ihn im Finder zeigt.

Die Erweiterung meldet der App alle 30 Sekunden Titel und Adresse deiner Tabs, über eine Schnittstelle, die nur auf deinem Mac erreichbar ist (`127.0.0.1:47830`). Für jeden neuen Tab lässt sie die Seite einmal 0,15 Sekunden rechnen, daran erkennt die App, welcher Chrome-Prozess zu dem Tab gehört. Inhalte von Seiten liest sie nicht. Die Schnittstelle nimmt nur Anfragen der Erweiterung an, Webseiten kommen nicht durch.

Gemessen wird die Rechenarbeit der Tabs. Video-Dekodierung und das Zeichnen auf den Bildschirm laufen in Chromes gemeinsamem Grafikprozess, der als eigene Zeile erscheint. Teilen sich mehrere Tabs einen Prozess, wird geteilt.

## So misst die App

Den Gesamtverbrauch liest sie aus der Power-Telemetrie des Akkus (`AppleSmartBattery`, Wert `SystemLoad`). Das ist der echte Verbrauch des ganzen Macs, auch am Netzteil. Die Aufteilung auf Prozessor, Grafik, Speicher und Medien-Chip kommt aus dem Energiemodell des Chips (IOReport). Was übrig bleibt, landet bei „Bildschirm & Peripherie“, also Hintergrundbeleuchtung, WLAN, SSD, Lautsprecher und USB-Geräte. Die Energie pro App kommt von macOS selbst (`proc_pid_rusage`), Hilfsprozesse werden ihrer App zugerechnet. Dazu kommen Bildschirmhelligkeit, Stromsparmodus, externe Monitore und die Wachhalter aus `pmset -g assertions`.

Gespeichert wird ein Minutenmittel für 60 Tage in `~/Library/Application Support/AkkuMonitor/`. Die App selbst braucht dabei weniger als 0,1 % Prozessorleistung.

## Grenzen

Pro App gibt es nur den Prozessoranteil. Grafik und Bildschirm lassen sich unter macOS ohne Root-Rechte keiner App zuordnen, und Systemprozesse wie WindowServer sind für normale Apps nicht lesbar. IOReport und die Helligkeitsabfrage sind private Schnittstellen von Apple. Fallen sie nach einem macOS-Update weg, zeigt die App weiter Gesamtverbrauch und App-Werte, nur die Aufteilung fehlt. Die Oberfläche ist auf Deutsch.

## Deinstallieren

```bash
./scripts/uninstall.sh
```

Das beendet die App und löscht sie samt Build-Ordner. Mit `--all` verschwinden auch deine Messwerte und Einstellungen. Die Chrome-Erweiterung entfernst du in `chrome://extensions`.

## Aufbau

| Datei | Inhalt |
|---|---|
| `Sensors.swift` | Akku, IOReport-Energie, Energie pro Prozess, Helligkeit |
| `PowerLog.swift` | macOS-Energieprotokoll und Wachhalter |
| `Model.swift` | Datenmodell, Speicher, Formatierung |
| `Monitor.swift` | Messschleife, Auswertung, Mitteilungen |
| `Diagnosis.swift` | Regeln, die aus Messwerten Empfehlungen machen |
| `Chrome.swift`, `ChromeView.swift` | Tab-Zuordnung, lokale Schnittstelle, Chrome-Bereich |
| `Components.swift`, `MenuView.swift`, `MainView.swift` | Oberfläche mit SwiftUI und Swift Charts |
| `chrome-extension/` | Chrome-Erweiterung (Manifest V3) |
| `scripts/` | Bauen, installieren, deinstallieren |

## Lizenz

MIT, siehe `LICENSE`. Gebaut von [heyfreiheit](https://heyfreiheit.com) mit Claude Code.
