import Foundation

public struct LastCorrectionState: Sendable {
    public let originalText: String
    public let convertedText: String
    public let originalLanguage: Language
    public let targetLanguage: Language
    public let appendedTail: String
    public let timestamp: Date
    public let timestampUptime: TimeInterval

    public init(
        originalText: String,
        convertedText: String,
        originalLanguage: Language,
        targetLanguage: Language,
        appendedTail: String = "",
        timestamp: Date = Date(),
        timestampUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.originalText = originalText
        self.convertedText = convertedText
        self.originalLanguage = originalLanguage
        self.targetLanguage = targetLanguage
        self.appendedTail = appendedTail
        self.timestamp = timestamp
        self.timestampUptime = timestampUptime
    }
}

public final class RukeyUndoManager: @unchecked Sendable {
    private var lastState: LastCorrectionState?
    private let lock = NSLock()
    public let maxUndoWindowSeconds: TimeInterval
    /// Injected monotonic clock for testability (defaults to system uptime).
    private let now: @Sendable () -> TimeInterval

    public init(maxUndoWindowSeconds: TimeInterval = 1.2, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maxUndoWindowSeconds = maxUndoWindowSeconds
        self.now = now
    }

    /// Records a newly applied correction.
    public func recordCorrection(_ decision: CorrectionDecision, appendedTail: String = "") {
        lock.withLock {
            lastState = LastCorrectionState(
                originalText: decision.originalText,
                convertedText: decision.convertedText,
                originalLanguage: decision.sourceLanguage,
                targetLanguage: decision.targetLanguage,
                appendedTail: appendedTail,
                timestamp: Date(),
                timestampUptime: now()
            )
        }
    }

    private func isFresh(_ state: LastCorrectionState, at uptime: TimeInterval) -> Bool {
        uptime - state.timestampUptime <= maxUndoWindowSeconds
    }

    /// Checks if an undo action is available.
    public var canUndo: Bool {
        return lock.withLock {
            guard let state = lastState else { return false }
            return isFresh(state, at: now())
        }
    }

    public struct UndoCalculation: Equatable, Sendable {
        public let backspacesNeeded: Int
        public let textToRestore: String
        public let originalLanguage: Language

        public init(backspacesNeeded: Int, textToRestore: String, originalLanguage: Language) {
            self.backspacesNeeded = backspacesNeeded
            self.textToRestore = textToRestore
            self.originalLanguage = originalLanguage
        }
    }

    /// Atomically checks freshness, computes undo, and consumes the state.
    /// Single-lock design fixes the previous TOCTOU: `canUndo` + `calculateUndo`
    /// checked the timestamp in two separate locks, so expiry could slip between them.
    public func calculateUndo() -> UndoCalculation? {
        return lock.withLock {
            guard let state = lastState else { return nil }
            guard isFresh(state, at: now()) else {
                lastState = nil
                return nil
            }
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
