import AppKit
import MacParakeetViewModels
import SwiftUI

struct MeetingRecordingPanelView: View {
    @Bindable var viewModel: MeetingRecordingPanelViewModel
    @State private var autoScroll = true
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptContent
            Divider()
            footer
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 320, idealHeight: 460)
        .background(DesignSystem.Colors.surface)
    }

    private var header: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                statusDot

                Text(viewModel.statusTitle)
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                if viewModel.showsElapsedTime {
                    Text(viewModel.formattedElapsed)
                        .font(DesignSystem.Typography.timestamp.monospacedDigit())
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }

                if viewModel.showsAudioLevels {
                    DualAudioOrbView(
                        micLevel: viewModel.micLevel,
                        systemLevel: viewModel.systemLevel
                    )
                }

                Spacer(minLength: 0)

                Button(action: { viewModel.onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(DesignSystem.Colors.surfaceElevated)
                        )
                }
                .buttonStyle(.plain)
                .help("Hide meeting panel")
            }

            if viewModel.showsLaggingIndicator {
                Label("Transcript preview is catching up", systemImage: "exclamationmark.triangle.fill")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if viewModel.previewLines.isEmpty {
            VStack(spacing: DesignSystem.Spacing.md) {
                if viewModel.canStop {
                    BreathingEnsoView()
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.5))
                }

                Text(viewModel.canStop ? "Listening…" : "Transcription in progress…")
                    .font(.system(size: 13, weight: .light, design: .default))
                    .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignSystem.Spacing.lg)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.previewLines.enumerated()), id: \.element.id) { index, line in
                            let previousSource = index > 0 ? viewModel.previewLines[index - 1].source : nil
                            let speakerChanged = line.source != previousSource
                            MeetingRecordingTranscriptRow(line: line, showSpeakerHeader: speakerChanged)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .background(DesignSystem.Colors.background)
                .onAppear {
                    guard autoScroll, let last = viewModel.previewLines.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onChange(of: viewModel.previewLines.last?.id) { _, lastID in
                    guard autoScroll, let lastID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Text("\(viewModel.wordCount) words")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            Button {
                copyTranscript()
            } label: {
                Label(
                    viewModel.showCopiedConfirmation ? "Copied" : "Copy",
                    systemImage: viewModel.showCopiedConfirmation ? "checkmark" : "doc.on.doc"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(
                    viewModel.showCopiedConfirmation
                        ? DesignSystem.Colors.successGreen
                        : DesignSystem.Colors.textTertiary
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canCopy)
            .help("Copy transcript to clipboard")

            Spacer()

            Button {
                autoScroll.toggle()
            } label: {
                Label(autoScroll ? "Auto-scroll" : "Paused", systemImage: autoScroll ? "chevron.down.circle.fill" : "chevron.down.circle")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(autoScroll ? DesignSystem.Colors.accent : DesignSystem.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            Button(action: { viewModel.onStop?() }) {
                Text(viewModel.canStop ? "Stop Recording" : "Recording Stopped")
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(viewModel.canStop ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canStop)
            .help(viewModel.canStop ? "Stop meeting recording" : "Meeting recording is no longer active")
        }
        .padding(DesignSystem.Spacing.md)
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.transcriptText, forType: .string)
        viewModel.showCopiedConfirmation = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            viewModel.showCopiedConfirmation = false
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch viewModel.state {
        case .hidden, .recording:
            Circle()
                .fill(DesignSystem.Colors.successGreen)
                .frame(width: 8, height: 8)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warningAmber)
        }
    }
}

private struct MeetingRecordingTranscriptRow: View {
    let line: MeetingRecordingPreviewLine
    var showSpeakerHeader: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Thin colored left edge
            Rectangle()
                .fill(sourceColor.opacity(0.5))
                .frame(width: 2)
                .padding(.vertical, 1)

            if showSpeakerHeader {
                Text(line.speakerLabel)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(sourceColor)
                    .padding(.leading, DesignSystem.Spacing.sm)

                Text(line.timestamp)
                    .font(DesignSystem.Typography.timestamp)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .padding(.leading, 4)
            }

            Text(line.text)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.leading, showSpeakerHeader ? DesignSystem.Spacing.sm : DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var sourceColor: Color {
        switch line.source {
        case .microphone:
            return DesignSystem.Colors.accent
        case .system:
            return DesignSystem.Colors.speakerColor(for: 0)
        case .none:
            return DesignSystem.Colors.textSecondary
        }
    }
}

/// A gently breathing ensō circle for the empty listening state.
private struct BreathingEnsoView: View {
    @State private var breathing = false

    private let size: CGFloat = 36

    var body: some View {
        ZStack {
            // Outer ensō ring
            Circle()
                .stroke(
                    DesignSystem.Colors.accent.opacity(breathing ? 0.35 : 0.12),
                    lineWidth: 1.5
                )
                .frame(width: size, height: size)
                .scaleEffect(breathing ? 1.08 : 0.95)

            // Inner glow dot
            Circle()
                .fill(DesignSystem.Colors.accent.opacity(breathing ? 0.25 : 0.08))
                .frame(width: size * 0.3, height: size * 0.3)
                .scaleEffect(breathing ? 1.15 : 0.85)
        }
        .animation(
            .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
            value: breathing
        )
        .onAppear { breathing = true }
    }
}
