import AppKit
import SwiftUI

struct StatusDot: View {
    let status: MountStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch status {
        case .mounted: return .green
        case .mounting, .unmounting: return .orange
        case .failed: return .red
        case .unmounted: return .secondary.opacity(0.5)
        }
    }
}

// MARK: - Menu bar panel

struct MenuView: View {
    @EnvironmentObject var m: MountManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Remote Mounts").font(.headline)
                Spacer()
                Button { m.showManagerWindow?() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Manage mounts")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if m.configs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No servers yet").foregroundStyle(.secondary)
                    Button("Add a server…") {
                        m.addConfig()
                        m.showManagerWindow?()
                    }
                }
                .padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(m.configs) { c in
                        MountRow(config: c)
                        if c.id != m.configs.last?.id { Divider().padding(.leading, 34) }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Mount All") { m.mountAll() }.disabled(m.configs.isEmpty)
                Button("Unmount All") { m.unmountAll() }.disabled(m.wanted.isEmpty)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .help("Unmounts everything and quits")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 380)
    }
}

struct MountRow: View {
    @EnvironmentObject var m: MountManager
    let config: MountConfig

    var body: some View {
        let status = m.status(config.id)
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: status).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).fontWeight(.medium)
                Text("\(config.remoteDescription) → \(config.displayMountPoint)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if status.isFailed || status == .mounting || status == .unmounting {
                    Text(status.label).font(.caption)
                        .foregroundStyle(status.isFailed ? .red : .secondary)
                        .lineLimit(2)
                }
                if m.needsRemount(config.id) {
                    Button("Settings changed — remount") { m.remount(config.id) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Spacer(minLength: 4)
            Button { m.openInFinder(config.id) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .disabled(status != .mounted)
                .help("Open in Finder")
            Menu {
                Button("Open in Finder") { m.openInFinder(config.id) }.disabled(status != .mounted)
                Button("Remount") { m.remount(config.id) }.disabled(!m.isWanted(config.id))
                Button("Show Log") { m.openLog(config.id) }
                Divider()
                Button("Edit…") {
                    m.selection = config.id
                    m.showManagerWindow?()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Toggle("", isOn: Binding(
                get: { m.isWanted(config.id) },
                set: { $0 ? m.mount(config.id) : m.unmount(config.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Manager window

struct ManagerView: View {
    @EnvironmentObject var m: MountManager

    var body: some View {
        NavigationSplitView {
            List(selection: $m.selection) {
                ForEach(m.configs) { c in
                    HStack(spacing: 8) {
                        StatusDot(status: m.status(c.id))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name)
                            Text(c.host.isEmpty ? "no host" : c.host)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(c.id)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 2) {
                        Button { m.addConfig() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                            .help("Add a server")
                        Button {
                            if let id = m.selection { m.removeConfig(id) }
                        } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                            .disabled(m.selection == nil)
                            .help("Remove (unmounts it; nothing on the server is deleted)")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    Toggle("Open at login", isOn: $m.loginItemEnabled)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            if let id = m.selection, m.config(id) != nil {
                MountEditor(id: id).id(id)
            } else {
                ContentUnavailableView("No server selected", systemImage: "externaldrive",
                                       description: Text("Add a server with the + button."))
            }
        }
        .frame(minWidth: 740, minHeight: 560)
        .onAppear { if m.selection == nil { m.selection = m.configs.first?.id } }
    }
}

struct MountEditor: View {
    @EnvironmentObject var m: MountManager
    let id: UUID
    @State private var hosts = System.sshHosts()
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    private var c: Binding<MountConfig> {
        Binding(get: { m.config(id) ?? MountConfig() }, set: { m.update($0) })
    }

    var body: some View {
        let status = m.status(id)
        Form {
            Section("Server") {
                TextField("Name", text: c.name)
                HStack {
                    TextField("SSH host", text: c.host, prompt: Text("alias from ~/.ssh/config, or user@host"))
                    Menu {
                        ForEach(hosts, id: \.self) { h in Button(h) { pickHost(h) } }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pick a host from ~/.ssh/config")
                }
                TextField("Remote folder", text: c.remotePath, prompt: Text("home folder"))
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }
                        .disabled(testing || c.wrappedValue.host.isEmpty)
                    if let r = testResult {
                        Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? .green : .red)
                            .lineLimit(2)
                    }
                }
            }

            Section {
                HStack {
                    TextField("Mount at", text: c.mountPoint)
                    Button("Choose…") { chooseFolder() }
                }
                Toggle("Mount when Remote Mounts starts", isOn: c.autoMount)
                Toggle("Read-only", isOn: c.readOnly)
            } header: {
                Text("On this Mac")
            } footer: {
                Text("Remote folder: leave empty for your home folder, or use / for the whole server.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: c.cacheSizeGB, in: 1...500) {
                    LabeledContent("File cache", value: "\(c.wrappedValue.cacheSizeGB) GB")
                }
                Stepper(value: c.dirCacheMinutes, in: 1...240) {
                    LabeledContent("Remember folder contents for", value: "\(c.wrappedValue.dirCacheMinutes) min")
                }
                TextField("Extra rclone flags", text: c.extraFlags, prompt: Text("e.g. --vfs-read-ahead 64M"))
            } header: {
                Text("Performance")
            } footer: {
                Text("Files you open are kept on this Mac up to the cache size. Remembering folders longer makes browsing faster, but files created on the server show up later.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack(alignment: .top) {
                    StatusDot(status: status).padding(.top, 5)
                    Text(status.label)
                        .foregroundStyle(status.isFailed ? .red : .primary)
                        .textSelection(.enabled)
                }
                if m.needsRemount(id) {
                    Text("Settings changed — remount to apply them.").foregroundStyle(.orange)
                }
                HStack {
                    if m.isWanted(id) {
                        Button("Unmount") { m.unmount(id) }
                        Button("Remount") { m.remount(id) }
                    } else {
                        Button("Mount") { m.mount(id) }.keyboardShortcut(.defaultAction)
                    }
                    Spacer()
                    Button("Show Log") { m.openLog(id) }
                    Button("Open in Finder") { m.openInFinder(id) }.disabled(status != .mounted)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pickHost(_ h: String) {
        var v = c.wrappedValue
        v.host = h
        if v.name.isEmpty || v.name == "New Server" { v.name = h }
        if v.mountPoint == MountConfig().mountPoint { v.mountPoint = "~/Mounts/\(h)" }
        c.wrappedValue = v
        testResult = nil
    }

    private func test() {
        testing = true
        testResult = nil
        let cfg = c.wrappedValue
        Task {
            let r = await m.testConnection(cfg)
            testResult = r
            testing = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Mount Here"
        panel.message = "Choose an empty folder to mount the server in"
        if panel.runModal() == .OK, let url = panel.url {
            c.wrappedValue.mountPoint = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
