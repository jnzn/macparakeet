import Cocoa
import Foundation
import MacParakeetCore

/// Lightweight global shortcut listener for immediate actions like toggling
/// meeting recording. Unlike `HotkeyManager`, this does not model hold or
/// double-tap gestures.
public final class GlobalShortcutManager {
    /// Fired on every press (hotkey down). Together with `onRelease` this
    /// enables hold-to-talk gestures.
    public var onTrigger: (() -> Void)?
    /// Fired on key-up for every press.
    public var onRelease: (() -> Void)?
    /// Fired when the user double-taps the hotkey within
    /// `doubleTapWindowSeconds`. When set, `onTrigger` still fires on each
    /// press — consumers decide how to reconcile the two (typically:
    /// ignore onTrigger while a bubble is open, use onDoubleTap to open
    /// a locked-listening bubble, use onRelease of a long press for
    /// hold-to-talk). Nil means double-taps are treated as regular
    /// press/release pairs.
    public var onDoubleTap: (() -> Void)?

    /// Max interval between two press events to count as a double-tap.
    public var doubleTapWindowSeconds: TimeInterval = 0.35

    private let trigger: HotkeyTrigger
    private let targetMask: CGEventFlags?
    private let requiredChordFlags: UInt64
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<GlobalShortcutManager>?
    private var installedRunLoop: CFRunLoop?
    private var targetModifierWasPressed = false
    private var triggerKeyIsPressed = false
    private var comboWasFullyPressed = false
    private var lastPressAt: Date?

    public init(trigger: HotkeyTrigger) {
        self.trigger = trigger
        self.targetMask = trigger.kind == .modifier ? Self.mask(for: trigger) : nil
        self.requiredChordFlags = trigger.chordEventFlags
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
    }

    public func start() -> Bool {
        if eventTap != nil {
            stop()
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
            retainedSelf?.release()
            retainedSelf = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        recoverFromDisabledTap()
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        targetModifierWasPressed = false
        triggerKeyIsPressed = false
        comboWasFullyPressed = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            recoverFromDisabledTap()
            return Unmanaged.passUnretained(event)
        }

        switch trigger.kind {
        case .disabled:
            return Unmanaged.passUnretained(event)
        case .modifier:
            return handleModifierEvent(type: type, event: event)
        case .keyCode:
            return handleKeyCodeEvent(type: type, event: event)
        case .chord:
            return handleChordEvent(type: type, event: event)
        case .modifierCombo:
            return handleModifierComboEvent(type: type, event: event)
        }
    }

    // MARK: - Modifier combo (2+ modifiers held together, no base key)

