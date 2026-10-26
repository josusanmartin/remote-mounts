import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Copies files and folders from a mounted server into ~/Downloads, with progress in the
/// Downloads window. ⌘-click in iTerm2 (rm-open) hands paths over as remotemounts://download?path=…
/// The copy goes through the mount's rclone straight from the server, never through the mount
/// folder, so a stuck mount can't hang a download (or the app).
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [Download] = []
    var showWindow: (() -> Void)?

    var active: [Download] { items.filter(\.isActive) }

    func handle(_ url: URL) {
        guard url.scheme == "remotemounts", url.host == "download",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value
        else { return }
        start(path)
    }

    func start(_ path: String) {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        // Any app or web page can open the URL, so only copy out of mounted servers. Matched by
        // path alone: looking at the file itself would go through the mount.
        let m = MountManager.shared
        guard let c = m.configs.first(where: { source.path.hasPrefix($0.expandedMountPoint + "/") }),
              m.status(c.id).isUp else {
            NSLog("Remote Mounts: not downloading \(path): not in a mounted server")
            return
        }
        let relative = String(source.path.dropFirst(c.expandedMountPoint.count + 1))
        let root = c.rcloneRemotePath
        let d = Download(source: source, job: CopyJob(socket: m.socketPath(c.id), root: ":sftp:" + root,
                                                      path: relative))
        items.insert(d, at: 0)
        showWindow?()
        d.start()
    }

    func retry(_ d: Download) {
        items.removeAll { $0 === d }
        start(d.source.path)
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }
}

@MainActor
final class Download: ObservableObject, Identifiable {
    enum State: Equatable {
        case starting
        case copying
        case done(URL)
        case failed(String)
        case cancelled
    }

    nonisolated let id = UUID()
    let source: URL
    let name: String
    @Published private(set) var isFolder = false
    @Published private(set) var state: State = .starting
    @Published private(set) var copied: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var speed: Double = 0

    private let job: CopyJob
    private var timer: Timer?
    private var samples: [(time: Date, bytes: Int64)] = []

    init(source: URL, job: CopyJob) {
        self.source = source
        self.job = job
        name = source.lastPathComponent
    }

    var isActive: Bool {
        switch state {
        case .starting, .copying: return true
        default: return false
        }
    }

    var fraction: Double? {
        guard case .copying = state, total > 0 else { return nil }
        return min(1, Double(copied) / Double(total))
    }

    var secondsLeft: Double? {
        guard case .copying = state, speed > 0, total > copied else { return nil }
        return Double(total - copied) / speed
    }

    func start() {
        let job = job
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        Thread.detachNewThread {
            let result = job.run(into: downloads)
            DispatchQueue.main.async { self.finish(result) }
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        let job = job
        DispatchQueue.global().async { job.cancel() }
    }

    private func refresh() {
        // The window's summary, the menu bar row and the menu bar icon add up all downloads
        DownloadManager.shared.objectWillChange.send()
        let p = job.progress
        copied = p.copied
        total = p.total
        if let folder = p.isFolder, folder != isFolder { isFolder = folder }
        if p.copying, state == .starting { state = .copying }
        // Speed over the last few seconds, so it follows changes without jumping around
        let now = Date()
        samples.append((now, p.copied))
        samples.removeAll { now.timeIntervalSince($0.time) > 4 }
        if let first = samples.first, now.timeIntervalSince(first.time) > 0.5 {
            speed = Double(p.copied - first.bytes) / now.timeIntervalSince(first.time)
        }
    }

    private func finish(_ result: Result<URL, CopyJob.Failure>) {
        timer?.invalidate()
        timer = nil
        refresh()
        DownloadManager.shared.objectWillChange.send()
        switch result {
        case .success(let dest):
            copied = total
            state = .done(dest)
            // Bounces the Downloads stack in the Dock, as browsers do
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                         object: dest.path)
        case .failure(.cancelled):
            state = .cancelled
        case .failure(.error(let msg)):
            state = .failed(msg)
        }
    }
}

