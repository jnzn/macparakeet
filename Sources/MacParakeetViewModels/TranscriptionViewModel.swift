import Foundation
import MacParakeetCore
import SwiftUI

@MainActor
@Observable
public final class TranscriptionViewModel {
    public var transcriptions: [Transcription] = []
    public var currentTranscription: Transcription?
    public var isTranscribing = false
    public var progress: String = ""
    public var transcriptionProgress: Double?
    public var errorMessage: String?
    public var isDragging = false
    public var urlInput: String = ""

    public var isValidURL: Bool {
        YouTubeURLValidator.isYouTubeURL(urlInput)
    }

    private var transcriptionService: TranscriptionServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?

    public init() {}

    public func configure(
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        loadTranscriptions()
    }

    public func loadTranscriptions() {
        guard let repo = transcriptionRepo else { return }
        transcriptions = (try? repo.fetchAll(limit: 50)) ?? []
    }

    public func transcribeFile(url: URL) {
        guard let service = transcriptionService else { return }
        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        errorMessage = nil

        Task {
            do {
                let result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.progress = phase
                        if phase.hasSuffix("%"),
                           let pctStr = phase.split(separator: " ").last?.dropLast(),
                           let pct = Double(pctStr) {
                            self?.transcriptionProgress = pct / 100.0
                        } else {
                            self?.transcriptionProgress = nil
                        }
                    }
                }
                currentTranscription = result
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            }
        }
    }

    public func transcribeURL() {
        guard let service = transcriptionService else { return }
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let videoID = YouTubeURLValidator.extractVideoID(url) else { return }

        // Check for existing transcription of the same video
        if let existing = try? transcriptionRepo?.fetchCompletedByVideoID(videoID) {
            currentTranscription = existing
            urlInput = ""
            return
        }

        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        errorMessage = nil
        urlInput = ""

        Task {
            do {
                let result = try await service.transcribeURL(urlString: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.progress = phase
                        // Parse percentage from phase text (e.g. "Downloading... XX%")
                        if phase.hasSuffix("%"),
                           let pctStr = phase.split(separator: " ").last?.dropLast(),
                           let pct = Double(pctStr) {
                            self?.transcriptionProgress = pct / 100.0
                        } else {
                            self?.transcriptionProgress = nil
                        }
                    }
                }
                currentTranscription = result
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            }
        }
    }

    public func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let ext = url.pathExtension.lowercased()
                guard AudioFileConverter.supportedExtensions.contains(ext) else { return }

                Task { @MainActor in
                    self.transcribeFile(url: url)
                }
            }
        }
        return true
    }

    public func retranscribe(_ original: Transcription) {
        guard let service = transcriptionService,
              let filePath = original.filePath,
              FileManager.default.fileExists(atPath: filePath) else { return }

        let url = URL(fileURLWithPath: filePath)
        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        errorMessage = nil
        currentTranscription = nil

        Task {
            do {
                var result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.progress = phase
                        if phase.hasSuffix("%"),
                           let pctStr = phase.split(separator: " ").last?.dropLast(),
                           let pct = Double(pctStr) {
                            self?.transcriptionProgress = pct / 100.0
                        } else {
                            self?.transcriptionProgress = nil
                        }
                    }
                }
                // Preserve original metadata
                result.fileName = original.fileName
                result.sourceURL = original.sourceURL
                try? transcriptionRepo?.save(result)
                currentTranscription = result
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                progress = ""
                transcriptionProgress = nil
                loadTranscriptions()
            }
        }
    }

    public func deleteTranscription(_ transcription: Transcription) {
        guard let repo = transcriptionRepo else { return }
        if transcription.sourceURL != nil, let audioPath = transcription.filePath {
            try? FileManager.default.removeItem(atPath: audioPath)
        }
        _ = try? repo.delete(id: transcription.id)
        if currentTranscription?.id == transcription.id {
            currentTranscription = nil
        }
        loadTranscriptions()
    }
}
