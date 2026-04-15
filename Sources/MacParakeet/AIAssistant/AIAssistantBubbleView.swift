import SwiftUI
import MacParakeetCore

/// Observable state for a single bubble session. Held by the bubble
/// controller; rebuilt on dismiss so stale turns don't leak across sessions.
@MainActor
@Observable
final class AIAssistantBubbleState {
    var history: [AIAssistantTurn] = []
    var currentInput: String = ""
    var isThinking: Bool = false
    var isListening: Bool = false
    /// Live ASR partial rendered under the "Listening…" indicator while the
    /// user is holding the AI hotkey. Populated via the
    /// `.macParakeetStreamingPartial` notification pipeline — only flows when
    /// the user has "Live transcript overlay" enabled in Settings.
    var listeningPartialText: String = ""
    var errorMessage: String? = nil
}

struct AIAssistantBubbleView: View {
    @Bindable var state: AIAssistantBubbleState
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(state.history.enumerated()), id: \.offset) { idx, turn in
                        VStack(alignment: .leading, spacing: 8) {
                            // User question — italic, muted, compact.
                            Text(turn.question)
                                .font(.callout.italic())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            // LLM response — Apple's "New York" serif at
                            // reading size. System-bundled on macOS; gives
                            // the bubble a warm editorial feel without
                            // shipping proprietary fonts (Claude's
                            // Copernicus is not distributable).
                            //
                            // Renders inline markdown via AttributedString.
                            // Covers **bold**, *italic*, `code`, links, and
                            // ~~strikethrough~~. Headings, lists, block
                            // code, tables fall back to literal characters —
                            // upgrade to MarkdownUI package in a later pass
                            // if richer rendering becomes important.
                            Text(Self.renderMarkdown(turn.response))
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(.primary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                        if idx < state.history.count - 1 {
                            Divider().padding(.vertical, 4)
                        }
                    }
                    if state.isListening {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                    .foregroundStyle(.red)
                                Text("Listening — release hotkey to send").font(.callout).foregroundStyle(.secondary)
                            }
                            if !state.listeningPartialText.isEmpty {
                                Text(state.listeningPartialText)
                                    .font(.body)
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .italic()
                            }
                        }
                    }
                    if state.isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let err = state.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if state.history.isEmpty && !state.isThinking && !state.isListening && state.errorMessage == nil {
                        Text("Hold the hotkey and speak, or type a question.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            HStack(spacing: 6) {
                TextField("Ask a question…", text: $state.currentInput, axis: .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.isThinking)
                    .onSubmit { submit() }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 420, height: 280)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var canSubmit: Bool {
        !state.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !state.isThinking
    }

    private func submit() {
        guard canSubmit else { return }
        let q = state.currentInput
        state.currentInput = ""
        onSubmit(q)
    }

    /// Parse Claude/Codex output as markdown so `**bold**`, `*italic*`,
    /// `` `code` ``, and links render as formatted text. `.full` interprets
    /// paragraph breaks and inline elements; `inlineOnlyPreservingWhitespace`
    /// would strip newlines, which is wrong for multi-paragraph responses.
    /// Falls back to plain text on parse failure.
    private static func renderMarkdown(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full
        )
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }
}
