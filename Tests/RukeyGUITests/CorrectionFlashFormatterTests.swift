import XCTest
@testable import RukeyGUI

final class CorrectionFlashFormatterTests: XCTestCase {
    func testCorrectionTextUsesAnArrow() {
        XCTAssertEqual(CorrectionFlash.text(original: "ghb", converted: "при"), "ghb → при")
    }

    func testTextIsTruncatedForThePanelWidth() {
        let long = String(repeating: "я", count: 100)
        let text = CorrectionFlash.text(original: long, converted: long)
        XCTAssertTrue(text.count <= 60)
        XCTAssertTrue(text.hasSuffix("…"))
    }
}