    /// Tracks the all-required-modifiers-held state for a `.modifierCombo`
    /// trigger. Fires onTrigger on the flagsChanged event that brings the
    /// last required modifier down, onRelease on the event that lifts the
    /// first required modifier.
    private func handleModifierComboEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }
        let allPressed = allModifierComboKeysPressed(flags: event.flags)
        if allPressed != comboWasFullyPressed {
            comboWasFullyPressed = allPressed
            if allPressed {
                emitPress()
            } else {
                onRelease?()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Dispatch a press event. Detects double-taps: if this press lands
    /// within `doubleTapWindowSeconds` of the previous press AND the
    /// consumer registered an `onDoubleTap` handler, fire onDoubleTap ONLY
    /// (suppress onTrigger for that second press) so flow coordinators
    /// don't double-process the gesture. Otherwise fires onTrigger normally.
    private func emitPress() {
        let now = Date()
        if let prev = lastPressAt,
           now.timeIntervalSince(prev) <= doubleTapWindowSeconds,
           onDoubleTap != nil {
            onDoubleTap?()
            lastPressAt = nil
            return
        }
        lastPressAt = now
        onTrigger?()
    }

    private func allModifierComboKeysPressed(flags: CGEventFlags) -> Bool {
        guard let modifiers = trigger.chordModifiers, !modifiers.isEmpty else {
            return false
        }
        for name in modifiers {
            switch name {
            case "command":
                if !flags.contains(.maskCommand) { return false }
            case "shift":
                if !flags.contains(.maskShift) { return false }
            case "control":
                if !flags.contains(.maskControl) { return false }
            case "option":
                if !flags.contains(.maskAlternate) { return false }
            default:
                return false
            }
        }
        return true
    }

    private func handleModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged, let mask = targetMask else {
            return Unmanaged.passUnretained(event)
        }

        handleModifierFlagsChanged(flags: event.flags, mask: mask)
        return Unmanaged.passUnretained(event)
    }

    private func handleModifierFlagsChanged(flags: CGEventFlags, mask: CGEventFlags) {
        let isPressed = flags.contains(mask)
        if isPressed != targetModifierWasPressed {
            targetModifierWasPressed = isPressed
            if isPressed {
                emitPress()
            } else {
                // Fire onRelease on modifier-key hotkeys too so hold-to-talk
                // works when the user maps the AI Assistant trigger to a
                // single modifier (e.g. "Left Control"). Without this the
                // mic stays open forever because the release event never
                // reaches the coordinator.
                onRelease?()
            }
        }
    }

    private func handleKeyCodeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            guard !triggerKeyIsPressed else { return nil }
            triggerKeyIsPressed = true
            emitPress()
            return nil
        case .keyUp:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            let wasPressed = triggerKeyIsPressed
            triggerKeyIsPressed = false
            if wasPressed { onRelease?() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shouldSwallow = handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: event.flags.rawValue & HotkeyTrigger.relevantModifierBits
        )
        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    private func recoverFromDisabledTap(flags: CGEventFlags? = nil) {
        recoverFromDisabledTap(flags: flags, triggerKeyPressed: currentPhysicalTriggerKeyIsPressed())
    }

    private func recoverFromDisabledTap(flags: CGEventFlags? = nil, triggerKeyPressed: Bool) {
        triggerKeyIsPressed = triggerKeyPressed
        syncModifierPressedState(flags: flags)
    }

    private func currentPhysicalTriggerKeyIsPressed() -> Bool {
        guard trigger.kind == .keyCode || trigger.kind == .chord,
              let keyCode = trigger.keyCode else {
            return false
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func syncModifierPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifier, let mask = targetMask else {
            targetModifierWasPressed = false
            return
        }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        targetModifierWasPressed = currentFlags.contains(mask)
    }

    @discardableResult
    private func handleChordEvent(
        type: CGEventType,
        triggerCode: UInt16,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return false }
            guard flags == requiredChordFlags else { return false }
            guard !triggerKeyIsPressed else { return true }
            triggerKeyIsPressed = true
            emitPress()
            return true
        case .keyUp:
            guard keyCode == triggerCode else { return false }
            guard triggerKeyIsPressed else { return false }
            triggerKeyIsPressed = false
            onRelease?()
            return true
        default:
            return false
        }
    }

    @discardableResult
    func handleChordEventForTesting(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        guard let triggerCode = trigger.keyCode else { return false }
        return handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: flags & HotkeyTrigger.relevantModifierBits
        )
    }

    func modifierFlagsChangedForTesting(flags: CGEventFlags) {
        guard let mask = targetMask else { return }
        handleModifierFlagsChanged(flags: flags, mask: mask)
    }

    func recoverFromDisabledTapForTesting(
        flags: CGEventFlags? = nil,
        triggerKeyPressed: Bool = false
    ) {
        recoverFromDisabledTap(flags: flags, triggerKeyPressed: triggerKeyPressed)
    }

    private static func mask(for trigger: HotkeyTrigger) -> CGEventFlags? {
        guard trigger.kind == .modifier, let name = trigger.modifierName else { return nil }
        switch name {
        case "fn": return .maskSecondaryFn
        case "control": return .maskControl
        case "option": return .maskAlternate
        case "shift": return .maskShift
        case "command": return .maskCommand
        default: return nil
        }
    }
}
