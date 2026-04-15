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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.question)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(turn.response)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        if idx < state.history.count - 1 {
                            Divider()
                        }
                    }
                    if state.isListening {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(.red)
                            Text("Listening — release hotkey to send").font(.callout).foregroundStyle(.secondary)
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
}
