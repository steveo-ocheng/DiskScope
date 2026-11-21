import SwiftUI

/// Side panel for asking Claude about the current scan. Needs an `AskClaudeModel` environment object.
/// `contextProvider` builds the disk summary; it's called only when a conversation starts or
/// when the user opens "What gets sent".
struct AskClaudePanel: View {
    @EnvironmentObject var claude: AskClaudeModel
    let contextProvider: () -> String

    @State private var question = ""
    @State private var showContext = false
    @State private var previewContext: String?
    @FocusState private var inputFocused: Bool

    static let starters = [
        "What's using the most space?",
        "What can I safely delete?",
        "Why doesn't the scan add up to the disk's used space?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if claude.isReady {
                conversation
                Divider()
                footer
            } else {
                setup
            }
        }
        .frame(minWidth: 280, idealWidth: 340)
        .onAppear { claude.refreshKeyStatus() }
        .onChange(of: claude.returnedQuestion) { _, returned in
            if let returned, question.isEmpty { question = returned }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Ask Claude", systemImage: "sparkles").font(.headline)
                Spacer()
                if !claude.transcript.isEmpty {
                    Button("Clear") { claude.clear(); previewContext = nil }
                        .controlSize(.small)
                        .help("Start a new conversation with a fresh summary")
                }
            }
            Text(verbatim: "Sends a summary of names and sizes to Anthropic when you press Send. Never file contents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: claude.enabled
                 ? "Add your Anthropic API key to start asking questions about this scan."
                 : "Ask Claude is off. Turn it on and add your Anthropic API key in Settings to ask questions about this scan.")
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "DiskScope sends only folder and file names, sizes and dates — never file contents — and only when you press Send. Usage is billed to your API key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !claude.hasKey {
                Divider()
                Text("How to get an API key").font(.headline)
                APIKeyGuide()
                    .font(.callout)
            }
            SettingsLink { Text(claude.hasKey ? "Open Settings…" : "Open Settings to Paste Your Key…") }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if claude.transcript.isEmpty {
                        Text("Try asking:").font(.caption).foregroundStyle(.secondary)
                        ForEach(Self.starters, id: \.self) { starter in
                            Button { send(starter) } label: {
                                Text(starter).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    ForEach(claude.transcript) { turn in
                        TurnView(turn: turn, streaming: claude.isStreaming && turn.id == claude.transcript.last?.id)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: claude.transcript.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = claude.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(verbatim: error).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { claude.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
            }
            if let notice = claude.notice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("What gets sent", isExpanded: $showContext) {
                contextPreview
            }
            .font(.caption)
            .onChange(of: showContext) { _, open in
                if open, claude.sentContext == nil, previewContext == nil { previewContext = contextProvider() }
            }

            HStack(alignment: .bottom, spacing: 6) {
                TextField("Ask about this scan…", text: $question, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { send(question) }
                    .disabled(claude.isStreaming)
                if claude.isStreaming {
                    Button { claude.cancel() } label: { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.borderless)
                        .font(.title2)
                        .help("Stop")
                } else {
                    Button { send(question) } label: { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.borderless)
                        .font(.title2)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (⌘↩)")
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder private var contextPreview: some View {
        let text = claude.sentContext ?? previewContext ?? ""
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: claude.sentContext != nil
                 ? "Sent with your first question (\(Self.sizeEstimate(text))):"
                 : "Will be sent with your first question (\(Self.sizeEstimate(text))):")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            if claude.sentContext == nil {
                Button("Refresh") { previewContext = contextProvider() }.controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !claude.isStreaming else { return }
        question = ""
        claude.ask(trimmed, context: contextProvider())
        previewContext = nil
        inputFocused = true
    }

    static func sizeEstimate(_ text: String) -> String {
        let bytes = text.utf8.count
        // ~4 characters per token is a fair rule of thumb for English-ish text.
        return "\(Format.bytes(Int64(bytes))), about \(Format.count(max(bytes / 4, 1))) tokens"
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    let streaming: Bool

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(verbatim: turn.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18)))
            }
        case .assistant:
            if turn.text.isEmpty && streaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            } else {
                Text(AnswerFormatting.render(turn.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

enum AnswerFormatting {
    /// Inline Markdown (bold, italics, code) with every link and image reference removed:
    /// answers can echo file names from the user's disk, so nothing in them is clickable.
    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        let linked = text.runs.filter { $0.link != nil || $0.imageURL != nil }.map(\.range)
        for range in linked {
            text[range].link = nil
            text[range].imageURL = nil
        }
        return text
    }
}

/// The Ask Claude tab for the app's Settings window.
struct ClaudeSettingsView: View {
    @EnvironmentObject var claude: AskClaudeModel
    @State private var draft = ""
    @State private var message: String?
    @State private var failed = false
    @State private var guideExpanded = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable Ask Claude", isOn: $claude.enabled)
                Text(verbatim: "Ask questions about a scan in a side panel. This is the only DiskScope feature that uses the network.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("How to get an API key", isExpanded: $guideExpanded) {
                    APIKeyGuide()
                        .padding(.top, 6)
                }
            }

            Section("Anthropic API key") {
                if claude.hasKey {
                    HStack {
                        Label("API key saved in your Keychain", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove Key", role: .destructive) {
                            do { try claude.removeKey(); show("Key removed.", failed: false) }
                            catch { show(error.localizedDescription, failed: true) }
                        }
                    }
                }
                HStack {
                    SecureField(claude.hasKey ? "Replace with a new key" : "sk-ant-…", text: $draft)
                        .textContentType(.password)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message {
                    Text(verbatim: message).font(.callout).foregroundStyle(failed ? .red : .secondary)
                }
                Text(verbatim: "The key is stored only in your Mac's Keychain (not synced) and sent only to api.anthropic.com. Questions are billed by Anthropic to that key's account; a typical question costs a few cents. Remove Key deletes it from this Mac; you can also revoke it in the Claude Console at any time.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What's shared") {
                Text(verbatim: "When you press Send, DiskScope sends Anthropic your question and, with the first question of a conversation, a summary of the scan: folder and file names and paths, sizes, item counts and dates. It never sends file contents. You can see the exact text under “What gets sent” in the panel. Model: \(ClaudeClient.model).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .onAppear {
            claude.refreshKeyStatus()
            guideExpanded = !claude.hasKey
        }
    }

    private func save() {
        do {
            try claude.saveKey(draft)
            draft = ""
            show("Key saved.", failed: false)
        } catch {
            show(error.localizedDescription, failed: true)
        }
    }

    private func show(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
    }
}

/// Step-by-step help for getting an Anthropic API key, with links into the Claude Console.
struct APIKeyGuide: View {
    enum Links {
        static let console = URL(string: "https://platform.claude.com/")!
        static let billing = URL(string: "https://platform.claude.com/settings/billing")!
        static let keys = URL(string: "https://platform.claude.com/settings/keys")!
        static let limits = URL(string: "https://platform.claude.com/settings/limits")!
        static let pricing = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Sign in to the Claude Console, or create an account. A Claude.ai Pro or Max subscription doesn't cover this: the API is billed separately, pay as you go.",
                 link: ("Open Claude Console", Links.console))
            step(2, "Add credit under Settings › Billing. A typical question costs a few cents.",
                 link: ("Open Billing", Links.billing))
            step(3, "Under Settings › API Keys, click Create Key and name it “DiskScope”.",
                 link: ("Open API Keys", Links.keys))
            step(4, "Copy the key. It starts with sk-ant- and is shown only once. Paste it into DiskScope › Settings › Ask Claude and click Save.",
                 link: nil)
            step(5, "Optional: cap your spending with a monthly limit under Settings › Limits.",
                 link: ("Open Limits", Links.limits))
            Link("API pricing ↗", destination: Links.pricing)
                .padding(.leading, 26)
        }
    }

    private func step(_ number: Int, _ text: String, link: (title: String, url: URL)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    Link("\(link.title) ↗", destination: link.url)
                }
            }
        }
    }
}
