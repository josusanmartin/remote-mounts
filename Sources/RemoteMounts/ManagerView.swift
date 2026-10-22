import AppKit
import SwiftUI

private struct LogTarget: Identifiable { let id: UUID }

struct ManagerView: View {
    @EnvironmentObject var m: MountManager
    @State private var pendingDelete: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            if let id = m.selection, m.config(id) != nil {
                ServerDetail(id: id, onDelete: { pendingDelete = id }).id(id)
            } else {
                ContentUnavailableView {
                    Label("No Server Selected", systemImage: "server.rack")
                } description: {
                    Text("Mount any host from your SSH config as a folder on this Mac.")
                } actions: {
                    Button("Add a Server…") { m.showAddSheet = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { m.showAddSheet = true } label: { Label("Add Server", systemImage: "plus") }
                    .help("Add a server (⌘N)")
            }
        }
        .sheet(isPresented: $m.showAddSheet) { AddServerSheet().environmentObject(m) }
        .sheet(item: Binding(get: { m.logSheetFor.map(LogTarget.init) },
                             set: { m.logSheetFor = $0?.id })) { t in
            LogSheet(id: t.id).environmentObject(m)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                              set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let id = pendingDelete { m.removeConfig(id) }
                pendingDelete = nil
            }
        } message: {
            Text("It will be unmounted. Nothing on the server is deleted.")
        }
        .onAppear {
            if m.selection == nil { m.selection = m.configs.first?.id }
            // Behave like a normal app (Dock icon, ⌘-Tab, menu bar) while the window is open
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            if !UserDefaults.standard.bool(forKey: "showInDock") { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private var deleteTitle: String {
        "Remove “\(pendingDelete.flatMap { m.config($0)?.displayName } ?? "server")”?"
    }

    private var sidebar: some View {
        List(selection: $m.selection) {
            Section("Servers") {
                ForEach(m.configs) { c in
                    SidebarRow(config: c)
                        .tag(c.id)
                        .contextMenu {
                            MountActions(id: c.id, includeEdit: false)
                            Divider()
                            Button("Duplicate") { m.duplicate(c.id) }
                            Button("Remove…") { pendingDelete = c.id }
                        }
                }
                .onMove { m.move(from: $0, to: $1) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 2) {
                    Button { m.showAddSheet = true } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add a server")
                    Button {
                        if let id = m.selection { pendingDelete = id }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(m.selection == nil)
                    .help("Remove the selected server")
                    Spacer()
                    Button { m.showSettingsWindow?() } label: {
                        Image(systemName: "gearshape").frame(width: 24, height: 20)
                    }
                    .help("Settings (⌘,)")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject var m: MountManager
    let config: MountConfig

    var body: some View {
        let status = m.status(config.id)
        HStack(spacing: 9) {
            ServerIcon(status: status, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.displayName).lineLimit(1)
                Text(status.isFailed ? "Problem" : (status.isUp ? "Mounted" : config.host.isEmpty ? "No host" : config.host))
                    .font(.caption)
                    .foregroundStyle(status.isFailed ? .red : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Server detail

struct ServerDetail: View {
    @EnvironmentObject var m: MountManager
    let id: UUID
    let onDelete: () -> Void

    @State private var hosts = System.sshHosts()
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var browsing = false
    @State private var showAdvanced = false

    private var c: Binding<MountConfig> {
        Binding(get: { m.config(id) ?? MountConfig() }, set: { m.update($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
        }
        .sheet(isPresented: $browsing) {
            RemoteFolderBrowser(host: c.wrappedValue.host, start: c.wrappedValue.rcloneRemotePath) { chosen in
                c.wrappedValue.remotePath = chosen
            }
        }
    }

    // MARK: Header

    private var header: some View {
        let status = m.status(id)
        return HStack(alignment: .center, spacing: 14) {
            ServerIcon(status: status, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.wrappedValue.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusDot(status: status)
                    Text(headerStatus(status))
                        .font(.callout)
                        .foregroundStyle(status.isFailed ? .red : .secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            primaryButton(status)
            Menu {
                MountActions(id: id, includeEdit: false)
                Divider()
                Button("Duplicate") { m.duplicate(id) }
                Button("Remove…", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func headerStatus(_ status: MountStatus) -> String {
        switch status {
        case .mounted: return "Mounted at \(c.wrappedValue.displayMountPoint)"
        case .mounting:
            return m.isWaitingForUnlock(id) ? "Waiting for your SSH key's passphrase…" : "Connecting to \(c.wrappedValue.host)…"
        case .unmounted: return "Not mounted"
        default: return status.label
        }
    }

    @ViewBuilder
    private func primaryButton(_ status: MountStatus) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .finishingUploads:
                Button("Unmount Now") { m.unmount(id, force: true) }
                    .help("Stop waiting; the uploads resume the next time you mount")
            case .mounting:
                Button("Cancel") { m.unmount(id, force: true) }
            case .failed where m.isWanted(id):
                Button("Stop") { m.unmount(id) }
                Button(m.lockedMounts.contains(id) ? "Unlock…" : "Retry Now") { m.mount(id) }.buttonStyle(.borderedProminent)
            case .mounted:
                Button("Open in Finder") { m.openInFinder(id) }
                Button("Unmount") { m.unmount(id) }
            case .unmounting:
                Button("Unmounting…") {}.disabled(true)
            default:
                Button("Mount") { m.mount(id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    // MARK: Form

    private var form: some View {
        let status = m.status(id)
        let cfg = c.wrappedValue
        return Form {
            if m.needsRemount(id) {
                Section {
                    HStack {
                        Label("You changed settings that apply on the next mount.", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Remount Now") { m.remount(id) }
                    }
                }
            }

            Section {
                TextField("Name", text: c.name, prompt: Text("shown in the menu and Finder"))
                HStack {
                    TextField("SSH host", text: c.host, prompt: Text("alias or user@host"))
                    Menu {
                        if hosts.isEmpty { Text("No hosts in ~/.ssh/config") }
                        ForEach(hosts) { h in
                            Button { pickHost(h.alias) } label: {
                                if let d = h.detail { Text("\(h.alias)  —  \(d)") } else { Text(h.alias) }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pick a host from ~/.ssh/config")
                }
                HStack {
                    TextField("Remote folder", text: c.remotePath, prompt: Text("home folder"))
                    Button("Browse…") { browsing = true }
                        .disabled(cfg.validationError != nil)
                }
                HStack(spacing: 10) {
                    Button(testing ? "Testing…" : "Test Connection") { test() }
                        .disabled(testing || cfg.host.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? .green : .red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                if let d = hosts.first(where: { $0.alias == cfg.host })?.detail {
                    Text("Connects to \(d) with your normal SSH keys.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Uses your normal SSH keys. Leave the folder empty for your home folder, or use / for the whole server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("Mount at", text: c.mountPoint)
                    Button("Choose…") { chooseFolder() }
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath:
                            (cfg.expandedMountPoint as NSString).deletingLastPathComponent)
                    } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                        .help("Show the parent folder in Finder")
                }
                if let warning = mountFolderWarning(cfg, status: status) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Mount automatically when Remote Mounts starts", isOn: c.autoMount)
                Toggle("Read-only", isOn: c.readOnly)
            } header: {
                Text("On This Mac")
            } footer: {
                Text("“Mount at” follows the server's name until you choose another folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if status.isUp {
                activitySection
            }

            Section {
                Stepper(value: c.cacheSizeGB, in: 1...500) {
                    LabeledContent("Keep opened files up to", value: "\(cfg.cacheSizeGB) GB")
                }
                Stepper(value: c.dirCacheMinutes, in: 1...240) {
                    LabeledContent("Remember folder contents for", value: "\(cfg.dirCacheMinutes) min")
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("Files you open are kept on this Mac, so opening them again is instant. Remembering folders longer makes browsing faster, but new files created on the server show up later.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    TextField("Extra rclone flags", text: c.extraFlags, prompt: Text("e.g. --vfs-read-ahead 64M"))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Command").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(m.commandLine(cfg), forType: .string)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        Text(m.commandLine(cfg))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Show Log") { m.showLog(id) }
                        Button("Reveal Cache Folder") {
                            let path = MountManager.cacheRoot + "/" + id.uuidString
                            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        }
                    }
                }
            }

            Section {
                Button("Remove Server…", role: .destructive) { onDelete() }
            } footer: {
                Text("Removing a server only forgets it here; nothing on the server is touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var activitySection: some View {
        let s = m.stats[id] ?? MountStats()
        let cfg = c.wrappedValue
        let limit = Int64(cfg.cacheSizeGB) * 1_000_000_000
        return Section("Activity") {
            LabeledContent("Uploads") {
                if s.pendingUploads == 0 {
                    Text("All changes uploaded").foregroundStyle(.secondary)
                } else {
                    Text("\(s.uploadsInProgress) in progress, \(s.uploadsQueued) waiting")
                }
            }
            ForEach(s.transferring) { t in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(t.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Format.bytes(t.bytes)) of \(Format.bytes(t.size)) · \(Format.speed(t.speed))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView(value: Double(t.percentage), total: 100)
                }
            }
            if s.erroredFiles > 0 {
                HStack {
                    Label("\(s.erroredFiles) file\(s.erroredFiles == 1 ? "" : "s") failed to upload; rclone keeps retrying.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Show Log") { m.showLog(id) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Local cache") {
                    Text("\(Format.bytes(s.cacheBytes)) of \(cfg.cacheSizeGB) GB · \(s.cachedFiles) files")
                        .monospacedDigit()
                }
                ProgressView(value: Double(min(s.cacheBytes, limit)), total: Double(max(limit, 1)))
            }
            LabeledContent("Folders remembered", value: "\(s.cachedFolders)")
        }
    }

    private func mountFolderWarning(_ cfg: MountConfig, status: MountStatus) -> String? {
        let path = cfg.expandedMountPoint
        guard !status.isUp, !System.mountedPaths().contains(path) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return "A file already exists at this path" }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter { $0 != ".DS_Store" } ?? []
        return contents.isEmpty ? nil : "This folder isn't empty — its files are hidden while the server is mounted"
    }

    private func pickHost(_ h: String) {
        var v = c.wrappedValue
        v.host = h
        if v.name.isEmpty || v.name == "New Server" { v.name = h }
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
        panel.message = "Choose an empty folder to show the server in"
        if panel.runModal() == .OK, let url = panel.url {
            c.wrappedValue.mountPoint = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

// MARK: - Add server

struct AddServerSheet: View {
    @EnvironmentObject var m: MountManager
    @Environment(\.dismiss) private var dismiss
    @State private var hosts = System.sshHosts()
    @State private var search = ""
    @State private var selected: String?
    @State private var custom = ""
    /// Hosts whose SSH key needs a passphrase that isn't unlocked yet.
    @State private var lockedHosts: Set<String> = []

    private var filtered: [SSHHost] {
        guard !search.isEmpty else { return hosts }
        return hosts.filter {
            $0.alias.localizedCaseInsensitiveContains(search)
                || ($0.hostName?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var chosenHost: String? {
        let typed = custom.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? selected : typed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Server").font(.title2.weight(.semibold))
                    Text("Pick a host from your SSH config. Remote Mounts logs in with your normal SSH keys.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(hosts.count) hosts", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))

            List(filtered, selection: $selected) { h in
                let added = m.configs.contains { $0.host == h.alias }
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.alias)
                        if let d = h.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if lockedHosts.contains(h.alias) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Its SSH key has a passphrase; you'll be asked for it once")
                    }
                    if added {
                        Text("Added").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(h.alias)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    selected = h.alias
                    custom = ""
                    add(mount: true)
                })
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .onChange(of: selected) { if selected != nil { custom = "" } }

            HStack {
                Text("Or connect to")
                TextField("user@hostname", text: $custom)
                    .onChange(of: custom) { if !custom.isEmpty { selected = nil } }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add(mount: false) }.disabled(chosenHost == nil)
                Button("Add & Mount") { add(mount: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenHost == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 560)
        .task {
            let aliases = hosts.map(\.alias)
            lockedHosts = await Task.detached {
                SSHKeys.loadFromKeychain()
                let loaded = SSHKeys.agentFingerprints()
                return Set(aliases.filter { !SSHKeys.lockedKeys(host: $0, loaded: loaded).isEmpty })
            }.value
        }
    }

    private func add(mount: Bool) {
        guard let host = chosenHost else { return }
        let id = m.addServer(host: host)
        if mount {
            m.mount(id)
        } else {
            // Ask for a locked key's passphrase now, while the user is setting things up
            Task { await m.ensureUnlocked(host: host) }
        }
        dismiss()
    }
}
