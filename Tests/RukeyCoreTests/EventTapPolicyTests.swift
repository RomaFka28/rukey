import CoreGraphics
import XCTest
@testable import RukeyCore

final class EventTapPolicyTests: XCTestCase {
    func testEventMaskIncludesMouseDown() {
        XCTAssertNotEqual(
            TapPolicy.eventMask & CGEventMask(1 << CGEventType.leftMouseDown.rawValue), 0)
    }

    func testEventMaskStillIncludesKeyDownAndFlagsChanged() {
        XCTAssertNotEqual(
            TapPolicy.eventMask & CGEventMask(1 << CGEventType.keyDown.rawValue), 0)
        XCTAssertNotEqual(
            TapPolicy.eventMask & CGEventMask(1 << CGEventType.flagsChanged.rawValue), 0)
    }

    func testLeftMouseDownResetsUndo() {
        XCTAssertTrue(TapPolicy.isUndoResettingEvent(.leftMouseDown))
        XCTAssertTrue(TapPolicy.isUndoResettingEvent(.rightMouseDown))
    }

    func testTypingDoesNotResetUndo() {
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.keyDown))
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.flagsChanged))
    }

    func testOtherMouseButtonsDoNotResetUndo() {
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.mouseMoved))
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.scrollWheel))
    }

    func testLayoutToggleIsRefusedUnderSecureInput() {
        XCTAssertFalse(TapPolicy.shouldToggleLayoutOnOptionTap(isSecureInputActive: true))
    }

    func testLayoutToggleIsAllowedNormally() {
        XCTAssertTrue(TapPolicy.shouldToggleLayoutOnOptionTap(isSecureInputActive: false))
    }
}
