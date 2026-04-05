import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

private struct MeetingRecordingCheckmarkView: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(DesignSystem.Colors.successGreen)
    }
}

private struct PulsingRecordDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(DesignSystem.Colors.recordingRed)
            .frame(width: 10, height: 10)
            .shadow(color: DesignSystem.Colors.recordingRed.opacity(0.6), radius: pulse ? 8 : 2)
            .scaleEffect(pulse ? 1.05 : 0.92)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

struct MeetingRecordingPillView: View {
    @Bindable var viewModel: MeetingRecordingPillViewModel

    var body: some View {
        VStack(spacing: 0) {
            pillContent
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .recording:
            recordingPill
        case .transcribing:
            statusPill(
                icon: AnyView(ProgressView().controlSize(.small).tint(.white)),
                title: "Transcribing meeting"
            )
        case .completed:
            statusPill(
                icon: AnyView(MeetingRecordingCheckmarkView()),
                title: "Saved to library"
            )
        case .error(let message):
            statusPill(
                icon: AnyView(
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                ),
                title: message
            )
        }
    }

    private var recordingPill: some View {
        VStack(alignment: .leading, spacing: viewModel.isExpanded && !viewModel.previewLines.isEmpty ? 10 : 0) {
            HStack(spacing: 12) {
                PulsingRecordDot()

                Text(viewModel.formattedElapsed)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 42, alignment: .leading)

                DualAudioLevelView(micLevel: viewModel.micLevel, systemLevel: viewModel.systemLevel)

                Spacer(minLength: 0)

                if !viewModel.previewLines.isEmpty {
                    Button {
                        viewModel.isExpanded.toggle()
                    } label: {
                        Image(systemName: viewModel.isExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.isExpanded ? "Collapse live transcript" : "Expand live transcript")
                }

                Button(action: { viewModel.onStop?() }) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .padding(8)
                        .background(
                            Circle()
                                .fill(DesignSystem.Colors.recordingRed.opacity(0.92))
                                .shadow(color: DesignSystem.Colors.recordingRed.opacity(0.45), radius: 6)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop meeting recording")
            }

            if viewModel.isExpanded && !viewModel.previewLines.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.previewLines) { line in
                        previewLineView(line)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(pillBackground)
    }

    private func statusPill(icon: AnyView, title: String) -> some View {
        HStack(spacing: 10) {
            icon
            Text(title)
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(pillBackground)
    }

    private var pillBackground: some View {
        let cornerRadius: CGFloat = viewModel.isExpanded && !viewModel.previewLines.isEmpty ? 18 : 999
        return RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DesignSystem.Colors.pillBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }

    private func previewLineView(_ line: MeetingRecordingPreviewLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.timestamp)
                    .font(DesignSystem.Typography.micro.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))

                Text(line.speakerLabel)
                    .font(DesignSystem.Typography.micro.weight(.semibold))
                    .foregroundStyle(color(for: line.source))
            }

            Text(line.text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func color(for source: AudioSource?) -> Color {
        switch source {
        case .microphone:
            return DesignSystem.Colors.accent
        case .system:
            return DesignSystem.Colors.successGreen
        case nil:
            return .white.opacity(0.7)
        }
    }
}
