import Foundation
import XCTest
@testable import RukeyCore

final class UndoManagerTests: XCTestCase {
    private func decision(
        original: String = "ghb",
        converted: String = "при"
    ) -> CorrectionDecision {
        CorrectionDecision(
            originalText: original,
            convertedText: converted,
            sourceLanguage: .english,
            targetLanguage: .russian,
            triggerRule: "en_invalid_prefix_ru_valid"
        )
    }

    func testNothingToUndoBeforeAnyCorrection() {
        let manager = RukeyUndoManager()
        XCTAssertFalse(manager.canUndo)
        XCTAssertNil(manager.calculateUndo())
    }

    func testUndoSurvivesAnArbitrarilyLongPause() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        // The old implementation expired the undo after 1.2 s. Sleeping past that
        // window is the only way this assertion can fail: without the sleep the
        // test passes on the time-gated implementation too and pins nothing.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(manager.canUndo)
    }

    func testTailIsErasedAlongsideTheCorrection() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail("вет")
        let calculation = manager.calculateUndo()
        XCTAssertEqual(calculation?.backspacesNeeded, 6)
        XCTAssertEqual(calculation?.textToRestore, "ghb")
    }

    func testTailAccumulatesAcrossSeveralAppends() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail("в")
        manager.appendToTail("е")
        manager.appendToTail("т")
        XCTAssertEqual(manager.calculateUndo()?.backspacesNeeded, 6)
    }

    func testTailClearedByExplicitClear() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail("вет")
        manager.clear()
        XCTAssertFalse(manager.canUndo)
    }

    func testTailIsTruncatedAtTheValve() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail(String(repeating: "я", count: 200))
        // The valve drops the undo rather than letting an unbounded erase
        // reach into text the user has long since moved past.
        XCTAssertFalse(manager.canUndo)
        // Just below the valve the undo survives, so this is a valve and not an
        // off-by-one that swallows every tail: 3 ("при") + 61 = 64, the limit
        // itself, and only *exceeding* it resets.
        let kept = RukeyUndoManager()
        kept.recordCorrection(decision())
        kept.appendToTail(String(repeating: "я", count: 61))
        XCTAssertTrue(kept.canUndo)
        XCTAssertEqual(kept.calculateUndo()?.backspacesNeeded, 64)
    }

    func testTailOnAnEmptyUndoIsIgnored() {
        let manager = RukeyUndoManager()
        manager.appendToTail("abc")
        XCTAssertFalse(manager.canUndo)
    }

    func testNewerCorrectionReplacesTheOlderUndo() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision(original: "ghb", converted: "при"))
        manager.recordCorrection(decision(original: "тест", converted: "ручка"))
        XCTAssertEqual(manager.calculateUndo()?.textToRestore, "тест")
    }

    func testUndoIsConsumedOnce() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        XCTAssertNotNil(manager.calculateUndo())
        XCTAssertNil(manager.calculateUndo())
    }

    func testLastUndoneIsEmptyUntilAnUndoHappens() {
        let manager = RukeyUndoManager()
        XCTAssertNil(manager.lastUndone)
        manager.recordCorrection(decision())
        // Recording is not undoing: the learning logic must never see a pair
        // the user did not take back.
        XCTAssertNil(manager.lastUndone)
        _ = manager.calculateUndo()
        XCTAssertEqual(manager.lastUndone?.original, "ghb")
        XCTAssertEqual(manager.lastUndone?.converted, "при")
    }

    func testBackspacesUseUTF16Length() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision(original: "ghb", converted: "🙂"))
        manager.appendToTail("😀")
        // Each emoji is two UTF-16 units.
        XCTAssertEqual(manager.calculateUndo()?.backspacesNeeded, 4)
    }
}
