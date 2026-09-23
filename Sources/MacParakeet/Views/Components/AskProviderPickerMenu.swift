import MacParakeetViewModels
import SwiftUI

/// Compact menu to pick which LLM answers *this* Ask/chat conversation. Hidden
/// unless the user has more than one provider set up. Selecting one only
/// overrides this conversation — the global default (Transforms, summaries,
/// dictation cleanup, other surfaces) is untouched.
///
/// Shared by the live meeting Ask pane and the Library transcript chat so both
/// surfaces show the same provider picker, and so the label always reflects the
/// provider that is actually answering (Apple On-Device by default when
/// available), rather than the persisted global provider's model list.
struct AskProviderPickerMenu: View {
    @Bindable var viewModel: TranscriptChatViewModel

    var body: some View {
        if viewModel.askProviderOptions.count > 1 {
            Menu {
                ForEach(viewModel.askProviderOptions) { option in
                    Button {
                        viewModel.selectedAskProviderID = option.id
                    } label: {
                        if option.id == viewModel.selectedAskProviderID {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .medium))
                    Text(viewModel.selectedAskProviderDisplayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(maxWidth: 150)
            .help("Choose which AI answers this conversation")
        }
    }
}
