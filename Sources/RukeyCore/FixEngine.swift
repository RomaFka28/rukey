import CoreGraphics
import Foundation

public protocol SyntheticEventSender: Sendable {
    func sendBackspace(count: Int)
    func insertUnicodeString(_ string: String)
}

public final class DefaultSyntheticEventSender: SyntheticEventSender {
    public static let shared = DefaultSyntheticEventSender()
    public static let magicEventUserData: Int64 = 0x52_554B_4559  // "RUKEY"

    public init() {}

    public func sendBackspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let backspaceKeyCode: CGKeyCode = 51  // macOS standard Backspace/Delete keycode

        for _ in 0..<count {
            if let down = CGEvent(
                keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: true)
            {
                down.setIntegerValueField(.eventSourceUserData, value: Self.magicEventUserData)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(
                keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: false)
            {
                up.setIntegerValueField(.eventSourceUserData, value: Self.magicEventUserData)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    public func insertUnicodeString(_ string: String) {
        guard !string.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16Array = Array(string.utf16)

        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.setIntegerValueField(.eventSourceUserData, value: Self.magicEventUserData)
            down.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.setIntegerValueField(.eventSourceUserData, value: Self.magicEventUserData)
            up.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
            up.post(tap: .cghidEventTap)
        }
    }
}

public final class FixEngine: @unchecked Sendable {
    private let eventSender: SyntheticEventSender
    private let inputSourceManager: InputSourceManager
    private var isSuppressingInput: Bool = false
    private let lock = NSLock()

    public var isFixing: Bool {
        return lock.withLock { isSuppressingInput }
    }

    public init(
        eventSender: SyntheticEventSender = DefaultSyntheticEventSender.shared,
        inputSourceManager: InputSourceManager = InputSourceManager.shared
    ) {
        self.eventSender = eventSender
        self.inputSourceManager = inputSourceManager
    }

    private func withSuppression(_ work: () -> Void) {
        lock.withLock { isSuppressingInput = true }
        defer { lock.withLock { isSuppressingInput = false } }
        work()
    }

    private func perform(backspaces: Int, text: String, language: Language) {
        withSuppression {
            if backspaces > 0 {
                eventSender.sendBackspace(count: backspaces)
            }
            inputSourceManager.apply(language: language)
            eventSender.insertUnicodeString(text)
        }
    }

    /// Performs atomic on-the-fly correction:
    /// 1. Suppress incoming events
    /// 2. Send exact count of backspaces for replaced length
    /// 3. Switch input source to target language
    /// 4. Insert converted text via unicode string API
    /// 5. Lift suppression
    public func executeCorrection(
        backspacesToErase: Int,
        convertedText: String,
        targetLanguage: Language
    ) {
        perform(backspaces: backspacesToErase, text: convertedText, language: targetLanguage)
    }

    /// Performs undo restoration: erases the current typed tail, inserts original text,
    /// and switches back to the original layout.
    public func executeUndo(
        currentReplacedCount: Int,
        originalText: String,
        originalLanguage: Language
    ) {
        perform(backspaces: currentReplacedCount, text: originalText, language: originalLanguage)
    }
}
