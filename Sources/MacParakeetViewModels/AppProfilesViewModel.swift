import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class AppProfilesViewModel {
    public let store: AppProfileStore

    /// Currently selected script id (tab). Nil when there are no scripts.
    public private(set) var selectedID: String?
    /// Editable working copy of the selected script. Bind editor fields to this.
    public var draft: AppProfile?

    public var previewInput: String = ""
    public private(set) var previewOutput: String?
    public private(set) var previewError: String?
    public private(set) var isPreviewing: Bool = false

    /// Injected so tests can stub the LLM. App passes a closure that calls
    /// `LLMService.formatTranscript`. Args: (sampleTranscript, promptTemplate).
    private let runPreviewClosure: @Sendable (String, String) async throws -> String

    public init(
        store: AppProfileStore,
        runPreview: @escaping @Sendable (String, String) async throws -> String
    ) {
        self.store = store
        self.runPreviewClosure = runPreview
        self.selectedID = store.profiles.first?.id
        self.draft = store.profiles.first
    }

    public func select(id: String) {
        selectedID = id
        draft = store.profiles.first { $0.id == id }
        previewOutput = nil
        previewError = nil
    }

    public func newScript() {
        let nextOrder = (store.profiles.map(\.sortOrder).max() ?? -1) + 1
        let new = AppProfile(
            id: "script-\(UUID().uuidString.prefix(8))",
            displayName: "New Script",
            bundleIDs: [],
            promptOverride: "Clean up ASR-transcribed speech. Output ONLY the corrected text.\n\nInput: {{TRANSCRIPT}}",
            enabled: true,
            sortOrder: nextOrder
        )
        store.upsert(new)
        select(id: new.id)
    }

    public func addApp(bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, var d = draft, !d.bundleIDs.contains(id) else { return }
        d.bundleIDs.append(id)
        draft = d
    }

    public func removeApp(bundleID: String) {
        draft?.bundleIDs.removeAll { $0 == bundleID }
    }

    public func save() {
        guard let d = draft else { return }
        store.upsert(d)
    }

    public func deleteSelected() {
        guard let id = selectedID,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        store.delete(id: id)
        let next = idx < store.profiles.count ? store.profiles[idx]
                 : (store.profiles.indices.contains(idx - 1) ? store.profiles[idx - 1] : nil)
        selectedID = next?.id
        draft = next
    }

    /// Bundle IDs in the draft that also appear in another script (resolution is
    /// first-match-by-sortOrder, so the earlier script wins). Drives the warning.
    public var duplicateBundleIDs: Set<String> {
        guard let d = draft else { return [] }
        let others = store.profiles.filter { $0.id != d.id }.flatMap(\.bundleIDs)
        return Set(d.bundleIDs).intersection(others)
    }

    public func runPreview(sample: String) async {
        guard let template = draft?.promptOverride, !template.isEmpty else {
            previewError = "Add a prompt to test."
            return
        }
        let requestedID = selectedID
        isPreviewing = true; previewError = nil; previewOutput = nil
        defer { if selectedID == requestedID { isPreviewing = false } }
        do {
            let out = try await runPreviewClosure(sample, template)
            guard selectedID == requestedID else { return }
            previewOutput = out
        } catch LLMError.notConfigured {
            guard selectedID == requestedID else { return }
            previewError = "Configure AI in Settings to test."
        } catch {
            guard selectedID == requestedID else { return }
            previewError = error.localizedDescription
        }
    }
}
