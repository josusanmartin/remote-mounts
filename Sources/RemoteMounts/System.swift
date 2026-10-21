import Foundation

/// Small wrappers around the OS: mount table, child commands, ~/.ssh/config, login item.
enum System {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var rclonePath: String? {
        ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
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
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            usleep(300_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return (-2, "timed out")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Kills any rclone left serving `mountPoint` (e.g. after a crash) and force-unmounts it.
    static func forceCleanup(mountPoint: String) {
        let escaped = mountPoint.map { "\\.^$*+?()[]{}|".contains($0) ? "\\\($0)" : String($0) }.joined()
        run("/usr/bin/pkill", ["-f", "rclone nfsmount .* \(escaped)( |$)"], timeout: 5)
        usleep(500_000)
        guard mountedPaths().contains(mountPoint) else { return }
        run("/sbin/umount", ["-f", mountPoint], timeout: 8)
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

    /// Host aliases from ~/.ssh/config (and its Include files), skipping wildcard patterns.
    static func sshHosts() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func parse(_ path: String, depth: Int) {
            guard depth < 4, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: \.isNewline) {
                let parts = raw.trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                guard parts.count > 1, let key = parts.first?.lowercased() else { continue }
                if key == "host" {
                    for h in parts.dropFirst()
                    where !h.contains("*") && !h.contains("?") && !h.hasPrefix("!") && seen.insert(h).inserted {
                        out.append(h)
                    }
                } else if key == "include" {
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
                }
            }
        }
        parse(home + "/.ssh/config", depth: 0)
        return out
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
