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
        XCTAssertFalse(RukeyUndoManager().canUndo)
        XCTAssertNil(RukeyUndoManager().calculateUndo())
    }

    func testRecordedCorrectionIsUndoable() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        XCTAssertTrue(manager.canUndo)
        let calculation = manager.calculateUndo()
        XCTAssertEqual(calculation?.textToRestore, "ghb")
        XCTAssertEqual(calculation?.backspacesNeeded, 3)
        XCTAssertEqual(calculation?.originalLanguage, .english)
    }

    func testUndoIsConsumedOnce() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        XCTAssertNotNil(manager.calculateUndo())
        XCTAssertFalse(manager.canUndo)
        XCTAssertNil(manager.calculateUndo())
    }

    func testAppendedTailIsErasedToo() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision(), appendedTail: " ")
        let calculation = manager.calculateUndo()
        // "при" plus a space, all erased before "ghb" goes back.
        XCTAssertEqual(calculation?.backspacesNeeded, 4)
    }

    func testClearRemovesTheUndo() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.clear()
        XCTAssertFalse(manager.canUndo)
    }
}