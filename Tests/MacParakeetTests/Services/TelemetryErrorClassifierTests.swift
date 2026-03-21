import Foundation
import Testing
@testable import MacParakeetCore

@Suite("TelemetryErrorClassifier")
struct TelemetryErrorClassifierTests {

    @Test("classifies AudioProcessorError cases with case name")
    func audioProcessorErrorCases() {
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.insufficientSamples)
            == "AudioProcessorError.insufficientSamples")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.microphoneNotAvailable)
            == "AudioProcessorError.microphoneNotAvailable")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.microphonePermissionDenied)
            == "AudioProcessorError.microphonePermissionDenied")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.recordingFailed("test"))
            == "AudioProcessorError.recordingFailed")
        #expect(TelemetryErrorClassifier.classify(AudioProcessorError.conversionFailed("test"))
            == "AudioProcessorError.conversionFailed")
    }

    @Test("classifies STTError cases with case name")
    func sttErrorCases() {
        #expect(TelemetryErrorClassifier.classify(STTError.engineStartFailed("test"))
            == "STTError.engineStartFailed")
    }

    @Test("classifies DictationServiceError cases with case name")
    func dictationServiceErrorCases() {
        #expect(TelemetryErrorClassifier.classify(DictationServiceError.emptyTranscript)
            == "DictationServiceError.emptyTranscript")
        #expect(TelemetryErrorClassifier.classify(DictationServiceError.notRecording)
            == "DictationServiceError.notRecording")
    }

    @Test("classifies URLError with code name")
    func urlErrorCodes() {
        #expect(TelemetryErrorClassifier.classify(URLError(.notConnectedToInternet))
            == "URLError.notConnectedToInternet")
        #expect(TelemetryErrorClassifier.classify(URLError(.timedOut))
            == "URLError.timedOut")
    }

    @Test("classifies CancellationError")
    func cancellationError() {
        #expect(TelemetryErrorClassifier.classify(CancellationError())
            == "CancellationError")
    }

    @Test("classifies NSError with domain and code")
    func nsError() {
        let error = NSError(domain: "TestDomain", code: 42)
        #expect(TelemetryErrorClassifier.classify(error)
            == "TestDomain.42")
    }
}
