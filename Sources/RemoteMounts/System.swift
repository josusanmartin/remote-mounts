import AppKit
import Foundation

/// Small wrappers around the OS: mount table, child commands, ssh, ~/.ssh/config, login item.
enum System {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var rclonePath: String? {
        ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func rcloneVersion() -> String? {
        guard let rclone = rclonePath else { return nil }
        let (code, out) = run(rclone, ["version"], timeout: 10)
        guard code == 0 else { return nil }
        return out.split(separator: "\n").first.map { $0.replacingOccurrences(of: "rclone ", with: "") }
    }

    /// Paths currently mounted. MNT_NOWAIT so a dead NFS mount can't block us.
    static func mountedPaths() -> Set<String> {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        var out = Set<String>()
        for i in 0..<Int(n) {
            let path = withUnsafeBytes(of: buf[i].f_mntonname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            out.insert(path)
        }
        return out
    }

    /// Runs a command and returns (exit code, combined output); gives up after `timeout`.
    /// Output goes through a temp file, not a pipe: a backgrounded ssh ControlMaster
    /// inherits the pipe and would keep it open forever.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10,
                    environment: [String: String]? = nil) -> (Int32, String) {
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outURL) else { return (-1, "can't create a temp file") }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: outURL)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        var code = p.terminationStatus
        if p.isRunning {
            p.terminate()
            usleep(300_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            code = -2
        }
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        return (code, code == -2 ? text + "\ntimed out" : text)
    }

    /// Makes the kernel hand its buffered writes to every file system, including our NFS mounts.
    static func flushWrites() {
        run("/bin/sync", [], timeout: 10)
    }

    /// Asks the kernel to unmount while rclone is still serving, so its NFS client gets answers.
    /// Killing rclone first leaves a mount whose server is gone, and unmounting that hangs in the kernel.
    static func unmountServed(_ mountPoint: String) {
        guard mountedPaths().contains(mountPoint) else { return }
        run("/sbin/umount", [mountPoint], timeout: 8)
        if mountedPaths().contains(mountPoint) { run("/sbin/umount", ["-f", mountPoint], timeout: 8) }
        if mountedPaths().contains(mountPoint) {
            run("/usr/sbin/diskutil", ["unmount", "force", mountPoint], timeout: 15)
        }
    }

    /// Clears whatever a previous run left at `mountPoint`: a still-running rclone (stopped after
    /// unmounting through it) or a mount whose rclone died. `lastPort` is the port that rclone served on.
    static func forceCleanup(mountPoint: String, lastPort: Int?) {
        let escaped = mountPoint.map { "\\.^$*+?()[]{}|".contains($0) ? "\\\($0)" : String($0) }.joined()
        if hasOrphan(mountPoint: mountPoint) {
            unmountServed(mountPoint)
            run("/usr/bin/pkill", ["-f", "rclone nfsmount .* \(escaped)( |$)"], timeout: 5)
            usleep(500_000)
        }
        guard mountedPaths().contains(mountPoint) else { return }
        rescueStaleMount(mountPoint, port: lastPort)
    }

