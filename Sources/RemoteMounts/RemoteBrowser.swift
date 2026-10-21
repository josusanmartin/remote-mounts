import SwiftUI

/// Sheet for picking a folder on the server over ssh, so nobody has to type remote paths.
struct RemoteFolderBrowser: View {
    let host: String
    /// Folder to open first, in rclone form ("" = home).
    let start: String
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listing: System.RemoteListing?
    @State private var error: String?
    @State private var loading = false
    @State private var showHidden = false
    @State private var selected: String?

    private var folders: [String] {
        (listing?.folders ?? []).filter { showHidden || !$0.hasPrefix(".") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a Folder on \(host)").font(.headline)
                HStack(spacing: 6) {
                    Button { load(listing.map { parent(of: $0.path) }) } label: { Image(systemName: "chevron.up") }
                        .disabled(listing?.path == "/" || loading)
                        .help("Enclosing folder")
                    Button { load(nil) } label: { Image(systemName: "house") }
                        .disabled(loading)
                        .help("Home folder")
                    breadcrumbs
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
            }
            .padding(16)

            Divider()

            Group {
                if let error {
                    ContentUnavailableView {
                        Label("Couldn't List Folders", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { load(listing?.path ?? (start.isEmpty ? nil : start)) }
                    }
                } else if listing != nil && folders.isEmpty {
                    ContentUnavailableView("No Folders Here", systemImage: "folder",
                                           description: Text("This folder has no subfolders."))
                } else {
                    List(folders, id: \.self, selection: $selected) { f in
                        Label(f, systemImage: "folder.fill")
                            .symbolRenderingMode(.multicolor)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture(count: 2).onEnded { enter(f) })
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Toggle("Show hidden folders", isOn: $showHidden).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selected.map { "Choose “\($0)”" } ?? "Choose This Folder") { choose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(listing == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 500)
        .task { load(start.isEmpty ? nil : start) }
    }

    private var breadcrumbs: some View {
        let path = listing?.path ?? ""
        let parts = path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("/") { load("/") }.buttonStyle(.borderless)
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                    Button(part) { load("/" + parts[...i].joined(separator: "/")) }
                        .buttonStyle(.borderless)
                        .fontWeight(i == parts.count - 1 ? .semibold : .regular)
                }
            }
            .font(.callout)
        }
    }

    private func load(_ path: String?) {
        loading = true
        error = nil
        selected = nil
        let host = host
        Task {
            let (result, err) = await Task.detached { System.listRemoteFolders(host: host, path: path) }.value
            loading = false
            if let result { listing = result } else { error = err }
        }
    }

    private func enter(_ folder: String) {
        guard let base = listing?.path else { return }
        load(base == "/" ? "/" + folder : base + "/" + folder)
    }

    private func parent(of path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    /// Stores paths under home as ~/..., the home folder itself as "".
    private func choose() {
        guard let listing else { return }
        var path = listing.path
        if let sel = selected { path = path == "/" ? "/" + sel : path + "/" + sel }
        if path == listing.home {
            onChoose("")
        } else if path.hasPrefix(listing.home + "/") {
            onChoose("~/" + path.dropFirst(listing.home.count + 1))
        } else {
            onChoose(path)
        }
        dismiss()
    }
}
