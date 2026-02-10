import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationHistoryView: View {
    @Bindable var viewModel: DictationHistoryViewModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search dictations...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DesignSystem.Spacing.md)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                if viewModel.groupedDictations.isEmpty {
                    emptyState
                } else {
                    dictationList
                }
            }
            .frame(minWidth: 260)

            // Detail pane
            if let selected = viewModel.selectedDictation {
                DictationDetailView(
                    dictation: selected,
                    onDelete: {
                        viewModel.deleteDictation(selected)
                    },
                    onCopy: {
                        viewModel.copyToClipboard(selected)
                    }
                )
                .frame(minWidth: 300)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Select a dictation to view details")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minWidth: 300)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(viewModel.searchText.isEmpty ? "No dictations yet" : "No results found")
                .foregroundStyle(.secondary)
            Text(viewModel.searchText.isEmpty ? "Press Fn to start dictating" : "Try a different search term")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var dictationList: some View {
        List {
            ForEach(viewModel.groupedDictations, id: \.0) { dateHeader, dictations in
                Section(dateHeader) {
                    ForEach(dictations) { dictation in
                        DictationRowView(
                            dictation: dictation,
                            isSelected: viewModel.selectedDictation?.id == dictation.id,
                            onSelect: { viewModel.selectedDictation = dictation },
                            onCopy: { viewModel.copyToClipboard(dictation) },
                            onDelete: { viewModel.deleteDictation(dictation) }
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct DictationRowView: View {
    let dictation: Dictation
    let isSelected: Bool
    var onSelect: () -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack {
                    Text(formatTime(dictation.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(formatDuration(ms: dictation.durationMs))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(dictation.rawTranscript)
                    .lineLimit(2)
                    .font(.body)

                HStack {
                    if dictation.audioPath != nil {
                        Button {} label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }

                    Spacer()

                    Button(action: onCopy) {
                        Text("Copy")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.vertical, DesignSystem.Spacing.xs)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy") { onCopy() }
                .keyboardShortcut("c", modifiers: .command)
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
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
