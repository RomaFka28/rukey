import XCTest
@testable import RukeyCore

final class WordFilterTests: XCTestCase {
    func testEmptyFilterExcludesNothing() {
        let filter = WordFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertFalse(filter.isExcluded("ghbdtn"))
        XCTAssertFalse(filter.isPrefixOfExcluded("ghb"))
    }

    func testExactMembership() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isExcluded("ghbdtn"))
        XCTAssertFalse(filter.isExcluded("ghbdt"))
    }

    func testExactMembershipIgnoresCase() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isExcluded("Ghbdtn"))
        XCTAssertTrue(filter.isExcluded("GHBDTN"))
    }

    func testPrefixMembershipCoversEveryShorterRun() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isPrefixOfExcluded("g"))
        XCTAssertTrue(filter.isPrefixOfExcluded("ghb"))
        XCTAssertTrue(filter.isPrefixOfExcluded("ghbdt"))
        XCTAssertTrue(filter.isPrefixOfExcluded("ghbdtn"))
        XCTAssertFalse(filter.isPrefixOfExcluded("ghbdtx"))
    }

    func testPrefixMembershipIgnoresCase() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isPrefixOfExcluded("GHB"))
    }

    func testBlankWordsAreIgnored() {
        let filter = WordFilter(words: ["", "   "])
        XCTAssertTrue(filter.isEmpty)
    }

    func testReplaceAllSwapsTheWholeSet() {
        let filter = WordFilter(words: ["ghbdtn"])
        filter.replaceAll(with: ["hello"])
        XCTAssertEqual(filter.words, ["hello"])
        XCTAssertFalse(filter.isExcluded("ghbdtn"))
        XCTAssertTrue(filter.isExcluded("hello"))
    }

    func testBlankWordIsNotAPrefixOfAnything() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertFalse(filter.isPrefixOfExcluded(""))
    }
}
