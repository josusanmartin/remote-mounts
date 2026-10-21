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

    var remoteDescription: String {
        "\(host.isEmpty ? "no host" : host):\(remotePath.isEmpty ? "~" : remotePath)"
    }

    var displayMountPoint: String { (expandedMountPoint as NSString).abbreviatingWithTildeInPath }

    var validationError: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Set an SSH host first" }
        if host.contains(where: \.isWhitespace) { return "SSH host can't contain spaces" }
        if mountPoint.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a folder to mount at" }
        return nil
    }
}

enum MountStatus: Equatable {
    case unmounted, mounting, mounted, unmounting
    case failed(String)

    var label: String {
        switch self {
        case .unmounted: return "Not mounted"
        case .mounting: return "Connecting…"
        case .mounted: return "Mounted"
        case .unmounting: return "Unmounting…"
        case .failed(let msg): return msg
        }
    }

    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}
