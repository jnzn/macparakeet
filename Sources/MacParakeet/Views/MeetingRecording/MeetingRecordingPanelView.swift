import AppKit
import MacParakeetCore
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

                Spacer(minLength: 0)

                if viewModel.wordCount > 0 {
                    Text("\(viewModel.wordCount) words")
                        .font(.system(size: 10, weight: .regular).monospacedDigit())
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.8))
                }

                if viewModel.showsAudioLevels {
                    DualAudioOrbView(
                        micLevel: viewModel.micLevel,
                        systemLevel: viewModel.systemLevel
                    )
                }
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
        let hasContent = !viewModel.previewLines.isEmpty

        ZStack {
            // Flower of life — always present, fades to watermark when text appears
            VStack(spacing: DesignSystem.Spacing.md) {
                if viewModel.canStop {
                    BreathingEnsoView()
                        .opacity(hasContent ? 0.15 : 1.0)
                        .animation(.easeInOut(duration: 0.8), value: hasContent)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.5))
                }

                if !hasContent {
                    Text(viewModel.canStop ? "Listening…" : "Transcription in progress…")
                        .font(.system(size: 13, weight: .light, design: .default))
                        .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.6))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // Transcript text overlay
            if hasContent {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(buildAttributedTranscript())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DesignSystem.Spacing.lg)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .id("transcript-bottom")
                    }
                    .onAppear {
                        guard autoScroll else { return }
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                    .onChange(of: viewModel.previewLines.count) { _, _ in
                        guard autoScroll else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(DesignSystem.Colors.background)
    }

    private var footer: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
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
            }

            if viewModel.canStop {
                SlideToStopView {
                    viewModel.onStop?()
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    private func buildAttributedTranscript() -> AttributedString {
        var result = AttributedString()
        var previousSource: AudioSource? = nil

        for line in viewModel.previewLines {
            let speakerChanged = line.source != previousSource

            if speakerChanged {
                if !result.characters.isEmpty {
                    result.append(AttributedString("\n\n"))
                }
                let color = sourceColor(for: line.source)
                var dot = AttributedString("● ")
                dot.font = .system(size: 10, weight: .medium)
                dot.foregroundColor = NSColor(color)
                result.append(dot)

                var speaker = AttributedString("\(line.speakerLabel)  ")
                speaker.font = .system(size: 11, weight: .medium)
                speaker.foregroundColor = NSColor(color.opacity(0.85))
                result.append(speaker)

                var timestamp = AttributedString("\(line.timestamp)\n")
                timestamp.font = .system(size: 10, weight: .regular).monospacedDigit()
                timestamp.foregroundColor = NSColor(DesignSystem.Colors.textTertiary.opacity(0.5))
                result.append(timestamp)
            }

            var text = AttributedString("\(line.text)\n")
            text.font = .system(size: 13, weight: .regular, design: .serif)
            text.foregroundColor = NSColor(DesignSystem.Colors.textPrimary.opacity(0.9))
            result.append(text)

            previousSource = line.source
        }

        return result
    }

    private func sourceColor(for source: AudioSource?) -> Color {
        switch source {
        case .microphone:
            return DesignSystem.Colors.accent
        case .system:
            return DesignSystem.Colors.speakerColor(for: 0)
        case .none:
            return DesignSystem.Colors.textSecondary
        }
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

/// A slowly rotating seed-of-life flower for the empty listening state.
/// Matches the flower head from the recording pill, without the stem.
private struct BreathingEnsoView: View {
    @State private var rotation: Double = 0
    @State private var glowBreathing = false

    private let size: CGFloat = 80
    private let circleRadius: CGFloat = 16
    private let strokeColor = DesignSystem.Colors.accent

    var body: some View {
        ZStack {
            // Center glow
            Circle()
                .fill(strokeColor.opacity(glowBreathing ? 0.5 : 0.2))
                .frame(width: circleRadius * 2, height: circleRadius * 2)
                .blur(radius: 8)
                .scaleEffect(glowBreathing ? 1.2 : 0.9)

            // Center circle
            Circle()
                .stroke(strokeColor.opacity(0.7), lineWidth: 1.2)
                .frame(width: circleRadius * 2, height: circleRadius * 2)

            // 6 outer circles (seed of life)
            ForEach(0..<6, id: \.self) { i in
                Circle()
                    .stroke(strokeColor.opacity(0.5), lineWidth: 1.2)
                    .frame(width: circleRadius * 2, height: circleRadius * 2)
                    .offset(x: circleRadius * CGFloat(cos(Double(i) * .pi / 3)),
                            y: circleRadius * CGFloat(sin(Double(i) * .pi / 3)))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                glowBreathing = true
            }
        }
    }
}

/// Slide-to-stop control — drag the knob to the right to end the recording.
private struct SlideToStopView: View {
    var onStop: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var completed = false

    private let trackHeight: CGFloat = 40
    private let knobSize: CGFloat = 34
    private let knobPadding: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let maxOffset = geo.size.width - knobSize - knobPadding * 2
            let progress = min(1, max(0, dragOffset / maxOffset))

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(DesignSystem.Colors.errorRed.opacity(0.12))
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.errorRed.opacity(0.2), lineWidth: 0.5)
                    )

                // Label
                Text("Slide to end recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.errorRed.opacity(0.5 * (1 - progress)))
                    .frame(maxWidth: .infinity)

                // Knob
                Circle()
                    .fill(completed ? DesignSystem.Colors.errorRed : DesignSystem.Colors.errorRed.opacity(0.8))
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Image(systemName: completed ? "checkmark" : "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: DesignSystem.Colors.errorRed.opacity(0.3), radius: 4)
                    .offset(x: knobPadding + dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !completed else { return }
                                dragOffset = min(maxOffset, max(0, value.translation.width))
                            }
                            .onEnded { _ in
                                guard !completed else { return }
                                if dragOffset >= maxOffset * 0.85 {
                                    completed = true
                                    dragOffset = maxOffset
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        onStop()
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(height: trackHeight)
    }
}
