import Foundation
import MacParakeetCore

/// Runs meeting transcription (and optional Whisper enhancement + AI titling)
/// detached from the meeting flow state machine, so a new recording can start
/// while a previous one is still being transcribed.
///
/// Each `process(...)` call owns one job keyed by the recording's session id.
/// `processingCount` drives the menu-bar "N processing" indicator. Jobs never
/// send events back into the flow state machine — they operate only on their
/// own captured `MeetingRecordingOutput`, which is why concurrent recordings
/// can't collide on shared completion state.
@MainActor
final class MeetingBackgroundProcessor {
    private let transcriptionService: TranscriptionServiceProtocol
    private let meetingRecordingService: MeetingRecordingServiceProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let conversationRepo: ChatConversationRepositoryProtocol
    private var llmService: LLMServiceProtocol?
    private let onTranscriptionReady: (Transcription) -> Void
    private let onProcessingCountChanged: (Int) -> Void

    private var jobs: [UUID: Task<Void, Never>] = [:]
    private(set) var processingCount = 0

    init(
        transcriptionService: TranscriptionServiceProtocol,
        meetingRecordingService: MeetingRecordingServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        conversationRepo: ChatConversationRepositoryProtocol,
        llmService: LLMServiceProtocol?,
        onTranscriptionReady: @escaping (Transcription) -> Void,
        onProcessingCountChanged: @escaping (Int) -> Void
    ) {
        self.transcriptionService = transcriptionService
        self.meetingRecordingService = meetingRecordingService
        self.transcriptionRepo = transcriptionRepo
        self.conversationRepo = conversationRepo
        self.llmService = llmService
        self.onTranscriptionReady = onTranscriptionReady
        self.onProcessingCountChanged = onProcessingCountChanged
    }

    func updateLLMService(_ service: LLMServiceProtocol?) {
        self.llmService = service
    }

    /// Begin background transcription for a finalized recording. Returns
    /// immediately; the work runs in a detached-from-flow Task.
    func process(
        output: MeetingRecordingOutput,
        operationContext: ObservabilityOperationContext,
        trigger: TelemetryMeetingRecordingTrigger?,
        liveWordCount: Int,
        liveTranscriptLagged: Bool,
        shouldAutoGenerateTitle: Bool,
        carriedChat: [ChatMessage]
    ) {
        let sessionID = output.sessionID
        adjustCount(by: 1)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.jobs[sessionID] = nil
                self.adjustCount(by: -1)
            }
            do {
                var transcription = try await Observability.withOperationContext(operationContext) {
                    let base = try await self.transcriptionService.transcribeMeeting(recording: output, onProgress: nil)
                    await self.meetingRecordingService.completeTranscription(for: output)
                    return base
                }

                transcription = await self.enhanceWithWhisperIfAvailable(transcription, output: output)

                if shouldAutoGenerateTitle {
                    transcription = await self.autoGenerateTitle(for: transcription)
                }

                self.persistCarriedChat(carriedChat, for: transcription)

                self.emitOperation(
                    operationContext: operationContext,
                    outcome: .success,
                    trigger: trigger,
                    output: output,
                    stage: .completeTranscription,
                    liveWordCount: liveWordCount,
                    liveTranscriptLagged: liveTranscriptLagged
                )
                self.onTranscriptionReady(transcription)
            } catch {
                Telemetry.send(.meetingRecordingFailed(
                    errorType: TelemetryErrorClassifier.classify(error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
                self.emitOperation(
                    operationContext: operationContext,
                    outcome: .failure,
                    trigger: trigger,
                    output: output,
                    stage: .transcription,
                    liveWordCount: liveWordCount,
                    liveTranscriptLagged: liveTranscriptLagged,
                    errorType: TelemetryErrorClassifier.classify(error)
                )
                // The lock file is intentionally NOT deleted on failure
                // (completeTranscription never ran), so crash recovery offers
                // this recording on next launch.
            }
        }
        jobs[sessionID] = task
    }

    // MARK: - Steps

    private func enhanceWithWhisperIfAvailable(
        _ transcription: Transcription,
        output: MeetingRecordingOutput
    ) async -> Transcription {
        guard WhisperEngine.isModelDownloaded() else { return transcription }
        do {
            return try await transcriptionService.retranscribeMeeting(
                existing: transcription,
                recording: output,
                speechEngineOverride: SpeechEngineSelection(engine: .whisper),
                onProgress: nil
            )
        } catch {
            // Enhancement is best-effort; keep the Parakeet result on failure.
            return transcription
        }
    }

    private func autoGenerateTitle(for transcription: Transcription) async -> Transcription {
        guard let llmService else { return transcription }
        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcription }
        do {
            let title = try await llmService.generateTitle(transcript: text)
            guard !title.isEmpty, title != transcription.fileName else { return transcription }
            try transcriptionRepo.updateFileName(id: transcription.id, fileName: title)
            var updated = transcription
            updated.fileName = title
            updated.derivedTitle = title
            return updated
        } catch {
            return transcription
        }
    }

    private func persistCarriedChat(_ messages: [ChatMessage], for transcription: Transcription) {
        guard !messages.isEmpty else { return }
        let firstUser = messages.first(where: { $0.role == .user })?.content ?? "Meeting chat"
        let conversation = ChatConversation(
            transcriptionId: transcription.id,
            title: String(firstUser.prefix(50))
        )
        do {
            try conversationRepo.save(conversation)
            try conversationRepo.updateMessages(id: conversation.id, messages: messages)
        } catch {
            // Best-effort: losing a carried-over live chat thread is preferable
            // to failing the whole background completion.
        }
    }

    // MARK: - Helpers

    private func adjustCount(by delta: Int) {
        processingCount = max(0, processingCount + delta)
        onProcessingCountChanged(processingCount)
    }

    private func emitOperation(
        operationContext: ObservabilityOperationContext,
        outcome: ObservabilityOutcome,
        trigger: TelemetryMeetingRecordingTrigger?,
        output: MeetingRecordingOutput,
        stage: TelemetryMeetingOperationStage?,
        liveWordCount: Int?,
        liveTranscriptLagged: Bool?,
        errorType: String? = nil
    ) {
        let notes = output.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        Telemetry.send(.meetingOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            outcome: outcome,
            trigger: trigger,
            stage: stage,
            durationSeconds: output.durationSeconds,
            liveWordCount: liveWordCount,
            liveTranscriptLagged: liveTranscriptLagged,
            microphoneTrackPresent: output.sourceAlignment.microphone != nil,
            systemTrackPresent: output.sourceAlignment.system != nil,
            notesUsed: notes.map { !$0.isEmpty },
            notesLengthBucket: Observability.textLengthBucket(output.userNotes),
            errorType: errorType
        ))
    }
}
