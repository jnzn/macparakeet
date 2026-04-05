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

struct MeetingRecordingPillView: View {
    @Bindable var viewModel: MeetingRecordingPillViewModel
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            pillContent
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onHover { hovering in
            isHovered = hovering
        }
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
        sacredRecordingPill
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

    private var sacredRecordingPill: some View {
        VStack(spacing: 0) {
            MerkabaPillIcon(
                isAnimating: true,
                audioLevel: max(viewModel.micLevel, viewModel.systemLevel)
            )
        }
        .frame(width: 48, height: 84)
        .background(
            Capsule()
                .fill(Color(white: isHovered ? 0.2 : 0.12).opacity(0.9))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(isHovered ? 0.15 : 0.08), lineWidth: 0.5)
                )
                .animation(.easeOut(duration: 0.15), value: isHovered)
        )
        .clipShape(Capsule())
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .padding(8)
        .overlay(alignment: .top) {
            if isHovered && viewModel.elapsedSeconds > 0 {
                Text(viewModel.formattedElapsed)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .offset(y: -24)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording meeting, \(viewModel.formattedElapsed) elapsed")
    }

    private var pillBackground: some View {
        RoundedRectangle(cornerRadius: 999)
            .fill(DesignSystem.Colors.pillBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }
}
