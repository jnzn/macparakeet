import SwiftUI
import MacParakeetCore

struct DictationDetailView: View {
    let dictation: Dictation
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(formatDate(dictation.createdAt))
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Text(formatDuration(ms: dictation.durationMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(DesignSystem.Spacing.lg)

            Divider()

            // Audio playback (if audio exists)
            if dictation.audioPath != nil {
                HStack {
                    Button {} label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.bordered)

                    // Placeholder waveform/scrubber
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)

                    Text(formatDuration(ms: dictation.durationMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(DesignSystem.Spacing.lg)

                Divider()
            }

            // Transcript
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text("Transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(dictation.cleanTranscript ?? dictation.rawTranscript)
                        .font(DesignSystem.Typography.body)
                        .textSelection(.enabled)
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Divider()

            // Actions
            HStack {
                Button(action: { onCopy?() }) {
                    Label("Copy", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive, action: { onDelete?() }) {
                    Label("Delete Dictation", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
