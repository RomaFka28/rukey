import XCTest
@testable import RukeyCore

final class LayoutConverterTests: XCTestCase {
    func testMappingsAreInternallyConsistent() {
        XCTAssertTrue(LayoutConverter.validateMappings())
    }

    func testRoundTripProbes() {
        XCTAssertEqual(LayoutConverter.toRussian("ghbdtn"), "привет")
        XCTAssertEqual(LayoutConverter.toEnglish("привет"), "ghbdtn")
        XCTAssertEqual(LayoutConverter.toEnglish("руддщ"), "hello")
        XCTAssertEqual(LayoutConverter.toRussian("hello"), "руддщ")
    }

    func testConversionPreservesCapitalisation() {
        XCTAssertEqual(LayoutConverter.toRussian("Hello"), "Руддщ")
        XCTAssertEqual(LayoutConverter.toEnglish("Привет"), "Ghbdtn")
    }

    func testDetectAlphabetSeparatesScripts() {
        XCTAssertEqual(LayoutConverter.detectAlphabet("ghbdtn"), .english)
        XCTAssertEqual(LayoutConverter.detectAlphabet("привет"), .russian)
        XCTAssertNil(LayoutConverter.detectAlphabet("приветghbdtn"))
        XCTAssertNil(LayoutConverter.detectAlphabet("123"))
    }

    func testTrailingScriptRunDropsLeadingPunctuation() {
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: ",fu"), "fu")
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: "abc!def"), "def")
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: "123"), "")
    }

    func testTrailingScriptRunStopsAtAlphabetChange() {
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: "приветghb"), "ghb")
    }

    func testSplitEdgePunctuationSeparatesCore() {
        let parts = LayoutConverter.splitEdgePunctuation(",fu!")
        XCTAssertEqual(parts.leading, ",")
        XCTAssertEqual(parts.core, "fu")
        XCTAssertEqual(parts.trailing, "!")
    }
}
