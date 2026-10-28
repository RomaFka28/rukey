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

    func testTapDisableEventsRequestReenableAndReset() {
        XCTAssertTrue(TapPolicy.isTapReenableEvent(.tapDisabledByTimeout))
        XCTAssertTrue(TapPolicy.isTapReenableEvent(.tapDisabledByUserInput))
        XCTAssertFalse(TapPolicy.isTapReenableEvent(.keyDown))
    }

    func testNavigationKeysAreWordBoundaries() {
        for keyCode in [115, 116, 119, 121, 123, 124, 125, 126] {
            XCTAssertTrue(KeyCode.wordBoundaries.contains(Int64(keyCode)))
        }
    }

    func testLayoutToggleIsRefusedUnderSecureInput() {
        XCTAssertFalse(TapPolicy.shouldToggleLayoutOnOptionTap(isSecureInputActive: true))
    }

    func testLayoutToggleIsAllowedNormally() {
        XCTAssertTrue(TapPolicy.shouldToggleLayoutOnOptionTap(isSecureInputActive: false))
    }
}
