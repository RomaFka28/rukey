import Combine

/// The single fan-out point translating engine callbacks into data the GUI can
/// publish: it subscribes to the four `EventTapManager` callbacks and to
/// `UndoLearningController.onNotice`, and fans the results out to SwiftUI. It
/// lives in `RukeyCore` because the daemon and the UI are one process.
///
/// Every property holds the latest value of its kind, so a consumer that
/// attaches late still sees the last correction. Construction is the only
/// wiring: in one process either the hub or hand-written callbacks own the tap,
/// never both. The console (`main.swift`) deliberately does not construct one:
/// it prints through `printLangState` and needs no SwiftUI.
///
/// No `@MainActor` and no `@unchecked Sendable`: the tap lives on the main run
/// loop — the bootstrap inherits today's `CFRunLoopRun`, and the GUI's
/// `NSApplication.run()` delivers to the same tap — so the callbacks arrive on
/// the main thread, and the four callback properties take plain closures, the
/// same shape as `EventTapManager`'s.
public final class AppEventHub: ObservableObject {
    /// The tap manager and the learning controller are held strongly; the
    /// wiring closures below capture the hub weakly.
    private let tapManager: EventTapManager
    private let learningController: UndoLearningController

    @Published public private(set) var lastCorrection: CorrectionDecision?
    @Published public private(set) var lastUndo: UndoNotice?
    @Published public private(set) var lastLearned: LearnedNotice?
    @Published private(set) var lastLayoutToggle: LayoutToggleNotice?
    @Published private(set) var lastIgnoredReason: String?

    /// Subscribes the hub to the tap manager's four callbacks and to the
    /// controller's notice hook. The undo notice itself arrives through the
    /// notice hook, count and threshold included, so the raw `(from, restored)`
    /// payload is not published separately; this is the same `handleUndo` call
    /// the console's `main.swift` makes, both feeding the same controller.
    public init(tapManager: EventTapManager, learningController: UndoLearningController) {
        self.tapManager = tapManager
        self.learningController = learningController

        tapManager.onCorrection = { [weak self] decision in
            self?.lastCorrection = decision
        }
        tapManager.onOptionToggle = { [weak self] from, to in
            self?.lastLayoutToggle = LayoutToggleNotice(from: from, to: to)
        }
        tapManager.onOptionIgnored = { [weak self] reason in
            self?.lastIgnoredReason = reason
        }
        tapManager.onOptionUndo = { [weak self] _, _ in
            guard let self else { return }
            self.learningController.handleUndo(self.tapManager.undoManager.lastUndone)
        }
        learningController.onNotice = { [weak self] notice in
            self?.handle(notice)
        }
    }

    /// The only writer of `lastUndo`/`lastLearned`; nothing but the wiring
    /// closures writes `lastCorrection`, `lastLayoutToggle` and
    /// `lastIgnoredReason`.
    private func handle(_ notice: LearningNotice) {
        switch notice {
        case let .undo(prefix, converted, count, threshold):
            lastUndo = UndoNotice(
                prefix: prefix, converted: converted, count: count, threshold: threshold)
        case let .learned(prefix, converted):
            lastLearned = LearnedNotice(prefix: prefix, converted: converted)
        }
    }
}

/// A snapshot of a `LearningNotice.undo`: the correction was undone and its
/// strike counted, mirroring the `Отменено:` console line.
public struct UndoNotice: Equatable, Sendable {
    public let prefix: String
    public let converted: String
    public let count: Int
    public let threshold: Int
}

/// A snapshot of a `LearningNotice.learned`: the prefix crossed the threshold
/// and is now excluded, mirroring the `Запомнено:` console line.
public struct LearnedNotice: Equatable, Sendable {
    public let prefix: String
    public let converted: String
}

/// The languages the option toggle switched between.
struct LayoutToggleNotice: Equatable, Sendable {
    public let from: Language
    public let to: Language
}
