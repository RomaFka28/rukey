import Foundation

struct LastCorrectionState: Sendable {
    public let originalText: String
    public let convertedText: String
    public let originalLanguage: Language
    public let targetLanguage: Language
    public let appendedTail: String

    public init(
        originalText: String,
        convertedText: String,
        originalLanguage: Language,
        targetLanguage: Language,
        appendedTail: String = ""
    ) {
        self.originalText = originalText
        self.convertedText = convertedText
        self.originalLanguage = originalLanguage
        self.targetLanguage = targetLanguage
        self.appendedTail = appendedTail
    }
}

public final class RukeyUndoManager: @unchecked Sendable {
    static let maxTailLength = 64

    private var lastState: LastCorrectionState?
    private var lastUndoneState: (original: String, converted: String)?
    private let lock = NSLock()

    public init() {}

    /// Records a newly applied correction.
    public func recordCorrection(_ decision: CorrectionDecision, appendedTail: String = "") {
        lock.withLock {
            lastState = LastCorrectionState(
                originalText: decision.originalText,
                convertedText: decision.convertedText,
                originalLanguage: decision.sourceLanguage,
                targetLanguage: decision.targetLanguage,
                appendedTail: appendedTail
            )
        }
    }

    /// Grows the tail of characters typed after the latest correction.
    /// Beyond `maxTailLength` UTF-16 units the undo is dropped rather than
    /// letting an unbounded erase reach into text the user has moved past.
    public func appendToTail(_ text: String) {
        lock.withLock {
            guard let state = lastState else { return }
            let appendedTail = state.appendedTail + text
            if state.convertedText.utf16EraseLength + appendedTail.utf16EraseLength > Self.maxTailLength {
                lastState = nil
                return
            }
            lastState = LastCorrectionState(
                originalText: state.originalText,
                convertedText: state.convertedText,
                originalLanguage: state.originalLanguage,
                targetLanguage: state.targetLanguage,
                appendedTail: appendedTail
            )
        }
    }

    /// Checks if an undo action is available.
    public var canUndo: Bool {
        return lock.withLock {
            lastState != nil
        }
    }

    /// The most recently undone pair, needed by the learning logic in Task 7.
    /// `onOptionUndo` carries only the language and the restored text, so the
    /// converted side has to come from here.
    public var lastUndone: (original: String, converted: String)? {
        lock.withLock { lastUndoneState }
    }

    public struct UndoCalculation: Equatable, Sendable {
        public let backspacesNeeded: Int
        public let textToRestore: String
        public let originalLanguage: Language

        init(backspacesNeeded: Int, textToRestore: String, originalLanguage: Language) {
            self.backspacesNeeded = backspacesNeeded
            self.textToRestore = textToRestore
            self.originalLanguage = originalLanguage
        }
    }

    /// Atomically computes undo and consumes the state.
    /// Single-lock design fixes the previous TOCTOU: `canUndo` + `calculateUndo`
    /// checked the timestamp in two separate locks, so expiry could slip between them.
    public func calculateUndo() -> UndoCalculation? {
        return lock.withLock {
            guard let state = lastState else { return nil }
            lastUndoneState = (original: state.originalText, converted: state.convertedText)
            lastState = nil
            // NOTE: erase length is UTF-16 units (`utf16EraseLength`), matching
            // FixEngine.sendBackspace / insertUnicodeString. `.count` (graphemes)
            // undercounts emoji/ZWJ sequences — never use it for erase logic.
            let backspacesNeeded = state.convertedText.utf16EraseLength + state.appendedTail.utf16EraseLength
            return UndoCalculation(
                backspacesNeeded: backspacesNeeded,
                textToRestore: state.originalText,
                originalLanguage: state.originalLanguage
            )
        }
    }

    /// Clears the undo state (e.g. on word boundary or explicit reset).
    public func clear() {
        lock.withLock { lastState = nil }
    }
}
