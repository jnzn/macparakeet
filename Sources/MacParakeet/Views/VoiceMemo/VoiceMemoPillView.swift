import MacParakeetViewModels
import SwiftUI

struct VoiceMemoPillView: View {
    @Bindable var viewModel: VoiceMemoPillViewModel
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.5
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            pillContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
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
                icon: AnyView(SpinnerRingView(size: 18)),
                title: "Transcribing…"
            )
            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
        case .completed:
            iconPill {
                MemoCompletionCheckmarkView()
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity).animation(.spring(response: 0.35, dampingFraction: 0.7)))
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
        HStack(spacing: 10) {
            ZStack {
                // Outer pulse ring — visually distinct from meeting pill's solid dot
                Circle()
                    .fill(DesignSystem.Colors.recordingRed.opacity(pulseOpacity * 0.4))
                    .frame(width: 22, height: 22)
                    .scaleEffect(pulseScale)

                // Inner solid dot
                Circle()
                    .fill(DesignSystem.Colors.recordingRed)
                    .frame(width: 10, height: 10)
                    .shadow(color: DesignSystem.Colors.recordingRed.opacity(0.6), radius: 4)
            }
            .frame(width: 22, height: 22)
            .onAppear { startPulse() }

            VStack(alignment: .leading, spacing: 1) {
                Text("Recording")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(viewModel.formattedElapsed)
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(isHovered ? DesignSystem.Colors.meetingPillBackgroundHover : DesignSystem.Colors.meetingPillBackground)
                .overlay(
                    Capsule()
                        .stroke(
                            isHovered ? DesignSystem.Colors.meetingPillStrokeHover : DesignSystem.Colors.meetingPillStroke,
                            lineWidth: 0.5
                        )
                )
                .animation(DesignSystem.Animation.meetingPillHover, value: isHovered)
        )
        .contentShape(Capsule())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { viewModel.onStop?() }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(DesignSystem.Animation.meetingPillHover, value: isHovered)
        .padding(DesignSystem.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice memo recording, \(viewModel.formattedElapsed) elapsed. Tap to stop.")
        .accessibilityAction { viewModel.onStop?() }
    }

    private func startPulse() {
        withAnimation(
            .easeInOut(duration: 1.1)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.6
            pulseOpacity = 0.0
        }
    }

    private func iconPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.meetingPillBackground)
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
                    )
            )
            .padding(DesignSystem.Spacing.sm)
    }

    private func statusPill(icon: AnyView, title: String) -> some View {
        HStack(spacing: 10) {
            icon
            Text(title)
                .font(DesignSystem.Typography.meetingPillStatus)
                .foregroundStyle(DesignSystem.Colors.meetingPillText)
                .lineLimit(2)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.md - DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 999)
                .fill(DesignSystem.Colors.pillBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 999)
                        .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
                )
                .cardShadow(DesignSystem.Shadows.meetingPill)
        )
        .padding(DesignSystem.Spacing.sm)
    }
}

// MARK: - Checkmark (local copy — avoids coupling to MeetingRecordingPillView)

private struct MemoCompletionCheckmarkView: View {
    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0
    private let color = DesignSystem.Colors.successGreen

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            MemoCheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .padding(7)
        }
        .frame(width: 26, height: 26)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { ringTrim = 1 }
            withAnimation(.easeOut(duration: 0.25).delay(0.25)) { checkTrim = 1 }
        }
    }
}

private struct MemoCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.22, y: h * 0.52))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.28))
        return path
    }
}
