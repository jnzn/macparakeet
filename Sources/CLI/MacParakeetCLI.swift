import ArgumentParser

@main
struct CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macparakeet-cli",
        abstract: "Local STT, transcription, and prompt automation for Apple Silicon. Powered by Parakeet TDT, with optional Whisper multilingual recognition.",
        version: "1.3.0",
        subcommands: [
            TranscribeCommand.self,
            HistoryCommand.self,
            ExportCommand.self,
            StatsCommand.self,
            HealthCommand.self,
            ModelsCommand.self,
            FlowCommand.self,
            LLMCommand.self,
            PromptsCommand.self,
            MeetingsCommand.self,
            CalendarCommand.self,
            FeedbackCommand.self,
        ],
        defaultSubcommand: nil
    )
}
