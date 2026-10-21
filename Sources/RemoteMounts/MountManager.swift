import AppKit
import Foundation

/// Owns the mount configs and one supervised `rclone nfsmount` process per active mount.
@MainActor
final class MountManager: ObservableObject {
    static let shared = MountManager()

    static let supportDir = System.home + "/Library/Application Support/RemoteMounts"
    static let logDir = System.home + "/Library/Logs/RemoteMounts"
    static let cacheRoot = System.home + "/Library/Caches/RemoteMounts"
    static var configURL: URL { URL(fileURLWithPath: supportDir + "/mounts.json") }

    @Published var configs: [MountConfig] = [] { didSet { save() } }
    @Published private(set) var statuses: [UUID: MountStatus] = [:]
    /// Mounts the user wants up; failed ones in here are retried with backoff.
    @Published private(set) var wanted: Set<UUID> = []
    @Published var selection: UUID?
    @Published var loginItemEnabled = LoginItem.isEnabled { didSet { LoginItem.set(loginItemEnabled) } }

    /// Set by the menu bar label, which is the one view that can reach SwiftUI's openWindow.
    var showManagerWindow: (() -> Void)?

    private var processes: [UUID: Process] = [:]
    /// The config each running process was started with, to detect edits that need a remount.
    @Published private(set) var activeConfigs: [UUID: MountConfig] = [:]
    private var preparing: Set<UUID> = []
    private var startedAt: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    private var retries: [UUID: DispatchWorkItem] = [:]
    private var remountAfterExit: Set<UUID> = []
    private var pollTimer: Timer?

    private init() {
        for dir in [Self.supportDir, Self.logDir, Self.cacheRoot] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        load()
        for c in configs where c.autoMount { mount(c.id) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: - Configs

    func config(_ id: UUID) -> MountConfig? { configs.first { $0.id == id } }
    func status(_ id: UUID) -> MountStatus { statuses[id] ?? .unmounted }
    func isWanted(_ id: UUID) -> Bool { wanted.contains(id) }

    var anyMounted: Bool { statuses.values.contains(.mounted) }
    var anyFailed: Bool { statuses.values.contains { $0.isFailed } }

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
        configs[i] = c
    }

    @discardableResult
    func addConfig() -> UUID {
        var c = MountConfig()
        c.autoMount = false
        configs.append(c)
        selection = c.id
        return c.id
    }

    func removeConfig(_ id: UUID) {
        unmount(id)
        configs.removeAll { $0.id == id }
        statuses[id] = nil
        if selection == id { selection = configs.first?.id }
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

    func mount(_ id: UUID) {
        guard let c = config(id) else { return }
        retries[id]?.cancel()
        retries[id] = nil
        if let err = c.validationError {
            wanted.remove(id)
            statuses[id] = .failed(err)
            return
        }
        guard let rclone = System.rclonePath else {
            wanted.remove(id)
            statuses[id] = .failed("rclone not found — run: brew install rclone")
            return
        }
        let mp = c.expandedMountPoint
        if let other = configs.first(where: { $0.id != id && $0.expandedMountPoint == mp && processes[$0.id] != nil }) {
            wanted.remove(id)
            statuses[id] = .failed("\(c.displayMountPoint) is already used by “\(other.name)”")
            return
        }
        wanted.insert(id)
        guard processes[id] == nil, !preparing.contains(id) else { return }
        preparing.insert(id)
        statuses[id] = .mounting

        let logPath = logPath(id)
        let cacheDir = Self.cacheRoot + "/" + id.uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
            // A previous run may have crashed and left the folder mounted or an rclone behind
            if System.mountedPaths().contains(mp) || System.hasOrphan(mountPoint: mp) {
                System.forceCleanup(mountPoint: mp)
            }
            Task { @MainActor in
                self.preparing.remove(id)
                guard self.wanted.contains(id), let current = self.config(id) else {
                    if self.statuses[id] == .mounting { self.statuses[id] = .unmounted }
                    return
                }
                self.launch(current, rclone: rclone, logPath: logPath, cacheDir: cacheDir)
            }
        }
    }

    private func launch(_ c: MountConfig, rclone: String, logPath: String, cacheDir: String) {
        let id = c.id
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()
        log?.write("\n=== \(Date()) mounting \(c.remoteDescription) at \(c.displayMountPoint)\n".data(using: .utf8)!)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        p.arguments = Self.rcloneArgs(c, logPath: logPath, cacheDir: cacheDir)
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

    static func rcloneArgs(_ c: MountConfig, logPath: String, cacheDir: String) -> [String] {
        let ssh = "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \(c.host)"
        var a = [
            "nfsmount", ":sftp:\(c.rcloneRemotePath)", c.expandedMountPoint,
            "--sftp-ssh", ssh,
            "--sftp-shell-type", "unix",
            // Without these, every file open runs md5sum over a fresh ssh login (~3 s on a slow link)
            "--sftp-md5sum-command", "none", "--sftp-sha1sum-command", "none",
            // Stay well below sshd's default MaxStartups (10) and keep connections open
            "--sftp-connections", "16", "--sftp-idle-timeout", "0", "--sftp-chunk-size", "255k",
            "--volname", c.name,
            "--vfs-cache-mode", "full", "--vfs-cache-max-age", "24h",
            "--vfs-cache-max-size", "\(c.cacheSizeGB)G", "--vfs-fast-fingerprint",
            "--dir-cache-time", "\(max(1, c.dirCacheMinutes))m", "--attr-timeout", "10s",
            "--cache-dir", cacheDir,
            "--log-file", logPath, "--log-level", "NOTICE",
        ]
        let knownHosts = System.home + "/.ssh/known_hosts"
        if FileManager.default.fileExists(atPath: knownHosts) { a += ["--sftp-known-hosts-file", knownHosts] }
        if c.readOnly { a.append("--read-only") }
        a += c.extraFlags.split(whereSeparator: \.isWhitespace).map(String.init)
        return a
    }

    func unmount(_ id: UUID) {
        wanted.remove(id)
        retries[id]?.cancel()
        retries[id] = nil
        failures[id] = 0
        remountAfterExit.remove(id)
        let mp = activeConfigs[id]?.expandedMountPoint ?? config(id)?.expandedMountPoint
        guard let p = processes[id] else {
            if !preparing.contains(id) { statuses[id] = .unmounted }
            return
        }
        statuses[id] = .unmounting
        p.terminate()  // rclone unmounts itself on SIGTERM
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            if let mp, System.mountedPaths().contains(mp) { System.forceCleanup(mountPoint: mp) }
        }
    }

    func remount(_ id: UUID) {
        guard processes[id] != nil else { mount(id); return }
        unmount(id)
        remountAfterExit.insert(id)
    }

    func mountAll() { configs.forEach { mount($0.id) } }
    func unmountAll() { configs.forEach { unmount($0.id) } }

    private func processExited(_ id: UUID, _ proc: Process, code: Int32) {
        guard processes[id] === proc else { return }
        let mp = activeConfigs[id]?.expandedMountPoint
        processes[id] = nil
        activeConfigs[id] = nil
        startedAt[id] = nil
        if let mp, System.mountedPaths().contains(mp) {
            DispatchQueue.global().async { System.forceCleanup(mountPoint: mp) }
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
        let reason = lastError(id) ?? "rclone exited (code \(code))"
        statuses[id] = .failed("\(reason) — retrying in \(delay)s")
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted.contains(id) else { return }
                self.mount(id)
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
                if statuses[id] != .mounted && statuses[id] != .unmounting {
                    statuses[id] = .mounted
                    failures[id] = 0
                }
            } else if statuses[id] == .mounting, let s = startedAt[id], Date().timeIntervalSince(s) > 60 {
                // Kill it; the exit handler reports the error and schedules a retry
                p.terminate()
            }
        }
    }

