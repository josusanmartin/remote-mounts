import AppKit
import SwiftUI

/// Asks for a locked SSH key's passphrase, once, and loads the key into the Mac's ssh-agent
/// so mounting, browsing and Terminal can all use it without asking again.
struct UnlockKeyView: View {
    @EnvironmentObject var m: MountManager
    @AppStorage("rememberPassphrase") private var remember = true
    @State private var key = ""
    @State private var passphrase = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let r = m.unlockRequest {
                content(r)
            } else {
                Color.clear.frame(width: 420, height: 1)
            }
        }
        .onChange(of: m.unlockRequest?.id, initial: true) {
            guard let r = m.unlockRequest else {
                window?.close()
                return
            }
            if !r.keys.contains(key) { key = r.keys[0] }
            passphrase = ""
            error = nil
            focused = true
            bringToFront()
        }
        // Closing the window counts as Cancel
        .onDisappear { if m.unlockRequest != nil { m.cancelUnlock() } }
    }

    private func content(_ r: MountManager.UnlockRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock Your SSH Key").font(.headline)
                    Text(explanation(r))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if r.keys.count > 1 {
                    Picker("Key", selection: $key) {
                        ForEach(r.keys, id: \.self) { Text(SSHKeys.displayName($0)).tag($0) }
                    }
                }
                SecureField("Passphrase", text: $passphrase, prompt: Text("Passphrase for \(keyName)"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .disabled(working)
                    .onSubmit(unlock)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Remember in my Keychain", isOn: $remember).toggleStyle(.checkbox)
                    Text(remember
                         ? "Remote Mounts unlocks the key on its own after you restart."
                         : "The key stays unlocked until you log out or restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
            .padding(.leading, 60)

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { m.cancelUnlock() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") { unlock() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var keyName: String { (key as NSString).lastPathComponent }

    private func explanation(_ r: MountManager.UnlockRequest) -> String {
        let hosts = r.hosts.map { "“\($0)”" }
        let who = hosts.count == 1 ? "\(hosts[0]) logs" : ListFormatter.localizedString(byJoining: hosts) + " log"
        return "\(who) in with the key \(SSHKeys.displayName(key)), which is protected by a passphrase. "
            + "Enter it once and Remote Mounts adds the key to your Mac's SSH agent, so connecting won't ask again."
    }

    private func unlock() {
        guard !passphrase.isEmpty, !working else { return }
        working = true
        error = nil
        let (key, passphrase, remember) = (key, passphrase, remember)
        Task {
            let result = await m.submitUnlock(key: key, passphrase: passphrase, remember: remember)
            working = false
            switch result {
            case .unlocked:
                self.passphrase = ""
            case .wrongPassphrase:
                error = "That passphrase isn't right. Try again."
                self.passphrase = ""
                focused = true
            case .failed(let msg):
                error = msg
            }
        }
    }

    private var window: NSWindow? { NSApp.windows.first { $0.title == "Unlock SSH Key" } }

    /// The prompt can appear while another app is in front (e.g. a mount at login): show it on top,
    /// but only take the keyboard if Remote Mounts is already active, so it can't catch keystrokes
    /// meant for another app.
    private func bringToFront() {
        DispatchQueue.main.async {
            guard let w = window else { return }
            if !w.isVisible { w.center() }
            w.orderFrontRegardless()
            if NSApp.isActive { w.makeKey() }
        }
    }
}
