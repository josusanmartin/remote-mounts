import AppKit
import Foundation
import Network
import UserNotifications

/// Owns the mount configs and one supervised `rclone nfsmount` process per active mount.
@MainActor
final class MountManager: ObservableObject {
    static let shared = MountManager()

    nonisolated static let supportDir = System.home + "/Library/Application Support/RemoteMounts"
    nonisolated static let logDir = System.home + "/Library/Logs/RemoteMounts"
    nonisolated static let cacheRoot = System.home + "/Library/Caches/RemoteMounts"
    static var configURL: URL { URL(fileURLWithPath: supportDir + "/mounts.json") }

    @Published var configs: [MountConfig] = [] { didSet { save() } }
    @Published private(set) var statuses: [UUID: MountStatus] = [:]
    @Published private(set) var stats: [UUID: MountStats] = [:]
    /// Mounts the user wants up; failed ones in here are retried with backoff.
    @Published private(set) var wanted: Set<UUID> = []
    /// The config each running process was started with, to detect edits that need a remount.
    @Published private(set) var activeConfigs: [UUID: MountConfig] = [:]
    @Published var selection: UUID?
    @Published var showAddSheet = false
    @Published var logSheetFor: UUID?
    @Published var loginItemEnabled = LoginItem.isEnabled { didSet { LoginItem.set(loginItemEnabled) } }
    /// The locked SSH key whose passphrase the unlock window is asking for.
    @Published private(set) var unlockRequest: UnlockRequest?
    /// Mounts that couldn't start because their SSH key is locked.
    @Published private(set) var lockedMounts: Set<UUID> = []

    /// Set by the menu bar label, the one view that can always reach SwiftUI's window actions.
    var showManagerWindow: (() -> Void)?
    var showSettingsWindow: (() -> Void)?
    var showUnlockWindow: (() -> Void)?

    struct UnlockRequest: Identifiable {
        let id = UUID()
        /// Hosts waiting on this key, for the prompt's wording.
        var hosts: [String]
        /// The host's candidate keys; unlocking any one of them is enough.
        let keys: [String]
        fileprivate var completions: [(Bool) -> Void]
    }

    private var processes: [UUID: Process] = [:]
    private var preparing: Set<UUID> = []
    private var startedAt: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    private var retries: [UUID: DispatchWorkItem] = [:]
    private var remountAfterExit: Set<UUID> = []
    /// Mounts waiting for their uploads to finish before they unmount.
    private var unmountWhenIdle: Set<UUID> = []
    private var statsInFlight: Set<UUID> = []
    private var openWhenMounted: Set<UUID> = []
    /// Consecutive "nothing pending" readings for mounts waiting to unmount.
    private var idleChecks: [UUID: Int] = [:]
    private var timers: [Timer] = []
    private var queuedUnlocks: [UnlockRequest] = []
    /// Keys whose prompt was cancelled; background retries don't ask again until the user does something.
    private var declinedKeys: Set<String> = []
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false

