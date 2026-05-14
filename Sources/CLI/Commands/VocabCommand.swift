import ArgumentParser

struct VocabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vocab",
        abstract: "Manage vocabulary: custom words, text snippets, and the text-processing pipeline.",
        subcommands: [
            VocabProcessCommand.self,
            VocabWordsCommand.self,
            VocabSnippetsCommand.self,
            VocabExportCommand.self,
            VocabImportCommand.self,
            VocabSchemaCommand.self,
        ]
    )
}
