import SwiftUI

extension MountStatus {
    var tint: Color {
        switch self {
        case .mounted: return .green
        case .mounting, .unmounting, .finishingUploads: return .orange
        case .failed: return .red
        case .unmounted: return .secondary
        }
    }
}

struct StatusDot: View {
    let status: MountStatus
    var body: some View {
        Circle()
            .fill(status == .unmounted ? Color.secondary.opacity(0.45) : status.tint)
            .frame(width: 8, height: 8)
    }
}

/// Rounded server tile with a status badge, used in the menu, sidebar and editor header.
struct ServerIcon: View {
    let status: MountStatus
    var size: CGFloat = 30

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(background)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "server.rack")
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(status.isUp ? .white : .secondary)
                }
            if status != .unmounted {
                Group {
                    if status.isBusy {
                        ProgressView().controlSize(.mini).scaleEffect(size < 36 ? 0.6 : 0.8)
                    } else {
                        Circle().fill(status.tint)
                    }
                }
                .frame(width: size * 0.36, height: size * 0.36)
                .background(Circle().fill(.background))
                .overlay(Circle().strokeBorder(.background, lineWidth: max(1.5, size * 0.05)))
                .offset(x: size * 0.1, y: size * 0.1)
            }
        }
        .frame(width: size, height: size)
    }

    private var background: AnyShapeStyle {
        status.isUp
            ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.22, green: 0.56, blue: 0.98),
                                                    Color(red: 0.10, green: 0.34, blue: 0.82)],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(Color.secondary.opacity(0.15))
    }
}

/// A one-line summary of a mount's upload activity, or nil when idle.
func activitySummary(_ stats: MountStats?) -> String? {
    guard let s = stats, s.pendingUploads > 0 else { return nil }
    var parts = ["↑ \(s.pendingUploads) upload\(s.pendingUploads == 1 ? "" : "s")"]
    if s.speed > 0 { parts.append(Format.speed(s.speed)) }
    return parts.joined(separator: " · ")
}

/// Shared actions for a mount, used by context menus and "…" menus.
struct MountActions: View {
    @EnvironmentObject var m: MountManager
    let id: UUID
    var includeEdit = true

    var body: some View {
        let status = m.status(id)
        Button("Open in Finder") { m.mountAndOpen(id) }
        Button("Open in Terminal") { m.openTerminal(id) }
        Button("Copy Local Path") { m.copyPath(id) }
        Divider()
        if m.isWanted(id) || status.isUp {
            Button("Remount") { m.remount(id) }
            Button("Unmount") { m.unmount(id) }
        } else {
            Button("Mount") { m.mount(id) }
        }
        Button("Show Log") { m.showLog(id) }
        if includeEdit {
            Divider()
            Button("Edit…") {
                m.selection = id
                m.showManagerWindow?()
            }
        }
    }
}

struct HoverIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
