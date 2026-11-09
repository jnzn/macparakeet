import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct AppProfilesView: View {
    @Bindable var viewModel: AppProfilesViewModel
    @State private var manualBundleID = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 180)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("App Profiles")
    }

    // MARK: Inner master sidebar (categories)

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { viewModel.selectedID },
                set: { if let id = $0 { viewModel.select(id: id) } }
            )) {
                ForEach(viewModel.store.profiles) { profile in
                    Text(profile.displayName.isEmpty ? "Untitled" : profile.displayName)
                        .opacity(profile.enabled ? 1 : 0.5)
                        .tag(profile.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                viewModel.select(id: profile.id)
                                showDeleteConfirm = true
                            } label: { Text("Delete") }
                        }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button { viewModel.newScript() } label: {
                Label("New", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    // MARK: Detail (apps ~15% / prompt ~42% / Try-it ~42%)

    @ViewBuilder
    private var detail: some View {
        if viewModel.draft != nil {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                TextField("Category name", text: Binding(
                    get: { viewModel.draft?.displayName ?? "" },
                    set: { viewModel.draft?.displayName = $0; viewModel.save() }
                ))
                .textFieldStyle(.roundedBorder)

                appsSection
                Divider()
                promptSection.frame(maxHeight: .infinity)
                Divider()
                tryItSection.frame(maxHeight: .infinity)
                footer
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .confirmationDialog(
                "Delete \"\(viewModel.draft.map { $0.displayName.isEmpty ? "Untitled" : $0.displayName } ?? "Untitled")\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { viewModel.deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            Text("No categories yet. Add one with \u{201C}New.\u{201D}")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applies to").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            FlowChips(items: viewModel.draft?.bundleIDs ?? []) { bundleID in
                viewModel.removeApp(bundleID: bundleID); viewModel.save()
            }
            if !viewModel.duplicateBundleIDs.isEmpty {
                Text("⚠︎ Also used by another category: \(viewModel.duplicateBundleIDs.sorted().joined(separator: ", ")). The earlier one wins.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    if let id = AppProfileAppPicker.pickBundleID() { viewModel.addApp(bundleID: id); viewModel.save() }
                } label: { Label("Add app…", systemImage: "plus.app") }
                TextField("or paste bundle ID (e.g. com.apple.mail)", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.addApp(bundleID: manualBundleID); manualBundleID = ""; viewModel.save() }
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { viewModel.draft?.promptOverride ?? "" },
                set: { viewModel.draft?.promptOverride = $0.isEmpty ? nil : $0; viewModel.save() }
            ))
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .border(DesignSystem.Colors.border)
            if !(viewModel.draft?.promptOverride?.contains("{{TRANSCRIPT}}") ?? false) {
                Text("Tip: include {{TRANSCRIPT}} where the dictated text goes.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var tryItSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it").font(DesignSystem.Typography.bodySmall).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                // Left: editable sample (as-is)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sample (as-is)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.previewInput)
                        .font(.body).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .border(DesignSystem.Colors.border)
                    Button {
                        Task { await viewModel.runPreview(sample: viewModel.previewInput) }
                    } label: {
                        if viewModel.isPreviewing { ProgressView().controlSize(.small) }
                        else { Label("Run", systemImage: "play.fill") }
                    }
                    .disabled(viewModel.previewInput.isEmpty || viewModel.isPreviewing)
                }
                // Right: cleaned output (read-only, live)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleaned").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        if let err = viewModel.previewError {
                            Text(err).font(.caption).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(viewModel.previewOutput ?? "")
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
                    .background(DesignSystem.Colors.surfaceElevated)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Enabled", isOn: Binding(
                get: { viewModel.draft?.enabled ?? true },
                set: { viewModel.draft?.enabled = $0; viewModel.save() }
            ))
            Spacer()
            Button(role: .destructive) { showDeleteConfirm = true } label: { Text("Delete category") }
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
                        Button { onRemove(item) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                }
            }
        }
    }
}
