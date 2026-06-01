import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct AppProfilesView: View {
    @Bindable var viewModel: AppProfilesViewModel
    @State private var manualBundleID = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            Divider()
            if viewModel.draft != nil {
                editor
            } else {
                emptyState
            }
            Spacer()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("App Profiles")
    }

    // Scrollable tab strip, one pill per script, + New.
    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.store.profiles) { profile in
                    Button {
                        viewModel.select(id: profile.id)
                    } label: {
                        Text(profile.displayName.isEmpty ? "Untitled" : profile.displayName)
                            .font(DesignSystem.Typography.bodySmall.weight(.medium))
                            .opacity(profile.enabled ? 1 : 0.5)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                Capsule().fill(profile.id == viewModel.selectedID
                                    ? DesignSystem.Colors.surfaceElevated
                                    : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    viewModel.newScript()
                } label: {
                    Label("New script", systemImage: "plus")
                        .font(DesignSystem.Typography.bodySmall)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        Text("No scripts yet. Add one with \u{201C}New script.\u{201D}")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var editor: some View {
        if var currentDraft = viewModel.draft {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                TextField("Script name", text: Binding(
                    get: { viewModel.draft?.displayName ?? "" },
                    set: { newValue in
                        currentDraft.displayName = newValue
                        viewModel.draft = currentDraft
                        viewModel.save()
                    }
                ))
                .textFieldStyle(.roundedBorder)

                appsSection

                Text("Prompt")
                    .font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { viewModel.draft?.promptOverride ?? "" },
                    set: { newValue in
                        currentDraft.promptOverride = newValue.isEmpty ? nil : newValue
                        viewModel.draft = currentDraft
                        viewModel.save()
                    }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .border(DesignSystem.Colors.border)
                if !(viewModel.draft?.promptOverride?.contains("{{TRANSCRIPT}}") ?? false) {
                    Text("Tip: include {{TRANSCRIPT}} where the dictated text goes.")
                        .font(.caption).foregroundStyle(.orange)
                }

                tryItBox

                HStack {
                    Toggle("Enabled", isOn: Binding(
                        get: { viewModel.draft?.enabled ?? true },
                        set: { newValue in
                            currentDraft.enabled = newValue
                            viewModel.draft = currentDraft
                            viewModel.save()
                        }
                    ))
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: { Text("Delete script") }
                }
                .confirmationDialog(
                    "Delete \"\(viewModel.draft?.displayName.isEmpty == false ? viewModel.draft!.displayName : "Untitled")\"?",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        viewModel.deleteSelected()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applies to")
                .font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            FlowChips(items: viewModel.draft?.bundleIDs ?? []) { bundleID in
                viewModel.removeApp(bundleID: bundleID)
                viewModel.save()
            }
            if !viewModel.duplicateBundleIDs.isEmpty {
                Text("⚠︎ Also used by another script: \(viewModel.duplicateBundleIDs.sorted().joined(separator: ", ")). The earlier script wins.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    if let id = AppProfileAppPicker.pickBundleID() {
                        viewModel.addApp(bundleID: id); viewModel.save()
                    }
                } label: { Label("Add app…", systemImage: "plus.app") }
                TextField("or paste bundle ID (e.g. com.apple.mail)", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.addApp(bundleID: manualBundleID); manualBundleID = ""; viewModel.save()
                    }
            }
        }
    }

    private var tryItBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            HStack {
                TextField("Sample dictation…", text: $viewModel.previewInput)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await viewModel.runPreview(sample: viewModel.previewInput) }
                } label: {
                    if viewModel.isPreviewing { ProgressView().controlSize(.small) }
                    else { Text("Run") }
                }
                .disabled(viewModel.previewInput.isEmpty || viewModel.isPreviewing)
            }
            if let out = viewModel.previewOutput {
                Text(out).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.Colors.surfaceElevated)
            }
            if let err = viewModel.previewError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Small horizontal wrap of removable chips.
private struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 4) {
                        Text(item).font(.caption)
                        Button { onRemove(item) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                }
            }
        }
    }
}