    /// Called from applicationWillTerminate: stop every rclone and make sure nothing stays mounted.
    func shutdown() {
        pollTimer?.invalidate()
        let running = processes
        wanted.removeAll()
        retries.values.forEach { $0.cancel() }
        for p in running.values { p.terminate() }
        let deadline = Date().addingTimeInterval(4)
        while running.values.contains(where: \.isRunning) && Date() < deadline { usleep(100_000) }
        for (id, p) in running {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            if let mp = activeConfigs[id]?.expandedMountPoint, System.mountedPaths().contains(mp) {
                System.forceCleanup(mountPoint: mp)
            }
        }
    }

    // MARK: - Logs and Finder

    func logPath(_ id: UUID) -> String { Self.logDir + "/\(id.uuidString).log" }

    /// Last ERROR/CRITICAL line from the mount's log, without the timestamp.
    private func lastError(_ id: UUID) -> String? {
        guard let h = FileHandle(forReadingAtPath: logPath(id)) else { return nil }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 4096 ? size - 4096 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: {
            $0.contains("ERROR") || $0.contains("CRITICAL") || $0.contains("Fatal")
        }) else { return nil }
        var s = String(line)
        if let r = s.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} "#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }

    func openLog(_ id: UUID) {
        let path = logPath(id)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openInFinder(_ id: UUID) {
        guard let c = config(id) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: c.expandedMountPoint))
    }

    func testConnection(_ c: MountConfig) async -> (ok: Bool, message: String) {
        let host = c.host
        let path = c.rcloneRemotePath
        return await Task.detached {
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let cmd = path.isEmpty ? "echo __ok" : "test -d \(quoted) && echo __ok || echo __nofolder"
            let (code, out) = System.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, cmd],
                                         timeout: 20)
            if out.contains("__ok") { return (true, "Connected") }
            if out.contains("__nofolder") { return (false, "Connected, but the remote folder doesn't exist") }
            if code == -2 { return (false, "Timed out") }
            let lastLine = out.split(separator: "\n").last.map(String.init) ?? "ssh exited with \(code)"
            return (false, lastLine)
        }.value
    }
}
