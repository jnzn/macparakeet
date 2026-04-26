import ArgumentParser

@main
struct CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macparakeet-cli",
        abstract: "Local STT, transcription, and prompt automation for Apple Silicon. Powered by Parakeet TDT on the Neural Engine.",
        version: "1.0.0",
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
            CalendarCommand.self,
            FeedbackCommand.self,
        ],
        defaultSubcommand: nil
    )
}
