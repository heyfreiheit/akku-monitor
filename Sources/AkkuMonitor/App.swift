import SwiftUI

@main
struct AkkuMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(monitor).environment(\.locale, Locale(identifier: "de_DE"))
        } label: {
            MenuLabel().environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Akku Monitor", id: "main") {
            MainView()
                .environmentObject(monitor)
                .environment(\.locale, Locale(identifier: "de_DE"))
                .frame(minWidth: 920, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 800)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in Monitor.shared.start() }
        // Bei SIGTERM (z. B. beim Neubauen) noch sichern, sonst gehen bis zu 5 Minuten App-Werte verloren.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            MainActor.assumeIsolated { Monitor.shared.flushMinute(); Monitor.shared.saveApps() }
            exit(0)
        }
        src.resume()
        termSource = src
    }
    private var termSource: DispatchSourceSignal?

    /// Erneutes Öffnen über Finder, Spotlight oder Dock zeigt das Analysefenster.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return true
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}