/// The copy itself, run by the mount's rclone through its control socket and watched from a
/// background thread. rclone copies into a temporary folder first, so a half-copied file never
/// shows up in Downloads; then it's moved in under a name that's free.
final class CopyJob: @unchecked Sendable {
    enum Failure: Error { case cancelled, error(String) }
    struct Progress { var copied: Int64 = 0, total: Int64 = 0, copying = false, isFolder: Bool? }

    private let socket: String
    private let root: String  // ":sftp:<the mount's remote folder>"
    private let path: String  // inside that folder
    private let group = "download-" + UUID().uuidString

    private let lock = NSLock()
    private var _progress = Progress()
    private var _cancelled = false
    private var _jobs: [Int] = []

    init(socket: String, root: String, path: String) {
        self.socket = socket
        self.root = root
        self.path = path
    }

    var progress: Progress { lock.withLock { _progress } }
    private var cancelled: Bool { lock.withLock { _cancelled } }
    private func update(_ f: (inout Progress) -> Void) { lock.withLock { f(&_progress) } }

    func cancel() {
        let jobs = lock.withLock { _cancelled = true; return _jobs }
        for id in jobs { rc("job/stop", ["jobid": id]) }
    }

    @discardableResult
    private func rc(_ method: String, _ params: [String: Any], timeout: Int = 30) -> [String: Any]? {
        RCClient.call(socketPath: socket, method, params: params, timeout: timeout)
    }

    /// Starts an rclone job in the background and returns its id.
    private func startJob(_ method: String, _ params: [String: Any]) throws -> Int {
        let r = rc(method, params.merging(["_async": true, "_group": group]) { $1 })
        guard let id = r?["jobid"] as? Int else {
            throw Failure.error((r?["error"] as? String).map(Self.friendly) ?? "Remote Mounts couldn't reach rclone")
        }
        lock.withLock { _jobs.append(id) }
        return id
    }

    func run(into downloads: URL) -> Result<URL, Failure> {
        let fm = FileManager.default
        var staging: URL?
        defer {
            if let staging { try? fm.removeItem(at: staging) }
            rc("core/stats-delete", ["group": group])
        }
        do {
            guard let item = rc("operations/stat", ["fs": root, "remote": path])?["item"] as? [String: Any] else {
                throw Failure.error("It isn't on the server anymore")
            }
            let isFolder = item["IsDir"] as? Bool ?? false
            let name = (path as NSString).lastPathComponent
            update {
                $0.isFolder = isFolder
                $0.total = isFolder ? 0 : (item["Size"] as? Int64 ?? Int64(item["Size"] as? Int ?? 0))
            }
            if cancelled { throw Failure.cancelled }
            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            let tmp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: downloads, create: true)
            staging = tmp
            let top = tmp.appendingPathComponent(name)

            let copy: Int
            var sizing: Int?
            if isFolder {
                let folder = root.hasSuffix(":") ? root + path : root + "/" + path
                copy = try startJob("sync/copy", ["srcFs": folder, "dstFs": top.path, "createEmptySrcDirs": true])
                // The whole folder's size, for the progress bar; the copy's own total grows as it goes
                sizing = try? startJob("operations/size", ["fs": folder])
            } else {
                copy = try startJob("operations/copyfile", ["srcFs": root, "srcRemote": path,
                                                            "dstFs": tmp.path, "dstRemote": name])
            }
            update { $0.copying = true }

            while true {
                if cancelled { throw Failure.cancelled }
                if let s = rc("core/stats", ["group": group], timeout: 5) {
                    let bytes = Self.int64(s["bytes"]), seen = Self.int64(s["totalBytes"])
                    update { $0.copied = bytes; $0.total = max($0.total, seen) }
                }
                if let id = sizing, let j = rc("job/status", ["jobid": id], timeout: 5), j["finished"] as? Bool == true {
                    sizing = nil
                    let size = Self.int64((j["output"] as? [String: Any])?["bytes"])
                    update { $0.total = max($0.total, size) }
                }
                if let j = rc("job/status", ["jobid": copy], timeout: 5), j["finished"] as? Bool == true {
                    if cancelled { throw Failure.cancelled }
                    guard j["success"] as? Bool == true else {
                        throw Failure.error(Self.friendly(j["error"] as? String ?? "The copy failed"))
                    }
                    break
                }
                usleep(300_000)
            }
            if let id = sizing { rc("job/stop", ["jobid": id]) }
            guard fm.fileExists(atPath: top.path) else { throw Failure.error("rclone didn't copy anything") }
            let dest = freeName(in: downloads, for: name)
            try fm.moveItem(at: top, to: dest)
            return .success(dest)
        } catch let f as Failure {
            if case .cancelled = f { for id in lock.withLock({ _jobs }) { rc("job/stop", ["jobid": id]) } }
            return .failure(f)
        } catch {
            return .failure(.error(error.localizedDescription))
        }
    }

    private static func int64(_ v: Any?) -> Int64 {
        (v as? NSNumber)?.int64Value ?? 0
    }

    private static func friendly(_ error: String) -> String {
        let s = error.lowercased()
        if s.contains("not found") || s.contains("no such file") { return "It isn't on the server anymore" }
        if s.contains("permission denied") { return "The server won't let you read it" }
        if s.contains("no space") { return "Your Mac is out of disk space" }
        return error.count > 160 ? String(error.prefix(160)) + "…" : error
    }

    /// "chart.png", then "chart 2.png", "chart 3.png"…, like Finder.
    private func freeName(in folder: URL, for name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".")
            ? name : (name as NSString).deletingPathExtension
        let suffix = stem == name ? "" : "." + ext
        var n = 1
        while true {
            let candidate = folder.appendingPathComponent(n == 1 ? name : "\(stem) \(n)\(suffix)")
            if (try? candidate.checkResourceIsReachable()) != true,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil {
                return candidate
            }
            n += 1
        }
    }
}

