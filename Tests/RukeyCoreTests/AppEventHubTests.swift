import XCTest
@testable import RukeyCore

final class AppEventHubTests: XCTestCase {
    private func makeTempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    private func makeRig(
        threshold: Int = 3,
        notify: Bool = true
    ) throws -> (engine: RukeyEngine, controller: UndoLearningController, hub: AppEventHub) {
        let engine = try RukeyEngine(
            config: RukeyConfig(),
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        let controller = UndoLearningController(
            strikeStore: engine.strikeStore,
            wordFilter: engine.wordFilter,
            thresholdProvider: { threshold },
            notifyProvider: { notify },
            configWriter: { _ in }
        )
        let hub = AppEventHub(tapManager: engine.tapManager, learningController: controller)
        return (engine, controller, hub)
    }

    private func decision() -> CorrectionDecision {
        CorrectionDecision(
            originalText: "ghb", convertedText: "при",
            sourceLanguage: .english, targetLanguage: .russian,
            triggerRule: "en_invalid_prefix_ru_valid")
    }

    /// Puts a correction into the undo manager and performs the undo — exactly
    /// the pair of calls the tap makes before it fires `onOptionUndo`.
    private func undoCandidate(_ engine: RukeyEngine) {
        engine.undoManager.recordCorrection(decision())
        _ = engine.undoManager.calculateUndo()
    }

    func testCorrectionCallbackReachesTheHub() throws {
        let (engine, _, hub) = try makeRig()
        engine.tapManager.onCorrection?(decision())
        XCTAssertEqual(hub.lastCorrection, decision())
    }

    func testOptionToggleReachesTheHub() throws {
        let (engine, _, hub) = try makeRig()
        engine.tapManager.onOptionToggle?(.english, .russian)
        XCTAssertEqual(hub.lastLayoutToggle, LayoutToggleNotice(from: .english, to: .russian))
    }

    func testIgnoredReasonReachesTheHub() throws {
        let (engine, _, hub) = try makeRig()
        engine.tapManager.onOptionIgnored?("no_pending_press")
        XCTAssertEqual(hub.lastIgnoredReason, "no_pending_press")
    }

    func testUndoCallbackFeedsLearningAndPublishesTheNotice() throws {
        let (engine, _, hub) = try makeRig(threshold: 3)
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        // The hub's wiring is what drove the strike: nothing else called handleUndo.
        XCTAssertEqual(engine.strikeStore.strikes(for: "ghb"), 1)
        XCTAssertEqual(hub.lastUndo, UndoNotice(
            prefix: "ghb", converted: "при", count: 1, threshold: 3))
        XCTAssertNil(hub.lastLearned)
    }

    func testLearningReachesTheHubAndTheFilter() throws {
        let (engine, _, hub) = try makeRig(threshold: 1)
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        XCTAssertEqual(hub.lastLearned, LearnedNotice(prefix: "ghb", converted: "при"))
        XCTAssertTrue(engine.wordFilter.isExcluded("ghb"))
    }

    func testUndoNoticeIsSuppressedWhenNotificationsAreOff() throws {
        let (engine, _, hub) = try makeRig(threshold: 3, notify: false)
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        XCTAssertNil(hub.lastUndo)
        // Suppression is about the notice, not about counting: the strike still lands.
        XCTAssertEqual(engine.strikeStore.strikes(for: "ghb"), 1)
    }

    /// The `.undo` notice's integers must come from the payload, not match the
    /// fixtures by coincidence: a first and second undo under a non-default
    /// threshold observe (1, 5) and (2, 5).
    func testUndoNoticeCarriesTheConfiguredThreshold() throws {
        let (engine, _, hub) = try makeRig(threshold: 5)
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        XCTAssertEqual(hub.lastUndo, UndoNotice(
            prefix: "ghb", converted: "при", count: 1, threshold: 5))
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        XCTAssertEqual(hub.lastUndo, UndoNotice(
            prefix: "ghb", converted: "при", count: 2, threshold: 5))
    }
}
