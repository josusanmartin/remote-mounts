import SwiftUI

/// Live view of a mount's rclone log, refreshed every couple of seconds.
struct LogSheet: View {
    @EnvironmentObject var m: MountManager
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var text = ""
    @State private var errorsOnly = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log — \(m.config(id)?.displayName ?? "Server")").font(.headline)
                Spacer()
                Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(rendered)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            HStack {
                Button("Clear Log") {
                    m.clearLog(id)
                    reload()
                }
                Button("Open in Console") { m.openLogInConsole(id) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 500)
        .onAppear(perform: reload)
        .onReceive(timer) { _ in reload() }
    }

    private func reload() {
        let t = m.readLogTail(id)
        if t != text { text = t }
    }

    private var rendered: AttributedString {
        var out = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = errorsOnly ? lines.filter { isError($0) || $0.hasPrefix("===") } : Array(lines)
        if shown.allSatisfy({ $0.isEmpty }) {
            var empty = AttributedString(errorsOnly ? "No errors." : "The log is empty.")
            empty.foregroundColor = .secondary
            return empty
        }
        for line in shown {
            var a = AttributedString(line + "\n")
            if line.hasPrefix("===") {
                a.foregroundColor = .accentColor
                a.font = .system(size: 11, weight: .semibold, design: .monospaced)
            } else if isError(line) {
                a.foregroundColor = .red
            } else if line.contains("NOTICE") {
                a.foregroundColor = .secondary
            }
            out += a
        }
        return out
    }

    private func isError<S: StringProtocol>(_ line: S) -> Bool {
        line.contains("ERROR") || line.contains("CRITICAL") || line.contains("Fatal")
    }
}
