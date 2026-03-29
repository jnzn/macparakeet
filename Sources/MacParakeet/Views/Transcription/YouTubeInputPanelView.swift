import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct YouTubeInputPanelView: View {
    @Bindable var viewModel: TranscriptionViewModel
    var onTranscribe: () -> Void
    var onDismiss: () -> Void

    @FocusState private var isTextFieldFocused: Bool
    @State private var appeared = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // Header
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DesignSystem.Colors.youtubeRed.opacity(0.1))
                        .frame(width: 36, height: 36)

                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.youtubeRed.opacity(0.7))
                }

                Text("Transcribe a YouTube video")
                    .font(DesignSystem.Typography.sectionTitle)

                Spacer()
            }

            // URL input row
            HStack(spacing: 8) {
                Image(systemName: viewModel.isValidURL ? "checkmark.circle.fill" : "link")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.isValidURL ? DesignSystem.Colors.successGreen : .secondary)
                    .contentTransition(.symbolEffect(.replace))

                TextField("Paste a YouTube link", text: $viewModel.urlInput)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        if viewModel.isValidURL && !viewModel.isTranscribing {
                            onTranscribe()
                        }
                    }

                Button {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        viewModel.urlInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Text("Paste")
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.cardBackground)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        viewModel.isValidURL ? DesignSystem.Colors.successGreen.opacity(0.35) : DesignSystem.Colors.border,
                        lineWidth: 0.8
                    )
            )

            // Transcribe button (full width)
            Button {
                onTranscribe()
            } label: {
                HStack(spacing: 6) {
                    Label("Transcribe", systemImage: "arrow.right")
                }
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                        .fill(viewModel.isValidURL && !viewModel.isTranscribing
                              ? DesignSystem.Colors.accent
                              : DesignSystem.Colors.accent.opacity(0.35))
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isValidURL || viewModel.isTranscribing)

            // Footer text
            if viewModel.isTranscribing {
                Text("A transcription is already in progress.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
            } else {
                Text("Downloads from YouTube, then transcribes entirely on your Mac.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .scaleEffect(appeared ? 1.0 : 0.97)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            isTextFieldFocused = true
            withAnimation(.easeOut(duration: 0.15)) {
                appeared = true
            }
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}
