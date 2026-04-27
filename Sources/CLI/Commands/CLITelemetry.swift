import Foundation
import MacParakeetCore

enum CLITelemetry {
    static func configureIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MACPARAKEET_TELEMETRY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           ["0", "false", "no", "off"].contains(override) {
            Telemetry.configure(NoOpTelemetryService())
            return
        }

        Telemetry.configure(TelemetryService(
            requestTimeoutInterval: 1.0,
            isEnabled: {
                AppPreferences.isTelemetryEnabled(defaults: macParakeetAppDefaults())
            }
        ))
    }

    static func sendOperationAndFlush(
        operationID: String,
        operationContext: ObservabilityOperationContext? = nil,
        command: String,
        subcommand: String? = nil,
        outcome: ObservabilityOutcome,
        startedAt: Date,
        inputKind: ObservabilityInputKind? = nil,
        outputFormat: String? = nil,
        json: Bool? = nil,
        exitCode: Int? = nil,
        errorType: String? = nil
    ) async {
        Telemetry.send(.cliOperation(
            operationID: operationID,
            operationContext: operationContext,
            command: command,
            subcommand: subcommand,
            outcome: outcome,
            durationSeconds: Observability.durationSeconds(since: startedAt),
            inputKind: inputKind,
            outputFormat: outputFormat,
            json: json,
            exitCode: exitCode,
            errorType: errorType
        ))
        await Telemetry.flush()
    }
}
