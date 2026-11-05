import AppKit
import SwiftUI

struct TerminalSheet: View {
    @Bindable var model: PoolAppModel
    let terminalID: UUID
    var openLink: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    var copyLink: @MainActor (URL) -> Bool = { url in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(url.absoluteString, forType: .string)
    }
    @State private var input = ""
    @State private var copiedLink: URL?
    @State private var copyFailed = false
    @FocusState private var focused: Bool
    private var terminal: PoolTerminal? { model.terminal?.id == terminalID ? model.terminal : nil }
    private var output: String { String((terminal?.output ?? "").suffix(64_000)) }
    private var acceptsText: Bool { terminal?.inputEnabled == true && terminal?.textInputEnabled == true }
    private var statusHint: String {
        guard terminal?.isRunning == true else { return model.t("This session has ended.") }
        if terminal?.isPendingSignIn == true {
            return model.t("Finish in the browser, or paste the code it shows. Closing cancels this sign-in.")
        }
        if terminal?.textInputEnabled != true {
            return model.t(model.snapshot.sessions.contains { $0.id == terminalID }
                           ? "Continue this conversation in Claude Desktop." : "Use the session controls to continue this quota check.")
        }
        return model.t("Closing this window keeps the session running.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(PoolPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(terminal?.title ?? model.t("Claude session")).font(.system(size: 15, weight: .semibold))
                    Text(model.t("Official Claude session")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.t("Close")) { model.perform(.closeTerminal(terminalID)) }
            }.padding(20)
            Divider()
            GeometryReader { viewport in
                ScrollView([.vertical, .horizontal]) {
                        Text(output.isEmpty ? model.t("Waiting for Claude…") : output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(red: 0.88, green: 0.89, blue: 0.87))
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(minWidth: 180 * NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).maximumAdvancement.width,
                                   minHeight: max(0, viewport.size.height - 36), alignment: .topLeading)
                            .padding(18)
                }.background(Color(red: 0.10, green: 0.115, blue: 0.12))
            }
            VStack(spacing: 12) {
                if let links = terminal?.links, !links.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.t("Session links")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(Array(links.enumerated()), id: \.offset) { index, url in
                                    HStack(spacing: 10) {
                                        Button { openLink(url) } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "link")
                                                Text(linkTitle(url)).lineLimit(1).truncationMode(.middle)
                                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                                            }.font(.system(size: 12)).foregroundStyle(PoolPalette.accent)
                                        }.buttonStyle(.plain).accessibilityLabel(model.t("Open link"))
                                            .accessibilityIdentifier("terminal.link.open.\(index)")
                                        Spacer(minLength: 0)
                                        Button(model.t(copiedLink == url ? "Copied" : "Copy link")) {
                                            copyFailed = !copyLink(url)
                                            if !copyFailed { copiedLink = url }
                                        }.font(.system(size: 11)).buttonStyle(.bordered)
                                            .accessibilityIdentifier("terminal.link.copy.\(index)")
                                    }
                                }
                            }
                        }.frame(height: min(108, CGFloat(links.count) * 30))
                        if copyFailed { Text(model.t("Could not copy link. Try again.")).font(.system(size: 11)).foregroundStyle(.red) }
                    }
                }
                // An ended sign-in can only be retried or closed; its dead terminal controls stay out of the way.
                if !(terminal?.isRunning != true && terminal?.retry != nil) {
                HStack(spacing: 8) {
                    TextField(model.t("Reply to Claude…"), text: $input).textFieldStyle(.roundedBorder)
                        .focused($focused).onSubmit(send).disabled(!acceptsText)
                    Button(model.t("Send"), action: send).buttonStyle(.borderedProminent)
                        .disabled(input.isEmpty || !acceptsText)
                }
                HStack(spacing: 7) {
                    key("Up", symbol: "arrow.up", value: "\u{1B}[A")
                    key("Down", symbol: "arrow.down", value: "\u{1B}[B")
                    key("Enter", symbol: "return", value: "\r")
                    key("Escape", symbol: "escape", value: "\u{1B}")
                    Spacer()
                    Button(model.t("Interrupt")) { model.perform(.cancelSession(terminalID)) }
                        .disabled(terminal?.isRunning != true)
                    if terminal?.canRequestExit == true || model.snapshot.sessions.contains(where: { $0.id == terminalID }) {
                        Button(model.t("Exit session")) { model.perform(.requestSessionExit(terminalID)) }
                            .disabled(terminal?.isRunning != true)
                    }
                }
                }
                if let failure = terminal?.failure {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failure).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("terminal.failure")
                        if let retry = terminal?.retry {
                            Button(model.t("Try again")) { model.perform(retry) }
                                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("terminal.retry")
                        }
                    }
                } else {
                    Text(statusHint)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(18)
        }.frame(width: 680, height: 520).background(PoolPalette.background)
            .preferredColorScheme(model.preferredColorScheme).onAppear { focused = true }
    }
    @ViewBuilder private func key(_ title: String, symbol: String, value: String) -> some View {
        let button = Button { model.perform(.sendTerminalKey(value)) } label: {
            Label(model.t(title), systemImage: symbol).font(.system(size: 11))
        }.disabled(terminal?.inputEnabled != true)
        if value == "\u{1B}" { button.keyboardShortcut(.escape, modifiers: []) }
        else { button }
    }
    private func linkTitle(_ url: URL) -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = parts?.percentEncodedPath ?? ""
        return (parts?.host ?? url.absoluteString) + (path == "/" ? "" : path)
    }
    private func send() {
        guard !input.isEmpty, acceptsText else { return }
        model.perform(.sendTerminalInput(input)); input = ""
    }
}
