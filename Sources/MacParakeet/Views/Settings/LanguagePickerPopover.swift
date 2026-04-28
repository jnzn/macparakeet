import AppKit
import MacParakeetCore
import SwiftUI

/// Trigger button + popover wrapper used inline in settings rows.
///
/// The button shows the current selection's English label and a chevron.
/// Tapping opens the popover; commit dismisses it. Disabled state matches the
/// segmented engine picker so the row visually mutes when Whisper is inactive.
struct LanguagePickerButton: View {
    @Binding var selection: String
    var isDisabled: Bool

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            HStack(spacing: 6) {
                Text(WhisperLanguageCatalog.displayLabel(for: selection))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            LanguagePickerPopover(selection: $selection) {
                isShowing = false
            }
        }
    }
}

/// Searchable popover for the full Whisper language list.
///
/// Layout: search field (autofocused) → divider → scrollable list with
/// "Auto-detect" pinned at top, separated from the alphabetical full list.
/// Selection commits and dismisses on click or ⏎; Esc dismisses (handled by
/// the popover itself). Keyboard nav: ↑↓ moves the highlight, hover syncs it
/// to whichever row the cursor is over so the two input modes don't fight.
struct LanguagePickerPopover: View {
    @Binding var selection: String
    var onCommit: () -> Void

    @State private var query = ""
    @State private var highlightedCode: String
    @FocusState private var searchFocused: Bool

    init(selection: Binding<String>, onCommit: @escaping () -> Void) {
        self._selection = selection
        self.onCommit = onCommit
        // Seed highlight with the current selection so opening the popover
        // immediately points at the active language.
        self._highlightedCode = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
        }
        .frame(width: 280)
        .onAppear { searchFocused = true }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            TextField("Search languages", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { commitHighlighted() }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - List

    /// Visible rows after applying `query`. `auto` is included whenever the
    /// query is empty or the typed text plausibly matches "auto".
    private var visibleRows: [WhisperLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let results = WhisperLanguageCatalog.search(query)
        let includesAuto = trimmed.isEmpty
            || "auto".contains(trimmed)
            || "auto-detect".contains(trimmed)
        return includesAuto ? [WhisperLanguageCatalog.auto] + results : results
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rows = visibleRows
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.code) { index, language in
                            row(for: language)
                                .id(language.code)
                            if index == 0 && language.code == WhisperLanguageCatalog.autoCode && rows.count > 1 {
                                Divider().padding(.horizontal, 8)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
            .background(KeyEventCatcher(
                onUp: { moveHighlight(by: -1, proxy: proxy) },
                onDown: { moveHighlight(by: 1, proxy: proxy) },
                onReturn: { commitHighlighted() }
            ))
            .onAppear {
                proxy.scrollTo(highlightedCode, anchor: .center)
            }
            .onChange(of: query) { _, _ in
                if let first = visibleRows.first {
                    highlightedCode = first.code
                    proxy.scrollTo(first.code, anchor: .top)
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No matches")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    // MARK: - Row

    private func row(for language: WhisperLanguage) -> some View {
        let isSelected = language.code == selection
        let isHighlighted = language.code == highlightedCode

        return Button {
            commit(language.code)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? Color.accentColor : .clear)
                    .frame(width: 12)
                Text(language.englishName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !language.nativeName.isEmpty
                    && language.nativeName != language.englishName {
                    Text(language.nativeName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                highlightedCode = language.code
            }
        }
    }

    // MARK: - Keyboard nav

    private func moveHighlight(by delta: Int, proxy: ScrollViewProxy) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex(where: { $0.code == highlightedCode }) ?? 0
        let newIndex = max(0, min(rows.count - 1, currentIndex + delta))
        let code = rows[newIndex].code
        highlightedCode = code
        proxy.scrollTo(code, anchor: nil)
    }

    private func commitHighlighted() {
        if visibleRows.contains(where: { $0.code == highlightedCode }) {
            commit(highlightedCode)
        } else if let first = visibleRows.first {
            commit(first.code)
        }
    }

    private func commit(_ code: String) {
        selection = code
        onCommit()
    }
}

// MARK: - Key event catcher
//
// `.onKeyPress` only fires on the focused responder, which is the search
// `TextField`. Plumbing arrow keys through the text field is unreliable —
// arrows move the caret instead — so we drop a tiny `NSView` that lives
// alongside the list and intercepts ↑/↓/↩ at the AppKit responder chain. It
// never takes first responder away from the search field.

private struct KeyEventCatcher: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onReturn: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onReturn = onReturn
    }

    final class CatcherView: NSView {
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onReturn: (() -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    switch event.keyCode {
                    case 125: // arrow down
                        self.onDown?()
                        return nil
                    case 126: // arrow up
                        self.onUp?()
                        return nil
                    case 36, 76: // return / numpad enter
                        self.onReturn?()
                        return nil
                    default:
                        return event
                    }
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
