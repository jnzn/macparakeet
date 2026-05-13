import Foundation

public struct TransformShortcutReservedHotkey: Sendable, Equatable {
    public let name: String
    public let trigger: HotkeyTrigger

    public init(name: String, trigger: HotkeyTrigger) {
        self.name = name
        self.trigger = trigger
    }
}