// MARK: - Window

struct DownloadsView: View {
    @ObservedObject var dm = DownloadManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if dm.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No downloads").font(.headline)
                    Text("⌘-click a server path in iTerm2 and choose Download.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(dm.items) { d in
                            DownloadRow(d: d)
                            if d !== dm.items.last { Divider().padding(.leading, 56) }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { dm.clearFinished() }
                    .disabled(dm.items.allSatisfy(\.isActive))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
    }

    private var summary: String {
        let n = dm.active.count
        return n == 0 ? "Saved to your Downloads folder" : "Downloading \(n) item\(n == 1 ? "" : "s")…"
    }
}

struct DownloadRow: View {
    @ObservedObject var d: Download

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: d.isFolder ? .folder
                : UTType(filenameExtension: d.source.pathExtension) ?? .data))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(d.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if d.isActive {
                    if let f = d.fraction {
                        ProgressView(value: f).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            button
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if case .done(let url) = d.state { NSWorkspace.shared.open(url) }
        }
        .help(d.source.path)
    }

    @ViewBuilder
    private var button: some View {
        switch d.state {
        case .starting, .copying:
            HoverIconButton(systemImage: "xmark", help: "Stop downloading") { d.cancel() }
        case .done(let url):
            HoverIconButton(systemImage: "magnifyingglass", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failed, .cancelled:
            HoverIconButton(systemImage: "arrow.clockwise", help: "Try again") {
                DownloadManager.shared.retry(d)
            }
        }
    }

    private var isError: Bool {
        if case .failed = d.state { return true }
        return false
    }

    private var detail: String {
        switch d.state {
        case .starting:
            return "Starting…"
        case .copying:
            // A folder's total arrives once rclone has gone through it
            if d.total == 0 {
                return d.copied == 0 ? "Looking through the folder…" : "\(Format.bytes(d.copied)) so far"
            }
            var parts = ["\(Format.bytes(d.copied)) of \(Format.bytes(d.total))"]
            if d.speed > 0 { parts.append(Format.speed(d.speed)) }
            if let s = d.secondsLeft { parts.append(Self.timeLeft(s)) }
            return parts.joined(separator: " · ")
        case .done:
            return "\(Format.bytes(d.total)) · Done"
        case .failed(let msg):
            return msg
        case .cancelled:
            return "Stopped"
        }
    }

    static func timeLeft(_ s: Double) -> String {
        if s < 5 { return "a few seconds left" }
        if s < 60 { return "about \(Int((s / 5).rounded()) * 5) s left" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = s < 3600 ? [.minute] : [.hour, .minute]
        return "about \(f.string(from: s.rounded()) ?? "") left"
    }
}
