import Foundation

/// The data twin of the two lines `UndoLearningController` writes: `.undo`
/// mirrors the `Отменено:` line, `.learned` mirrors the `.warn` `Запомнено:`
/// line. Emitted at the same point under the same condition as its line, so a
/// consumer reads exactly what the console prints.
public enum LearningNotice: Equatable, Sendable {
    case undo(prefix: String, converted: String, count: Int, threshold: Int)
    case learned(prefix: String, converted: String)
}

/// Turns repeated undos of the same correction into an exclusion rule.
///
/// The controller owns no state beyond its dependencies: the counts live in
/// `StrikeStore`, the exclusion set in `WordFilter`, the threshold and the
/// notification flag are read through closures on every call so the settings
/// apply without a restart, and the config write is delegated to the caller.
/// The threshold is compared for exact equality rather than `>=`, so a fourth
/// undo cannot rewrite the config a second time.
public final class UndoLearningController: @unchecked Sendable {
    // `@unchecked Sendable` is conservative rather than load-bearing: every
    // stored property is immutable and itself `Sendable` except `onNotice` — a
    // set-once-before-the-tap-starts, then read-on-the-tap-thread hook, the same
    // pattern (and the same lack of a `@Sendable` annotation on the property) as
    // `EventTapManager`'s four callbacks.
    private let strikeStore: StrikeStore
    private let wordFilter: WordFilter
    private let thresholdProvider: @Sendable () -> Int
    private let notifyProvider: @Sendable () -> Bool
    private let configWriter: @Sendable (Set<String>) -> Void
    private let logBuffer: LogBuffer

    /// The two lines this controller writes, as data: `.undo` mirrors the
    /// `Отменено:` line, `.learned` mirrors the `.warn` `Запомнено:` line, both
    /// emitted at the same point under the same condition. The hub at the end of
    /// this plan (Task 9) subscribes to this instead of parsing the log.
    public var onNotice: ((LearningNotice) -> Void)?

    public init(
        strikeStore: StrikeStore,
        wordFilter: WordFilter,
        thresholdProvider: @escaping @Sendable () -> Int,
        notifyProvider: @escaping @Sendable () -> Bool,
        configWriter: @escaping @Sendable (Set<String>) -> Void,
        logBuffer: LogBuffer = .shared
    ) {
        self.strikeStore = strikeStore
        self.wordFilter = wordFilter
        self.thresholdProvider = thresholdProvider
        self.notifyProvider = notifyProvider
        self.configWriter = configWriter
        self.logBuffer = logBuffer
    }

    /// Handles one undo of `pair`, or nothing when there was nothing to undo.
    public func handleUndo(_ pair: (original: String, converted: String)?) {
        guard let pair else { return }
        let count = strikeStore.registerUndo(key: pair.original)
        let threshold = thresholdProvider()
        if threshold > 0 && count == threshold {
            wordFilter.replaceAll(with: wordFilter.words.union([pair.original]))
            configWriter(wordFilter.words)
            logBuffer.log(
                "Запомнено: \(pair.original) больше не станет \(pair.converted)",
                level: .warn
            )
            onNotice?(.learned(prefix: pair.original, converted: pair.converted))
        } else if notifyProvider() {
            logBuffer.log(
                "Отменено: \(pair.original) → \(pair.converted) (\(count)/\(threshold))"
            )
            onNotice?(
                .undo(
                    prefix: pair.original, converted: pair.converted, count: count,
                    threshold: threshold))
        }
    }
}