    /// The kernel keeps waiting for a dead NFS server, so stand in a throwaway one on the same
    /// port; it answers every request with an error and the unmount can finish.
    static func rescueStaleMount(_ mountPoint: String, port: Int?) {
        var standIn: Process?
        if let port, let rclone = rclonePath {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: rclone)
            p.arguments = ["serve", "nfs", ":memory:", "--addr", "127.0.0.1:\(port)"]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                standIn = p
                usleep(1_000_000)
            }
        }
        defer { standIn?.terminate() }
        run("/sbin/umount", ["-f", mountPoint], timeout: 10)
        if mountedPaths().contains(mountPoint) {
            run("/usr/sbin/diskutil", ["unmount", "force", mountPoint], timeout: 15)
        }
    }

    static func hasOrphan(mountPoint: String) -> Bool {
        let (code, out) = run("/bin/ps", ["-axo", "command="], timeout: 5)
        guard code == 0 else { return false }
        return out.split(separator: "\n").contains {
            $0.contains("rclone nfsmount") && ($0.contains(" \(mountPoint) ") || $0.hasSuffix(" \(mountPoint)"))
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - ssh

    /// ssh options for the app's own quick commands (test, folder browser). They share one
    /// multiplexed connection so browsing doesn't pay a fresh login for every folder.
    static func quickSSHArgs(_ host: String, _ command: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "ControlMaster=auto", "-o", "ControlPath=\(MountManager.cacheRoot)/cm-%C",
         "-o", "ControlPersist=120", host, command]
    }

    struct RemoteListing {
        var home: String
        var path: String
        var folders: [String]
    }

    /// Lists the folders in `path` on `host` (nil = home). Returns the listing or a friendly error.
    static func listRemoteFolders(host: String, path: String?) -> (RemoteListing?, String?) {
        let cdTarget = path.map { "cd -- \(shellQuote($0)) 2>/dev/null || exit 3; " } ?? ""
        let cmd = "cd || exit 3; h=\"$PWD\"; \(cdTarget)echo __RM__; printf '%s\\n%s\\n' \"$h\" \"$PWD\"; ls -1Ap 2>/dev/null | sed -n 's|/$||p'"
        let (code, out) = run("/usr/bin/ssh", quickSSHArgs(host, cmd), timeout: 25)
        if code == 3 { return (nil, "That folder doesn't exist on the server") }
        guard code == 0, let marker = out.range(of: "__RM__\n") else {
            return (nil, friendlyError(out, host: host) ?? "ssh exited with \(code)")
        }
        let lines = out[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return (nil, "Unexpected reply from the server") }
        let folders = lines.dropFirst(2).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (RemoteListing(home: lines[0], path: lines[1], folders: folders), nil)
    }

    /// Opens Terminal with an ssh session in the mount's remote folder.
    static func openTerminal(host: String, remotePath: String) {
        let cd = remotePath.isEmpty ? "" : "cd -- \(shellQuote(remotePath)) 2>/dev/null; "
        let remoteCmd = "\(cd)exec \"$SHELL\" -l"
        let script = "#!/bin/zsh\nclear\nexec ssh -t \(shellQuote(host)) \(shellQuote(remoteCmd))\n"
        let safeHost = host.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        let url = URL(fileURLWithPath: MountManager.cacheRoot + "/ssh-\(safeHost).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    /// Turns ssh/rclone error text into something a person can act on; nil if nothing matched.
    static func friendlyError(_ raw: String, host: String) -> String? {
        let s = raw.lowercased()
        if s.contains("could not resolve hostname") || s.contains("nodename nor servname") {
            return "Unknown host “\(host)” — check the name or your ~/.ssh/config"
        }
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") {
            return "The server's host key is new or changed — run “ssh \(host)” once in Terminal to accept it"
        }
        if s.contains("permission denied") || s.contains("too many authentication failures") {
            return "The server refused your SSH key — check that “ssh \(host)” works without a password"
        }
        if s.contains("connection refused") { return "The server refused the connection — is SSH running?" }
        if s.contains("timed out") || s.contains("no route to host") || s.contains("network is unreachable")
            || s.contains("host is down") {
            return "Can't reach the server — check your network or VPN"
        }
        if s.contains("resource busy") {
            return "The mount folder is still busy from the last mount — retrying shortly"
        }
        if s.contains("subsystem request failed") { return "SFTP isn't enabled on this server" }
        if s.contains("directory not found") || s.contains("no such file") { return "The remote folder doesn't exist" }
        if s.contains("connection closed") || s.contains("broken pipe") || s.contains("exit status 255") {
            return "The SSH connection dropped"
        }
        return nil
    }

    /// Host entries from ~/.ssh/config (and its Include files), skipping wildcard patterns.
    static func sshHosts() -> [SSHHost] {
        var hosts: [SSHHost] = []
        var index: [String: Int] = [:]
        func parse(_ path: String, depth: Int) {
            guard depth < 4, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            var current: [String] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                let parts = raw.trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                guard parts.count > 1, let key = parts.first?.lowercased(), !key.hasPrefix("#") else { continue }
                switch key {
                case "host":
                    current = parts.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    for h in current where index[h] == nil {
                        index[h] = hosts.count
                        hosts.append(SSHHost(alias: h))
                    }
                case "match":
                    current = []
                case "hostname", "user":
                    for h in current {
                        guard let i = index[h] else { continue }
                        // ssh uses the first value it sees
                        if key == "hostname", hosts[i].hostName == nil { hosts[i].hostName = parts[1] }
                        if key == "user", hosts[i].user == nil { hosts[i].user = parts[1] }
                    }
                case "include":
                    for pat in parts.dropFirst() {
                        var full = (pat as NSString).expandingTildeInPath
                        if !full.hasPrefix("/") { full = home + "/.ssh/" + full }
                        var g = glob_t()
                        defer { globfree(&g) }
                        if glob(full, 0, nil, &g) == 0 {
                            for i in 0..<Int(g.gl_pathc) {
                                if let p = g.gl_pathv[i] { parse(String(cString: p), depth: depth + 1) }
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
        parse(home + "/.ssh/config", depth: 0)
        return hosts
    }
}

/// Passphrase-protected SSH keys. The app's ssh runs in batch mode and can't ask for a passphrase,
/// so a locked key is unlocked once into the macOS ssh-agent, which every connection then shares:
/// rclone's, the folder browser's and Terminal's.
enum SSHKeys {
    enum UnlockResult: Equatable {
        case unlocked, wrongPassphrase
        case failed(String)
    }

    /// Keys `host` needs unlocked before it can log in; empty when it can log in as is.
    /// Reloads keys whose passphrases are in the Keychain before giving up.
    static func lockedKeys(host: String) -> [String] {
        var keys = keyState(host: host, loaded: agentFingerprints())
        if !keys.locked.isEmpty {
            loadFromKeychain()
            keys = keyState(host: host, loaded: agentFingerprints())
        }
        guard !keys.locked.isEmpty else { return [] }
        guard keys.anyUsable else { return keys.locked }
        // Another of its keys works locally, but the server may only take the locked one, so ask it
        let (code, out) = System.run("/usr/bin/ssh", System.quickSSHArgs(host, "true"), timeout: 20)
        return code == 255 && out.lowercased().contains("permission denied") ? keys.locked : []
    }

    /// Locked keys when none of `host`'s keys is usable right now, without contacting the server.
    static func lockedKeys(host: String, loaded: Set<String>) -> [String] {
        let keys = keyState(host: host, loaded: loaded)
        return keys.anyUsable ? [] : keys.locked
    }

    private static func keyState(host: String, loaded: Set<String>) -> (locked: [String], anyUsable: Bool) {
        var locked: [String] = []
        var anyUsable = false
        for key in identityFiles(host: host) {
            guard let fp = fingerprint(key) else { continue }
            if loaded.contains(fp) || !needsPassphrase(key) { anyUsable = true } else { locked.append(key) }
        }
        return (locked, anyUsable)
    }

    /// The agent starts empty after a restart; this brings back every key whose passphrase
    /// was saved in the Keychain, without asking.
    static func loadFromKeychain() {
        System.run("/usr/bin/ssh-add", ["--apple-load-keychain"], timeout: 10)
    }

    /// Key files ssh would offer for `host`, including its defaults when none are configured.
    static func identityFiles(host: String) -> [String] {
        let (code, out) = System.run("/usr/bin/ssh", ["-G", host], timeout: 5)
        guard code == 0 else { return [] }
        var seen = Set<String>()
        return out.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("identityfile ") else { return nil }
            let path = (String(line.dropFirst("identityfile ".count)) as NSString).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: path), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    static func agentFingerprints() -> Set<String> {
        let (_, out) = System.run("/usr/bin/ssh-add", ["-l"], timeout: 5)
        return Set(out.split(separator: "\n").compactMap { line in
            line.split(separator: " ").dropFirst().first.map(String.init).flatMap { $0.hasPrefix("SHA256:") ? $0 : nil }
        })
    }

    static func fingerprint(_ key: String) -> String? {
        let (code, out) = System.run("/usr/bin/ssh-keygen", ["-l", "-f", key], timeout: 5)
        guard code == 0 else { return nil }
        return out.split(separator: " ").dropFirst().first.map(String.init)
    }

    static func needsPassphrase(_ key: String) -> Bool {
        let (code, out) = System.run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", key], timeout: 5)
        return code != 0 && out.contains("passphrase")
    }

    /// Adds `key` to the agent with `passphrase`; `remember` also saves the passphrase in the Keychain.
    /// The passphrase reaches ssh-add through a one-shot askpass helper, never a file or the command line.
    static func unlock(_ key: String, passphrase: String, remember: Bool) -> UnlockResult {
        let helper = MountManager.cacheRoot + "/askpass"
        let flag = MountManager.cacheRoot + "/askpass-" + UUID().uuidString
        // ssh-add asks again after a wrong passphrase; answering only once makes it give up instead
        let script = "#!/bin/sh\n[ -e \"$RM_ASKPASS_FLAG\" ] && exit 1\n: > \"$RM_ASKPASS_FLAG\"\n"
            + "printf '%s\\n' \"$RM_ASKPASS_SECRET\"\n"
        do {
            try script.write(toFile: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper)
        } catch {
            return .failed("Couldn't prepare the passphrase prompt: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: flag) }
        let (code, out) = System.run("/usr/bin/ssh-add", (remember ? ["--apple-use-keychain"] : []) + [key],
                                     timeout: 15, environment: [
                                         "SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force",
                                         "RM_ASKPASS_SECRET": passphrase, "RM_ASKPASS_FLAG": flag,
                                     ])
        if code == 0 { return .unlocked }
        if code == -2 { return .failed("ssh-add didn't answer") }
        if out.lowercased().contains("agent") { return .failed("Couldn't reach the Mac's SSH agent") }
        return .wrongPassphrase
    }

    static func displayName(_ key: String) -> String { (key as NSString).abbreviatingWithTildeInPath }
}

/// Minimal HTTP client for rclone's remote-control API on a unix socket.
enum RCClient {
    static func call(socketPath: String, _ method: String, timeout: Int = 3) -> [String: Any]? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let body = "{}"
        let request = "POST /\(method) HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let sent = request.withCString { send(fd, $0, strlen($0), 0) }
        guard sent > 0 else { return nil }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.count > 4_000_000 { break }
        }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let json = data[split.upperBound...]
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }
}

/// "Open at login" via a per-user LaunchAgent that opens the app bundle.
enum LoginItem {
    static let label = "dev.josu.RemoteMounts"
    static var plistURL: URL {
        URL(fileURLWithPath: System.home + "/Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ enabled: Bool) {
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: plistURL)
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
