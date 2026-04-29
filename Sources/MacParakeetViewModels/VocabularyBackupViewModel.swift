import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class VocabularyBackupViewModel {
    public enum Status: Equatable {
        case idle
        case exporting
        case exported(wordsCount: Int, snippetsCount: Int, filename: String)
        case importing
        case imported(VocabularyImportExportService.ImportResult)
        case failed(String)
    }

    public var status: Status = .idle
    public var pendingImport: VocabularyImportExportService.ImportPreview?
    public var conflictPolicy: VocabularyImportExportService.ConflictPolicy = .skip

    private var service: VocabularyImportExportService?
    private var onImportFinished: (() -> Void)?

    public init() {}

    public func configure(
        service: VocabularyImportExportService,
        onImportFinished: @escaping () -> Void
    ) {
        self.service = service
        self.onImportFinished = onImportFinished
    }

    public var isPresentingImportSheet: Bool { pendingImport != nil }

    public func suggestedFilename() -> String {
        service?.suggestedFilename() ?? "MacParakeet-Vocabulary.json"
    }

    /// Builds export bytes synchronously. Caller wires this to NSSavePanel.
    public func makeExportData() -> Data? {
        guard let service else { return nil }
        status = .exporting
        do {
            let bundle = try service.makeBundle()
            let data = try service.exportData()
            return tap(data) {
                status = .exported(
                    wordsCount: bundle.customWords.count,
                    snippetsCount: bundle.textSnippets.count,
                    filename: ""
                )
            }
        } catch {
            status = .failed("Couldn't create the backup: \(error.localizedDescription)")
            return nil
        }
    }

    public func confirmExportSucceeded(filename: String, wordsCount: Int, snippetsCount: Int) {
        status = .exported(
            wordsCount: wordsCount,
            snippetsCount: snippetsCount,
            filename: filename
        )
    }

    /// Loads + decodes a chosen file. On success, populates `pendingImport` so
    /// the UI shows the preview sheet. On failure, surfaces an error message.
    public func loadPreview(from url: URL) {
        guard let service else { return }
        status = .importing
        do {
            let data = try Data(contentsOf: url)
            let preview = try service.decodePreview(from: data)
            pendingImport = preview
            conflictPolicy = .skip
            status = .idle
        } catch let error as VocabularyImportExportService.ImportError {
            status = .failed(error.errorDescription ?? "Couldn't read the file.")
        } catch {
            status = .failed("Couldn't read the file: \(error.localizedDescription)")
        }
    }

    public func cancelImport() {
        pendingImport = nil
        status = .idle
    }

    public func applyImport() {
        guard let service, let preview = pendingImport else { return }
        status = .importing
        do {
            let result = try service.apply(preview: preview, policy: conflictPolicy)
            pendingImport = nil
            status = .imported(result)
            onImportFinished?()
        } catch {
            status = .failed("Couldn't apply the import: \(error.localizedDescription)")
        }
    }

    public func dismissStatus() {
        status = .idle
    }

    private func tap<T>(_ value: T, _ block: () -> Void) -> T {
        block()
        return value
    }
}
