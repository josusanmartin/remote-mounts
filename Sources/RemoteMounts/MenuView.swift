import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject var m: MountManager
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if m.configs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(m.configs) { c in MenuMountRow(config: c) }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !downloads.active.isEmpty {
                Divider()
                downloadsRow
            }
            Divider()
            footer
        }
        .frame(width: 370)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Remote Mounts").font(.system(size: 13, weight: .semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HoverIconButton(systemImage: "plus", help: "Add a server") {
                m.showAddSheet = true
                m.showManagerWindow?()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let total = m.configs.count
        let failed = m.configs.filter { m.status($0.id).isFailed }.count
        let pending = m.totalPendingUploads
        var parts: [String] = []
        if total == 0 { return "No servers yet" }
        parts.append(m.mountedCount == 0 ? "Nothing mounted" : "\(m.mountedCount) of \(total) mounted")
        if failed > 0 { parts.append("\(failed) with problems") }
        if pending > 0 { parts.append("↑ \(pending) uploading") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Mount a server as a folder").font(.headline)
            Text("Pick any host from your SSH config and browse it in Finder like local files.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add a Server…") {
                m.showAddSheet = true
                m.showManagerWindow?()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Overall progress of downloads in flight; click for the Downloads window.
    private var downloadsRow: some View {
        let active = downloads.active
        let total = active.reduce(Int64(0)) { $0 + $1.total }
        let copied = active.reduce(Int64(0)) { $0 + $1.copied }
        let speed = active.reduce(0) { $0 + $1.speed }
        return Button { downloads.showWindow?() } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(active.count == 1 ? "Downloading \(active[0].name)" : "Downloading \(active.count) items")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if total > 0 {
                        ProgressView(value: min(1, Double(copied) / Double(total))).controlSize(.small)
                    }
                    Text("\(Format.bytes(copied)) of \(Format.bytes(total))" + (speed > 0 ? " · " + Format.speed(speed) : ""))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Mount All") { m.mountAll() }.disabled(m.configs.isEmpty)
            Button("Unmount All") { m.unmountAll() }.disabled(m.wanted.isEmpty && m.mountedCount == 0)
            Spacer()
            Menu {
                Button("Manage Servers…") { m.showManagerWindow?() }
                Button("Add Server…") {
                    m.showAddSheet = true
                    m.showManagerWindow?()
                }
                Button("Downloads…") { downloads.showWindow?() }
                Button("Settings…") { m.showSettingsWindow?() }
                Divider()
                Button("Quit Remote Mounts") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct MenuMountRow: View {
    @EnvironmentObject var m: MountManager
    let config: MountConfig
    @State private var hovering = false

    var body: some View {
        let id = config.id
        let status = m.status(id)
        HStack(spacing: 10) {
            ServerIcon(status: status, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                subtitle(status)
            }
            Spacer(minLength: 6)
            if hovering {
                HStack(spacing: 4) {
                    HoverIconButton(systemImage: "folder", help: "Open in Finder") { m.mountAndOpen(id) }
                    HoverIconButton(systemImage: "terminal", help: "Open in Terminal") { m.openTerminal(id) }
                    Menu { MountActions(id: id) } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .transition(.opacity)
            }
            Toggle("", isOn: Binding(
                get: { m.isWanted(id) || status.isUp },
                set: { $0 ? m.mount(id) : m.unmount(id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(m.isWanted(id) ? "Unmount" : "Mount")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { m.mountAndOpen(id) }
        .contextMenu { MountActions(id: id) }
        .help(status.isUp ? "Click to open \(config.displayMountPoint) in Finder" : "Click to mount and open")
    }

    @ViewBuilder
    private func subtitle(_ status: MountStatus) -> some View {
        let id = config.id
        switch status {
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 3) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if m.isWanted(id) { Button(m.lockedMounts.contains(id) ? "Unlock…" : "Retry Now") { m.mount(id) } }
                    Button("Show Log") { m.showLog(id) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .mounting:
            Text(m.isWaitingForUnlock(id) ? "Waiting for your SSH key's passphrase…" : "Connecting to \(config.host)…")
                .font(.caption).foregroundStyle(.secondary)
        case .unmounting, .finishingUploads:
            Text(status.label).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .mounted:
            VStack(alignment: .leading, spacing: 2) {
                if let activity = activitySummary(m.stats[id]) {
                    Text(activity).font(.caption).foregroundStyle(.blue)
                } else {
                    Text(config.displayMountPoint).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if m.needsRemount(id) {
                    Button("Settings changed — Remount") { m.remount(id) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        case .unmounted:
            Text(config.remoteDescription).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
