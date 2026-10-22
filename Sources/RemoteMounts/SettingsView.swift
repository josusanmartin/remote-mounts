import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var m: MountManager
    @AppStorage("notifications") private var notifications = true
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("confirmOpen") private var confirmOpen = true
    @State private var notificationsDenied = false
    @State private var itermEnabled = ITermIntegration.isEnabled
    @State private var itermPendingRestart = false

    var body: some View {
        Form {
            Section {
                Toggle("Open Remote Mounts at login", isOn: $m.loginItemEnabled)
                Text("Servers set to mount automatically come up as soon as you log in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep Remote Mounts in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) {
                        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.title == "Remote Mounts" }
                        NSApp.setActivationPolicy(showInDock || windowOpen ? .regular : .accessory)
                    }
                Text("Useful when the menu bar is crowded: macOS hides menu bar icons that don't fit next to the notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify me when a server disconnects or fails", isOn: $notifications)
                if notificationsDenied && notifications {
                    HStack {
                        Text("Notifications are turned off for Remote Mounts in System Settings.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
            }
            if ITermIntegration.isInstalled {
                Section {
                    Toggle("Open server paths with ⌘-click", isOn: Binding(get: { itermEnabled }, set: { on in
                        ITermIntegration.setEnabled(on)
                        itermEnabled = ITermIntegration.isEnabled
                        itermPendingRestart = ITermIntegration.isRunning
                    }))
                    Text("⌘-click /home/you/report/chart.png in an SSH session and it opens from the mounted folder. Links and files on this Mac open as usual.")
                        .font(.caption).foregroundStyle(.secondary)
                    if itermPendingRestart {
                        Label("Quit and reopen iTerm2 to apply this.", systemImage: "arrow.clockwise")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Ask before opening a file", isOn: $confirmOpen)
                        .disabled(!itermEnabled)
                } header: {
                    Text("iTerm2")
                }
            }
            Section {
                LabeledContent("Quitting") {
                    Text("Unmounts every server, after pending uploads finish")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsDenied = settings.authorizationStatus == .denied
        }
    }
}

private struct AboutSettings: View {
    @State private var rcloneVersion: String?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(spacing: 3) {
                Text("Remote Mounts").font(.title2.weight(.semibold))
                Text("Version \(appVersion)").foregroundStyle(.secondary)
            }
            Text("Mounts SSH servers as folders on your Mac using rclone over SFTP.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Group {
                if System.rclonePath == nil {
                    Label("rclone isn't installed — run “brew install rclone”", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("rclone \(rcloneVersion ?? "…")").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            HStack {
                Button("Config Folder") { reveal(MountManager.supportDir) }
                Button("Logs Folder") { reveal(MountManager.logDir) }
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/josusanmartin/remote-mounts")!)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .task {
            rcloneVersion = await Task.detached { System.rcloneVersion() }.value
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