    var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true
    }

    private init() {
        for dir in [Self.supportDir, Self.logDir, Self.cacheRoot] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        load()
        for c in configs where c.autoMount { mount(c.id) }
        // .common so they keep running while a modal alert (e.g. the quit prompt) is up
        for (interval, action) in [(1.0, { [weak self] in self?.poll() }),
                                   (2.0, { [weak self] in self?.refreshStats() })] as [(Double, () -> Void)] {
            let t = Timer(timeInterval: interval, repeats: true) { _ in Task { @MainActor in action() } }
            RunLoop.main.add(t, forMode: .common)
            timers.append(t)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(up: path.status == .satisfied) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self?.retryFailedNow()
            }
        }
    }

    // MARK: - Configs

    func config(_ id: UUID) -> MountConfig? { configs.first { $0.id == id } }
    func status(_ id: UUID) -> MountStatus { statuses[id] ?? .unmounted }
    func isWanted(_ id: UUID) -> Bool { wanted.contains(id) }

    var mountedCount: Int { configs.filter { status($0.id).isUp }.count }
    var anyMounted: Bool { mountedCount > 0 }
    var anyFailed: Bool { configs.contains { status($0.id).isFailed } }
    var totalPendingUploads: Int {
        processes.keys.reduce(0) { $0 + (stats[$1]?.pendingUploads ?? 0) }
    }

    func needsRemount(_ id: UUID) -> Bool {
        guard let active = activeConfigs[id], let current = config(id) else { return false }
        var a = active, b = current
        // These don't affect the running process
        a.autoMount = false; b.autoMount = false
        a.name = ""; b.name = ""
        return a != b
    }

    func update(_ c: MountConfig) {
        guard let i = configs.firstIndex(where: { $0.id == c.id }), configs[i] != c else { return }
        var c = c
        let old = configs[i]
        // The mount folder follows the name until the user picks one; a live mount stays where it is
        if c.name != old.name, c.mountPoint == old.mountPoint, old.usesAutoMountPoint, activeConfigs[c.id] == nil {
            c.mountPoint = MountConfig.autoMountPoint(for: c.name)
        }
        configs[i] = c
    }

    /// Adds a server for `host` and selects it; returns its id.
    @discardableResult
    func addServer(host: String, name: String? = nil) -> UUID {
        var c = MountConfig()
        c.host = host
        c.name = uniqueName(name ?? host)
        c.mountPoint = MountConfig.autoMountPoint(for: c.name)
        configs.append(c)
        selection = c.id
        return c.id
    }

    func duplicate(_ id: UUID) {
        guard var c = config(id), let i = configs.firstIndex(where: { $0.id == id }) else { return }
        c.id = UUID()
        c.name = uniqueName(c.name + " copy")
        c.mountPoint = MountConfig.autoMountPoint(for: c.name)
        c.autoMount = false
        configs.insert(c, at: i + 1)
        selection = c.id
    }

    func removeConfig(_ id: UUID) {
        unmount(id, force: true)
        configs.removeAll { $0.id == id }
        statuses[id] = nil
        stats[id] = nil
        if selection == id { selection = configs.first?.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        configs.move(fromOffsets: source, toOffset: destination)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(configs.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let decoded = try? JSONDecoder().decode([MountConfig].self, from: data) else { return }
        configs = decoded
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(configs) { try? data.write(to: Self.configURL, options: .atomic) }
    }

    // MARK: - Mount / unmount

    /// `userInitiated: false` is for background retries, which don't re-ask for a passphrase the user dismissed.
    func mount(_ id: UUID, userInitiated: Bool = true) {
        guard let c = config(id) else { return }
        retries[id]?.cancel()
        retries[id] = nil
        // Toggling back on while uploads drain just cancels the pending unmount
        if unmountWhenIdle.remove(id) != nil, processes[id] != nil {
            wanted.insert(id)
            statuses[id] = .mounted
            return
        }
        if let err = c.validationError {
            wanted.remove(id)
            statuses[id] = .failed(err)
            return
        }
        guard let rclone = System.rclonePath else {
            wanted.remove(id)
            statuses[id] = .failed("rclone isn't installed — run “brew install rclone” in Terminal")
            return
        }
        let mp = c.expandedMountPoint
        if let other = configs.first(where: { $0.id != id && $0.expandedMountPoint == mp && processes[$0.id] != nil }) {
            wanted.remove(id)
            statuses[id] = .failed("\(c.displayMountPoint) is already used by “\(other.displayName)”")
            return
        }
        wanted.insert(id)
        guard processes[id] == nil, !preparing.contains(id) else { return }
        preparing.insert(id)
        statuses[id] = .mounting
        lockedMounts.remove(id)

        let lastPort = lastNFSPort(id)
        Task {
            guard await ensureUnlocked(host: c.host, ask: userInitiated) else {
                preparing.remove(id)
                guard wanted.contains(id) else {
                    if statuses[id] == .mounting { statuses[id] = .unmounted }
                    return
                }
                lockedMounts.insert(id)
                statuses[id] = .failed("Your SSH key is locked — enter its passphrase to connect")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
                // A previous run may have crashed and left the folder mounted or an rclone behind
                if System.mountedPaths().contains(mp) || System.hasOrphan(mountPoint: mp) {
                    System.forceCleanup(mountPoint: mp, lastPort: lastPort)
                }
                Task { @MainActor in
                    self.preparing.remove(id)
                    guard self.wanted.contains(id), let current = self.config(id) else {
                        if self.statuses[id] == .mounting { self.statuses[id] = .unmounted }
                        return
                    }
                    self.launch(current, rclone: rclone)
                }
            }
        }
    }

    // MARK: - Locked SSH keys

    /// Makes sure `host` can log in without a prompt, asking for its key's passphrase if needed.
    /// With `ask: false`, a key whose prompt the user cancelled stays locked without asking again.
    /// Returns false if the key is still locked.
    func ensureUnlocked(host: String, ask: Bool = true) async -> Bool {
        let locked = await Task.detached { SSHKeys.lockedKeys(host: host) }.value
        guard let key = locked.first else { return true }
        if !ask && declinedKeys.contains(key) { return false }
        return await withCheckedContinuation { cont in
            requestUnlock(host: host, keys: locked) { cont.resume(returning: $0) }
        }
    }

    func isWaitingForUnlock(_ id: UUID) -> Bool {
        guard status(id) == .mounting, let host = config(id)?.host else { return false }
        return unlockRequest?.hosts.contains(host) ?? false
    }

    /// Queues a prompt for `keys`; mounts that share a key share one prompt.
    private func requestUnlock(host: String, keys: [String], done: @escaping (Bool) -> Void) {
        func merge(_ r: inout UnlockRequest) -> Bool {
            guard !Set(r.keys).isDisjoint(with: keys) else { return false }
            if !r.hosts.contains(host) { r.hosts.append(host) }
            r.completions.append(done)
            return true
        }
        if var r = unlockRequest, merge(&r) {
            unlockRequest = r
            showUnlockWindow?()
            return
        }
        for i in queuedUnlocks.indices {
            if merge(&queuedUnlocks[i]) { return }
        }
        let r = UnlockRequest(hosts: [host], keys: keys, completions: [done])
        if unlockRequest == nil {
            unlockRequest = r
            showUnlockWindow?()
        } else {
            queuedUnlocks.append(r)
        }
    }

    /// Called by the unlock window.
    func submitUnlock(key: String, passphrase: String, remember: Bool) async -> SSHKeys.UnlockResult {
        let result = await Task.detached { SSHKeys.unlock(key, passphrase: passphrase, remember: remember) }.value
        if result == .unlocked { finishUnlock(true) }
        return result
    }

    func cancelUnlock() { finishUnlock(false) }

    private func finishUnlock(_ ok: Bool) {
        guard let r = unlockRequest else { return }
        if ok { declinedKeys.subtract(r.keys) } else { declinedKeys.formUnion(r.keys) }
        unlockRequest = nil
        r.completions.forEach { $0(ok) }
        presentNextUnlock()
    }

    private func presentNextUnlock() {
        guard unlockRequest == nil, !queuedUnlocks.isEmpty else { return }
        let next = queuedUnlocks.removeFirst()
        Task {
            // The key just unlocked may have been this host's too, under another file name
            let locked = await Task.detached { SSHKeys.lockedKeys(host: next.hosts[0]) }.value
            if locked.isEmpty {
                next.completions.forEach { $0(true) }
            } else if unlockRequest == nil {
                unlockRequest = next
                showUnlockWindow?()
                return
            } else {
                queuedUnlocks.insert(next, at: 0)
                return
            }
            presentNextUnlock()
        }
    }

    private func launch(_ c: MountConfig, rclone: String) {
        let id = c.id
        let logPath = logPath(id)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()
        log?.write("\n=== \(Date()) mounting \(c.remoteDescription) at \(c.displayMountPoint)\n".data(using: .utf8)!)
        try? FileManager.default.removeItem(atPath: socketPath(id))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        p.arguments = rcloneArgs(c)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.processExited(id, proc, code: code) }
        }
        do {
            try p.run()
        } catch {
            statuses[id] = .failed("Couldn't start rclone: \(error.localizedDescription)")
            wanted.remove(id)
            return
        }
        processes[id] = p
        activeConfigs[id] = c
        startedAt[id] = Date()
    }

    func socketPath(_ id: UUID) -> String {
        // Unix socket paths are limited to 104 bytes, so keep this short
        Self.cacheRoot + "/rc-" + id.uuidString.prefix(8) + ".sock"
    }

    func rcloneArgs(_ c: MountConfig) -> [String] {
        let ssh = "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \(c.host)"
        var a = [
            "nfsmount", ":sftp:\(c.rcloneRemotePath)", c.expandedMountPoint,
            "--sftp-ssh", ssh,
            "--sftp-shell-type", "unix",
            // Without these, every file open runs md5sum over a fresh ssh login (~3 s on a slow link)
            "--sftp-md5sum-command", "none", "--sftp-sha1sum-command", "none",
            // Stay well below sshd's default MaxStartups (10) and keep connections open
            "--sftp-connections", "16", "--sftp-idle-timeout", "0", "--sftp-chunk-size", "255k",
            "--volname", c.displayName,
            "--vfs-cache-mode", "full", "--vfs-cache-max-age", "24h",
            "--vfs-cache-max-size", "\(c.cacheSizeGB)G", "--vfs-fast-fingerprint",
            "--dir-cache-time", "\(max(1, c.dirCacheMinutes))m", "--attr-timeout", "10s",
            "--cache-dir", Self.cacheRoot + "/" + c.id.uuidString,
            "--rc", "--rc-no-auth", "--rc-addr", "unix://" + socketPath(c.id),
            "--log-file", logPath(c.id), "--log-level", "NOTICE",
        ]
        let knownHosts = System.home + "/.ssh/known_hosts"
        if FileManager.default.fileExists(atPath: knownHosts) { a += ["--sftp-known-hosts-file", knownHosts] }
        if c.readOnly { a.append("--read-only") }
        a += c.extraFlags.split(whereSeparator: \.isWhitespace).map(String.init)
        return a
    }

    /// The rclone command line, shell-quoted, for display and copying.
    func commandLine(_ c: MountConfig) -> String {
        let args = rcloneArgs(c).map { arg in
            arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@,+".contains($0) } ? arg : System.shellQuote(arg)
        }
        return ([System.rclonePath ?? "rclone"] + args).joined(separator: " ")
    }

    /// Fetches upload counts from every running rclone right away (a local socket call, a few ms).
    /// Returns the mounts that didn't answer: rclone can be slow while it takes in a big write,
    /// so callers must treat those as still busy, not as idle.
    @discardableResult
    func refreshStatsNow(_ only: UUID? = nil) -> Set<UUID> {
        var silent = Set<UUID>()
        for (id, p) in processes where p.isRunning && (only == nil || only == id) {
            guard let vfs = RCClient.call(socketPath: socketPath(id), "vfs/stats", timeout: 3) else {
                silent.insert(id)
                continue
            }
            stats[id] = MountStats(vfs: vfs, core: RCClient.call(socketPath: socketPath(id), "core/stats", timeout: 3))
        }
        return silent
    }

    /// Unmounts, first letting pending uploads finish unless `force` is set.
    func unmount(_ id: UUID, force: Bool = false) {
        openWhenMounted.remove(id)
        lockedMounts.remove(id)
        retries[id]?.cancel()
        retries[id] = nil
        failures[id] = 0
        remountAfterExit.remove(id)
        wanted.remove(id)
        guard !force, processes[id] != nil, !unmountWhenIdle.contains(id) else {
            stopProcess(id)
            return
        }
        statuses[id] = .unmounting
        // Push the Mac's buffered NFS writes into rclone first, so its upload counts are complete
        DispatchQueue.global(qos: .userInitiated).async {
            System.flushWrites()
            Task { @MainActor in
                guard !self.wanted.contains(id) else {  // switched back on meanwhile
                    if self.processes[id] != nil { self.statuses[id] = .mounted }
                    return
                }
                let silent = !self.refreshStatsNow(id).isEmpty
                let pending = self.stats[id]?.pendingUploads ?? 0
                if pending > 0 || silent {
                    self.unmountWhenIdle.insert(id)
                    self.idleChecks[id] = 0
                    self.statuses[id] = .finishingUploads(max(pending, 1))
                } else {
                    self.stopProcess(id)
                }
            }
        }
    }

    /// Unmounts through the running rclone, then stops it.
    private func stopProcess(_ id: UUID) {
        unmountWhenIdle.remove(id)
        let mp = activeConfigs[id]?.expandedMountPoint ?? config(id)?.expandedMountPoint
        guard let p = processes[id] else {
            if !preparing.contains(id) { statuses[id] = .unmounted }
            return
        }
        statuses[id] = .unmounting
        let lastPort = lastNFSPort(id)
        DispatchQueue.global(qos: .userInitiated).async {
            // Unmount while rclone still answers, then stop it
            if let mp { System.unmountServed(mp) }
            p.terminate()
            for _ in 0..<50 where p.isRunning { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            if let mp, System.mountedPaths().contains(mp) { System.rescueStaleMount(mp, port: lastPort) }
        }
    }

    func remount(_ id: UUID) {
        guard processes[id] != nil else { mount(id); return }
        stopProcess(id)
        remountAfterExit.insert(id)
    }

    /// Mounts if needed, then opens the folder in Finder once it's up.
    func mountAndOpen(_ id: UUID) {
        if status(id).isUp { openInFinder(id); return }
        openWhenMounted.insert(id)
        mount(id)
    }

    func showLog(_ id: UUID) {
        selection = id
        logSheetFor = id
        showManagerWindow?()
    }

    func mountAll() { configs.forEach { mount($0.id) } }
    func unmountAll() { configs.forEach { unmount($0.id) } }

    /// Skips the backoff wait for every failed mount, e.g. after the network comes back.
    func retryFailedNow() {
        for id in wanted where processes[id] == nil && !preparing.contains(id) { mount(id, userInitiated: false) }
    }

    private func networkChanged(up: Bool) {
        if up && networkWasDown { retryFailedNow() }
        networkWasDown = !up
    }

    private func processExited(_ id: UUID, _ proc: Process, code: Int32) {
        guard processes[id] === proc else { return }
        let mp = activeConfigs[id]?.expandedMountPoint
        let wasUp = status(id).isUp
        processes[id] = nil
        activeConfigs[id] = nil
        startedAt[id] = nil
        stats[id] = nil
        unmountWhenIdle.remove(id)
        if let mp, System.mountedPaths().contains(mp) {
            let lastPort = lastNFSPort(id)
            DispatchQueue.global().async { System.rescueStaleMount(mp, port: lastPort) }
        }
        if remountAfterExit.remove(id) != nil {
            statuses[id] = .unmounted
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.mount(id) }
            return
        }
        guard wanted.contains(id) else {
            statuses[id] = .unmounted
            return
        }
        let n = (failures[id] ?? 0) + 1
        failures[id] = n
        let delay = [5, 10, 30, 60][min(n - 1, 3)]
        let reason = lastError(id) ?? "rclone stopped unexpectedly (code \(code))"
        statuses[id] = .failed(reason)
        if n == 1, let name = config(id)?.displayName {
            notify(wasUp ? "\(name) disconnected" : "Couldn't mount \(name)",
                   wasUp ? "\(reason). Reconnecting…" : "\(reason). Retrying in \(delay) s.")
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted.contains(id) else { return }
                self.mount(id, userInitiated: false)
            }
        }
        retries[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }

    private func poll() {
        let mounted = System.mountedPaths()
        for (id, p) in processes where p.isRunning {
            guard let mp = activeConfigs[id]?.expandedMountPoint else { continue }
            if mounted.contains(mp) {
                if statuses[id] == .mounting || status(id).isFailed {
                    statuses[id] = .mounted
                    if (failures[id] ?? 0) > 0, let name = config(id)?.displayName {
                        notify("\(name) reconnected", "Mounted again at \(activeConfigs[id]?.displayMountPoint ?? mp).")
                    }
                    failures[id] = 0
                    if openWhenMounted.remove(id) != nil { openInFinder(id) }
                }
            } else if statuses[id] == .mounting, let s = startedAt[id], Date().timeIntervalSince(s) > 60 {
                // Kill it; the exit handler reports the error and schedules a retry
                p.terminate()
            }
        }
    }

    private func refreshStats() {
        for (id, p) in processes where p.isRunning && status(id).isUp && !statsInFlight.contains(id) {
            statsInFlight.insert(id)
            let sock = socketPath(id)
            DispatchQueue.global(qos: .utility).async {
                let vfs = RCClient.call(socketPath: sock, "vfs/stats")
                let core = vfs == nil ? nil : RCClient.call(socketPath: sock, "core/stats")
                Task { @MainActor in
                    self.statsInFlight.remove(id)
                    guard self.processes[id] === p, let vfs else { return }
                    let s = MountStats(vfs: vfs, core: core)
                    let old = self.stats[id]
                    if old != s { self.stats[id] = s }
                    if s.erroredFiles > (old?.erroredFiles ?? 0), let name = self.config(id)?.displayName {
                        self.notify("Upload failed on \(name)", "\(s.erroredFiles) file(s) couldn't be uploaded. rclone will keep retrying; see the log.")
                    }
                    if self.unmountWhenIdle.contains(id) {
                        // Two empty readings in a row, so a file between upload steps isn't missed
                        let checks = s.pendingUploads == 0 ? (self.idleChecks[id] ?? 0) + 1 : 0
                        self.idleChecks[id] = checks
                        if checks >= 2 {
                            self.stopProcess(id)
                        } else if s.pendingUploads > 0 {
                            self.statuses[id] = .finishingUploads(s.pendingUploads)
                        }
                    }
                }
            }
        }
    }

    /// Called from applicationWillTerminate: unmount everything through the running rclones, then stop them.
    func shutdown() {
        timers.forEach { $0.invalidate() }
        pathMonitor.cancel()
        retries.values.forEach { $0.cancel() }
        wanted.removeAll()
        let running = processes.map { (id: $0.key, process: $0.value,
                                       mountPoint: activeConfigs[$0.key]?.expandedMountPoint,
                                       port: lastNFSPort($0.key)) }
        let group = DispatchGroup()
        for r in running {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                if let mp = r.mountPoint { System.unmountServed(mp) }
                r.process.terminate()
            }
        }
        _ = group.wait(timeout: .now() + 20)
        let deadline = Date().addingTimeInterval(3)
        while running.contains(where: { $0.process.isRunning }) && Date() < deadline { usleep(100_000) }
        for r in running {
            if r.process.isRunning { kill(r.process.processIdentifier, SIGKILL) }
            if let mp = r.mountPoint, System.mountedPaths().contains(mp) {
                System.rescueStaleMount(mp, port: r.port)
            }
        }
    }

    // MARK: - Notifications

    private func notify(_ title: String, _ body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Logs, Finder, Terminal

    func logPath(_ id: UUID) -> String { Self.logDir + "/\(id.uuidString).log" }

    /// Last ERROR/CRITICAL line from the mount's log, made readable.
    private func lastError(_ id: UUID) -> String? {
        let tail = readLogTail(id, maxBytes: 6000)
        // Only look at the latest run
        let run = tail.components(separatedBy: "\n=== ").last ?? tail
        let lines = run.split(separator: "\n").map(String.init)
        if let host = config(id)?.host, let friendly = System.friendlyError(lines.suffix(15).joined(separator: "\n"), host: host) {
            return friendly
        }
        guard let line = lines.last(where: { $0.contains("ERROR") || $0.contains("CRITICAL") || $0.contains("Fatal") })
        else { return nil }
        var s = line
        if let r = s.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} "#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }

    /// The port the latest rclone run for this mount served NFS on, from its log.
    func lastNFSPort(_ id: UUID) -> Int? {
        let tail = readLogTail(id, maxBytes: 20_000)
        guard let r = tail.range(of: #"NFS Server running at 127\.0\.0\.1:(\d+)"#, options: [.regularExpression, .backwards])
        else { return nil }
        return Int(tail[r].split(separator: ":").last ?? "")
    }

    func readLogTail(_ id: UUID, maxBytes: UInt64 = 64_000) -> String {
        guard let h = FileHandle(forReadingAtPath: logPath(id)) else { return "" }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > maxBytes ? size - maxBytes : 0)
        var text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        if size > maxBytes, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }

    func clearLog(_ id: UUID) {
        try? Data().write(to: URL(fileURLWithPath: logPath(id)))
    }

    func openLogInConsole(_ id: UUID) {
        let path = logPath(id)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openInFinder(_ id: UUID) {
        guard let c = config(id), status(id).isUp else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: c.expandedMountPoint))
    }

    func openTerminal(_ id: UUID) {
        guard let c = config(id), c.validationError == nil else { return }
        System.openTerminal(host: c.host, remotePath: c.rcloneRemotePath)
    }

    func copyPath(_ id: UUID) {
        guard let c = config(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.expandedMountPoint, forType: .string)
    }

    func testConnection(_ c: MountConfig) async -> (ok: Bool, message: String) {
        let host = c.host
        let path = c.rcloneRemotePath
        guard await ensureUnlocked(host: host) else { return (false, "Your SSH key is locked") }
        return await Task.detached {
            let check = path.isEmpty ? "echo __ok" : "test -d \(System.shellQuote(path)) && echo __ok || echo __nofolder"
            let cmd = "\(check); command -v sftp-server >/dev/null 2>&1 || ls /usr/lib/openssh/sftp-server /usr/libexec/sftp-server /usr/lib/ssh/sftp-server >/dev/null 2>&1 || echo __nosftp"
            let (code, out) = System.run("/usr/bin/ssh", System.quickSSHArgs(host, cmd), timeout: 25)
            if out.contains("__nofolder") { return (false, "Connected, but the remote folder doesn't exist") }
            if out.contains("__ok") {
                return (true, out.contains("__nosftp") ? "Connected (couldn't confirm SFTP is enabled)" : "Connected")
            }
            if let friendly = System.friendlyError(out, host: host) { return (false, friendly) }
            let lastLine = out.split(separator: "\n").last.map(String.init) ?? "ssh exited with \(code)"
            return (false, lastLine)
        }.value
    }
}

