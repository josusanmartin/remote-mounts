import AppKit
import SwiftUI

@main
struct RemoteMountsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var manager = MountManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(manager)
        } label: {
            MenuBarLabel(manager: manager)
        }
        .menuBarExtraStyle(.window)

        Window("Remote Mounts", id: "manager") {
            ManagerView().environmentObject(manager)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if MountManager.shared.configs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MountManager.shared.showManagerWindow?() }
        }
    }

    // Opening the app again (Finder, Spotlight, `open`) shows the manager window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MountManager.shared.showManagerWindow?()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MountManager.shared.shutdown()
    }
}

struct MenuBarLabel: View {
    @ObservedObject var manager: MountManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                manager.showManagerWindow = {
                    openWindow(id: "manager")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    private var symbol: String {
        if manager.anyFailed { return "externaldrive.badge.exclamationmark" }
        return manager.anyMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive"
    }
}
