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
    }
}
