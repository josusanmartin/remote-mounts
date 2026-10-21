import Foundation

struct MountConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New Server"
    /// An alias from ~/.ssh/config or user@hostname; passed straight to the system ssh.
    var host = ""
    /// Empty = the remote home folder, "/" = the whole filesystem, otherwise relative to home or absolute.
    var remotePath = ""
    var mountPoint = MountConfig.autoMountPoint(for: "New Server")
    var autoMount = true
    var readOnly = false
    var cacheSizeGB = 10
    var dirCacheMinutes = 10
    var extraFlags = ""

    init() {}

    // Decode field by field so configs written by older versions keep loading
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MountConfig()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath) ?? d.remotePath
        mountPoint = try c.decodeIfPresent(String.self, forKey: .mountPoint) ?? d.mountPoint
        autoMount = try c.decodeIfPresent(Bool.self, forKey: .autoMount) ?? d.autoMount
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? d.readOnly
        cacheSizeGB = try c.decodeIfPresent(Int.self, forKey: .cacheSizeGB) ?? d.cacheSizeGB
        dirCacheMinutes = try c.decodeIfPresent(Int.self, forKey: .dirCacheMinutes) ?? d.dirCacheMinutes
        extraFlags = try c.decodeIfPresent(String.self, forKey: .extraFlags) ?? d.extraFlags
    }

    /// Default mount folder for a name: ~/Mounts/<name>, with characters macOS paths can't hold replaced.
    static func autoMountPoint(for name: String) -> String {
        var folder = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if folder.isEmpty || folder.hasPrefix(".") { folder = "untitled" + folder }
        return "~/Mounts/" + folder
    }

    /// True while the mount folder is still the automatic one, so it should follow renames.
    var usesAutoMountPoint: Bool {
        mountPoint == Self.autoMountPoint(for: name) || mountPoint == "~/Mounts/new-server"
    }

    var expandedMountPoint: String {
        URL(fileURLWithPath: (mountPoint as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// Remote path in rclone form: "" for home, "~/x" becomes "x".
    var rcloneRemotePath: String {
        var p = remotePath.trimmingCharacters(in: .whitespaces)
        if p == "~" { p = "" } else if p.hasPrefix("~/") { p.removeFirst(2) }
        return p
    }

    /// The name to show; falls back to the host while the name field is empty.
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return host.isEmpty ? "Untitled" : host
    }

    var displayRemotePath: String { remotePath.isEmpty ? "~" : remotePath }
    var remoteDescription: String { "\(host.isEmpty ? "no host" : host):\(displayRemotePath)" }
    var displayMountPoint: String { (expandedMountPoint as NSString).abbreviatingWithTildeInPath }

    var validationError: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Set an SSH host first" }
        if host.contains(where: \.isWhitespace) { return "The SSH host can't contain spaces" }
        if mountPoint.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a folder to mount at" }
        return nil
    }
}

enum MountStatus: Equatable {
    case unmounted, mounting, mounted, unmounting
    /// Unmount was requested but rclone still has files to upload; stays mounted until they finish.
    case finishingUploads(Int)
    case failed(String)

    var label: String {
        switch self {
        case .unmounted: return "Not mounted"
        case .mounting: return "Connecting…"
        case .mounted: return "Mounted"
        case .unmounting: return "Unmounting…"
        case .finishingUploads(let n): return "Finishing \(n) upload\(n == 1 ? "" : "s") before unmounting…"
        case .failed(let msg): return msg
        }
    }

    var isFailed: Bool { if case .failed = self { return true } else { return false } }
    /// The folder is mounted and usable.
    var isUp: Bool {
        switch self {
        case .mounted, .finishingUploads: return true
        default: return false
        }
    }
    var isBusy: Bool {
        switch self {
        case .mounting, .unmounting, .finishingUploads: return true
        default: return false
        }
    }
}

/// Live numbers from a running rclone's remote-control API.
struct MountStats: Equatable {
    struct Transfer: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let size: Int64
        let bytes: Int64
        let percentage: Int
        let speed: Double
    }

    var uploadsInProgress = 0
    var uploadsQueued = 0
    var erroredFiles = 0
    var cacheBytes: Int64 = 0
    var cachedFiles = 0
    var cachedFolders = 0
    var transferring: [Transfer] = []

    var pendingUploads: Int { uploadsInProgress + uploadsQueued }
    var speed: Double { transferring.reduce(0) { $0 + $1.speed } }

    init() {}

    init(vfs: [String: Any], core: [String: Any]?) {
        let disk = vfs["diskCache"] as? [String: Any] ?? [:]
        uploadsInProgress = disk["uploadsInProgress"] as? Int ?? 0
        uploadsQueued = disk["uploadsQueued"] as? Int ?? 0
        erroredFiles = disk["erroredFiles"] as? Int ?? 0
        cacheBytes = (disk["bytesUsed"] as? NSNumber)?.int64Value ?? 0
        cachedFiles = disk["files"] as? Int ?? 0
        let meta = vfs["metadataCache"] as? [String: Any] ?? [:]
        cachedFolders = meta["dirs"] as? Int ?? 0
        let list = core?["transferring"] as? [[String: Any]] ?? []
        transferring = list.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return Transfer(name: name,
                            size: (t["size"] as? NSNumber)?.int64Value ?? 0,
                            bytes: (t["bytes"] as? NSNumber)?.int64Value ?? 0,
                            percentage: t["percentage"] as? Int ?? 0,
                            speed: (t["speedAvg"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
}

/// A Host entry from ~/.ssh/config.
struct SSHHost: Identifiable, Hashable {
    var id: String { alias }
    let alias: String
    var hostName: String?
    var user: String?

    var detail: String? {
        guard let hostName, hostName != alias else { return user.map { "\($0)@\(alias)" } }
        return user.map { "\($0)@\(hostName)" } ?? hostName
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false  // "0 bytes", not "Zero KB"
        return f.string(fromByteCount: n)
    }

    static func speed(_ bps: Double) -> String { bytes(Int64(bps)) + "/s" }
}
