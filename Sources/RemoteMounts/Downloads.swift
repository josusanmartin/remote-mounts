import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Copies files and folders from a mounted server into ~/Downloads, with progress in the
/// Downloads window. ⌘-click in iTerm2 (rm-open) hands paths over as remotemounts://download?path=…
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
        // Any app or web page can open the URL, so only copy out of mounted servers
        let mounts = MountManager.shared.configs.map(\.expandedMountPoint)
        guard mounts.contains(where: { source.path.hasPrefix($0 + "/") }),
              FileManager.default.fileExists(atPath: source.path) else {
            NSLog("Remote Mounts: not downloading \(path): not in a mounted server")
            return
        }
        let d = Download(source: source)
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
        case counting(files: Int)
        case copying
        case done(URL)
        case failed(String)
        case cancelled
    }

    nonisolated let id = UUID()
    let source: URL
    let name: String
    let isFolder: Bool
    @Published private(set) var state: State = .counting(files: 0)
    @Published private(set) var copied: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var speed: Double = 0

    private let job = CopyJob()
    private var timer: Timer?
    private var samples: [(time: Date, bytes: Int64)] = []

    init(source: URL) {
        self.source = source
        name = source.lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        isFolder = isDir.boolValue
    }

    var isActive: Bool {
        switch state {
        case .counting, .copying: return true
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
        let (job, source) = (job, source)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        Thread.detachNewThread {
            let result = job.run(source: source, into: downloads)
            DispatchQueue.main.async { self.finish(result) }
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() { job.cancel() }

    private func refresh() {
        // The window's summary, the menu bar row and the menu bar icon add up all downloads
        DownloadManager.shared.objectWillChange.send()
        let p = job.progress
        copied = p.copied
        total = p.total
        if p.copying {
            if case .counting = state { state = .copying }
        } else {
            state = .counting(files: p.files)
        }
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

/// The copy itself, on a background thread. Copies into a temporary folder first, so a
/// half-copied file never shows up in Downloads, then moves it in under a name that's free.
final class CopyJob: @unchecked Sendable {
    enum Failure: Error { case cancelled, error(String) }
    struct Progress { var files = 0, copied: Int64 = 0, total: Int64 = 0, copying = false }

    private let lock = NSLock()
    private var _progress = Progress()
    private var _cancelled = false

    var progress: Progress { lock.withLock { _progress } }
    func cancel() { lock.withLock { _cancelled = true } }
    private var cancelled: Bool { lock.withLock { _cancelled } }
    private func update(_ f: (inout Progress) -> Void) { lock.withLock { f(&_progress) } }

    private struct Entry { let relative: String, kind: Kind, size: Int64 }
    private enum Kind { case file, folder, link }

    func run(source: URL, into downloads: URL) -> Result<URL, Failure> {
        let fm = FileManager.default
        var staging: URL?
        defer { if let staging { try? fm.removeItem(at: staging) } }
        do {
            let entries = try list(source)
            update {
                $0.total = entries.reduce(0) { $0 + $1.size }
                $0.copying = true
            }
            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            let tmp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: downloads, create: true)
            staging = tmp
            let top = tmp.appendingPathComponent(source.lastPathComponent)
            for e in entries {
                if cancelled { return .failure(.cancelled) }
                let from = e.relative.isEmpty ? source : source.appendingPathComponent(e.relative)
                let to = e.relative.isEmpty ? top : top.appendingPathComponent(e.relative)
                switch e.kind {
                case .folder: try fm.createDirectory(at: to, withIntermediateDirectories: true)
                case .link: try fm.createSymbolicLink(atPath: to.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: from.path))
                case .file: try copyFile(from, to)
                }
            }
            // Folders' dates last, since adding files to them changes their dates
            for e in entries.reversed() where e.kind != .link {
                let from = e.relative.isEmpty ? source : source.appendingPathComponent(e.relative)
                let to = e.relative.isEmpty ? top : top.appendingPathComponent(e.relative)
                if let attrs = try? fm.attributesOfItem(atPath: from.path) {
                    try? fm.setAttributes(attrs.filter { $0.key == .modificationDate || $0.key == .posixPermissions },
                                          ofItemAtPath: to.path)
                }
            }
            let dest = freeName(in: downloads, for: source.lastPathComponent)
            try fm.moveItem(at: top, to: dest)
            return .success(dest)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(.error(error.localizedDescription))
        }
    }

    /// Everything to copy, parents before children. Folders are walked here, before copying,
    /// so the progress bar knows the total size.
    private func list(_ source: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let v = try source.resourceValues(forKeys: Set(keys))
        guard v.isDirectory == true else {
            update { $0.files = 1 }
            return [Entry(relative: "", kind: .file, size: Int64(v.fileSize ?? 0))]
        }
        var out = [Entry(relative: "", kind: .folder, size: 0)]
        var error: Error?
        let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys,
                                                    errorHandler: { _, e in error = e; return false })
        let prefix = source.path.count + 1
        while let url = walker?.nextObject() as? URL {
            if cancelled { throw Failure.cancelled }
            let v = try url.resourceValues(forKeys: Set(keys))
            let rel = String(url.standardizedFileURL.path.dropFirst(prefix))
            if v.isSymbolicLink == true {
                out.append(Entry(relative: rel, kind: .link, size: 0))
            } else if v.isDirectory == true {
                out.append(Entry(relative: rel, kind: .folder, size: 0))
            } else {
                out.append(Entry(relative: rel, kind: .file, size: Int64(v.fileSize ?? 0)))
                update { $0.files += 1 }
            }
        }
        if let error { throw error }
        return out
    }

    private func copyFile(_ from: URL, _ to: URL) throws {
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: to.path, contents: nil) else {
            throw Failure.error("Couldn't create \(to.lastPathComponent) in Downloads")
        }
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        while true {
            if cancelled { throw Failure.cancelled }
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            update { $0.copied += Int64(chunk.count) }
        }
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
        case .counting, .copying:
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
        case .counting(let files):
            return files == 0 ? "Starting…" : "Looking through the folder… \(files) files"
        case .copying:
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
