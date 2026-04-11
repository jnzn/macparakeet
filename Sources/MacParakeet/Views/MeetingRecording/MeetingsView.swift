import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct MeetingsView: View {
    @Bindable var viewModel: TranscriptionLibraryViewModel
    let onStartMeeting: () -> Void
    let onSelectTranscription: (Transcription) -> Void

    @State private var pendingDelete: Transcription?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            meetingList
        }
        .searchable(text: $viewModel.searchText, prompt: "Search meetings")
        .onAppear { viewModel.loadTranscriptions() }
        .alert(
            "Delete Meeting?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let transcription = pendingDelete {
                    viewModel.deleteTranscription(transcription)
                    pendingDelete = nil
                }
            }
        } message: {
            if let pending = pendingDelete {
                Text("\"\(pending.fileName)\" will be permanently deleted.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Meetings")
                .font(DesignSystem.Typography.pageTitle)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer()

            recordMeetingButton
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.lg)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    // MARK: - Record Meeting Button

    private var recordMeetingButton: some View {
        Button(action: onStartMeeting) {
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
                    .fill(DesignSystem.Colors.errorRed.opacity(0.12))
                    .overlay(
                        Capsule()
                            .strokeBorder(DesignSystem.Colors.errorRed.opacity(0.25), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignSystem.Colors.errorRed)
    }

    // MARK: - Meeting List

    @ViewBuilder
    private var meetingList: some View {
        if viewModel.filteredTranscriptions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.filteredTranscriptions) { transcription in
                        MeetingRowCard(
                            transcription: transcription,
                            searchText: viewModel.searchText,
                            onTap: { onSelectTranscription(transcription) },
                            menuContent: { menuItems(for: transcription) }
                        )
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.lg)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func menuItems(for transcription: Transcription) -> some View {
        Button {
            onSelectTranscription(transcription)
        } label: {
            Label("Open", systemImage: "doc.text")
        }

        Button {
            viewModel.toggleFavorite(transcription)
        } label: {
            Label(
                transcription.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: transcription.isFavorite ? "star.slash" : "star"
            )
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = transcription
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()

            Image(systemName: viewModel.searchText.isEmpty ? "waveform.badge.mic" : "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            Text(viewModel.searchText.isEmpty
                 ? "No meetings recorded yet"
                 : "No matching meetings")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Text(viewModel.searchText.isEmpty
                 ? "Press Record Meeting to capture system audio and transcribe locally."
                 : "Try different words or clear your search.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)

            if viewModel.searchText.isEmpty {
                Text("For the cleanest separation between you and other participants, use headphones.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignSystem.Spacing.xl)
    }
}
