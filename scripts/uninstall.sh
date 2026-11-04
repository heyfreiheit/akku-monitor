#!/bin/zsh
# Entfernt Akku Monitor. Mit --all auch Messwerte und Einstellungen.
set -euo pipefail
BUNDLE_ID="${BUNDLE_ID:-com.heyfreiheit.akkumonitor}"

pkill -x AkkuMonitor 2>/dev/null || true
rm -rf "$HOME/Applications/Akku Monitor.app" "$HOME/Library/Caches/akku-monitor-build"
echo "App und Build-Ordner entfernt."

if [[ "${1:-}" == "--all" ]]; then
  rm -rf "$HOME/Library/Application Support/AkkuMonitor"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  echo "Messwerte und Einstellungen entfernt."
else
  echo "Deine Messwerte liegen weiter in ~/Library/Application Support/AkkuMonitor (löschen mit --all)."
fi
echo "Die Chrome-Erweiterung entfernst du in chrome://extensions."
