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
        // The undo must switch back the layout the text actually came from.
        XCTAssertEqual(calculation?.originalLanguage, .english)
        // A tail can also arrive at record time — the space-triggered correction
        // passes the space through — and it counts toward the erase too.
        let recorded = RukeyUndoManager()
        recorded.recordCorrection(decision(), appendedTail: " ")
        XCTAssertEqual(recorded.calculateUndo()?.backspacesNeeded, 4)
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
        // The valve weighs the converted text too: 62 + 3 = 65 exceeds it even
        // though the tail alone does not, so a tail-only bound would keep this.
        let over = RukeyUndoManager()
        over.recordCorrection(decision())
        over.appendToTail(String(repeating: "я", count: 62))
        XCTAssertFalse(over.canUndo)
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
        // Replacement starts a fresh tail: a tail from the old correction must
        // not widen the new correction's erase.
        let fresh = RukeyUndoManager()
        fresh.recordCorrection(decision())
        fresh.appendToTail("вет")
        fresh.recordCorrection(decision(original: "ntcn", converted: "тест"))
        XCTAssertEqual(fresh.calculateUndo()?.backspacesNeeded, 4)
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
        // "The most recently undone pair": neither a later correction nor a
        // clear retracts it — Task 7's learning reads it through this API.
        manager.recordCorrection(decision(original: "руддщ", converted: "hello"))
        XCTAssertEqual(manager.lastUndone?.original, "ghb")
        manager.clear()
        XCTAssertEqual(manager.lastUndone?.original, "ghb")
    }

    func testBackspacesUseUTF16Length() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision(original: "ghb", converted: "🙂"))
        manager.appendToTail("😀")
        // Each emoji is two UTF-16 units.
        XCTAssertEqual(manager.calculateUndo()?.backspacesNeeded, 4)
    }
}
