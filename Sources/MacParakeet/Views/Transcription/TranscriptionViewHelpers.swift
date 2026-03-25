func truncateErrorMessage(_ msg: String) -> String {
    if msg.contains("dyld") || msg.contains("Library not loaded") {
        return "Library loading failed"
    }
    let firstLine = msg.prefix(while: { $0 != "\n" })
    if firstLine.count > 40 {
        return String(firstLine.prefix(37)) + "..."
    }
    return String(firstLine)
}
