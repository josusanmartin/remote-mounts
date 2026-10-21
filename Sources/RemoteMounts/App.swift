import AppKit
import SwiftUI
import UserNotifications

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
        .defaultSize(width: 860, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Server…") { manager.showAddSheet = true }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView().environmentObject(manager)
        }

        #if DEBUG
        // RM_MENU_PREVIEW=1 shows the menu bar panel in a normal window, for screenshots
        Window("Menu Preview", id: "menu-preview") {
            MenuView().environmentObject(manager)
        }
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["RM_MENU_PREVIEW"] != nil ? .presented : .suppressed)
        .windowResizability(.contentSize)
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the same mount folders
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "showInDock") { NSApp.setActivationPolicy(.regular) }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if MountManager.shared.configs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MountManager.shared.showAddSheet = true
                MountManager.shared.showManagerWindow?()
            }
        }
    }

    // Opening the app again (Finder, Spotlight, `open`) shows the manager window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MountManager.shared.showManagerWindow?()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var quitAlert: NSAlert?
    private var quitTimer: Timer?

    /// Quitting stops every mount, so pending uploads get to finish first. The prompt is a
    /// floating window rather than a modal alert: a modal returns at once when another app is in front.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = MountManager.shared
        // Flush the Mac's buffered writes into rclone, then ask it directly: the polled
        // numbers can be a couple of seconds old and miss a file that was just saved
        System.flushWrites()
        let silent = manager.refreshStatsNow()
        guard manager.totalPendingUploads > 0 || !silent.isEmpty else { return .terminateNow }
        guard quitAlert == nil else { return .terminateLater }

        let alert = NSAlert()
        alert.messageText = "Finishing uploads"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Now")
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(cancelQuit)
        alert.buttons[1].target = self
        alert.buttons[1].action = #selector(quitNow)
        updateQuitText(alert, pending: max(manager.totalPendingUploads, 1))
        // Alert panels hide while their app is inactive, and macOS won't bring a background app
        // forward, so keep it visible and floating above everything else
        alert.window.hidesOnDeactivate = false
        alert.window.level = .floating
        alert.window.center()
        quitAlert = alert
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        alert.window.orderFrontRegardless()
        alert.window.makeKey()

        // .common: while a reply is pending the run loop is in the modal-panel mode
        var emptyReadings = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let alert = self.quitAlert else { return }
                let silent = manager.refreshStatsNow()
                let left = manager.totalPendingUploads
                // Two empty readings in a row, so a file between upload steps isn't missed
                emptyReadings = left == 0 && silent.isEmpty ? emptyReadings + 1 : 0
                if emptyReadings >= 2 {
                    self.finishQuit(true)
                } else if left > 0 {
                    self.updateQuitText(alert, pending: left)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quitTimer = timer
        return .terminateLater
    }

    private func updateQuitText(_ alert: NSAlert, pending: Int) {
        alert.informativeText = "\(pending) file\(pending == 1 ? " is" : "s are") still uploading. "
            + "Remote Mounts will quit as soon as \(pending == 1 ? "it's" : "they're") done.\n\n"
            + "If you quit now, the uploads resume the next time you mount."
        alert.layout()
    }

    @objc private func cancelQuit() { finishQuit(false) }
    @objc private func quitNow() { finishQuit(true) }

    private func finishQuit(_ quit: Bool) {
        quitTimer?.invalidate()
        quitTimer = nil
        quitAlert?.window.orderOut(nil)
        quitAlert = nil
        if !quit, !UserDefaults.standard.bool(forKey: "showInDock"),
           !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Remote Mounts" }) {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.reply(toApplicationShouldTerminate: quit)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MountManager.shared.shutdown()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { MountManager.shared.showManagerWindow?() }
        completionHandler()
    }
}

struct MenuBarLabel: View {
    @ObservedObject var manager: MountManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                manager.showManagerWindow = {
                    openWindow(id: "manager")
                    NSApp.activate(ignoringOtherApps: true)
                }
                manager.showSettingsWindow = {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
    }

    private var symbol: String {
        if manager.anyFailed { return "externaldrive.badge.exclamationmark" }
        return manager.anyMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive"
    }
}


