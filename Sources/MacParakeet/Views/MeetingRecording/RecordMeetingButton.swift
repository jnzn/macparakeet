import SwiftUI

/// Primary CTA in the Meetings page header. Tinted-red pill with a subtle
/// hover lift — restrained enough to coexist with content without dominating,
/// confident enough to feel like a recording button.
struct RecordMeetingButton: View {
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(DesignSystem.Colors.errorRed)
                    .frame(width: 8, height: 8)

                Text("Record Meeting")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.errorRed.opacity(fillOpacity))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                DesignSystem.Colors.errorRed.opacity(strokeOpacity),
                                lineWidth: 0.5
                            )
                    )
            )
            .scaleEffect(pressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignSystem.Colors.errorRed)
        .onHover { hovered = $0 }
        .pressEvents(onPress: { pressed = true }, onRelease: { pressed = false })
        .animation(DesignSystem.Animation.hoverTransition, value: hovered)
        .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private var fillOpacity: Double { hovered ? 0.18 : 0.12 }
    private var strokeOpacity: Double { hovered ? 0.36 : 0.25 }
}

private extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded { _ in onRelease() }
        )
    }
}
