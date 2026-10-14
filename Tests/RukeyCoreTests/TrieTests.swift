import XCTest
@testable import RukeyCore

final class TrieTests: XCTestCase {
    func testInsertCountsWords() {
        let trie = TestDictionaries.makeTrie(["alpha", "beta", "alpha"])
        XCTAssertEqual(trie.wordCount, 2)
    }

    func testContainsExactWord() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.contains("ghbdtn"))
        XCTAssertFalse(trie.contains("ghbdt"))
    }

    func testContainsIsCaseInsensitive() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.contains("Ghbdtn"))
        XCTAssertTrue(trie.contains("GHBDTN"))
    }

    func testHasPrefixMatchesAnyPathInTheTrie() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.hasPrefix("ghb"))
        XCTAssertTrue(trie.hasPrefix("ghbdtn"))
        XCTAssertFalse(trie.hasPrefix("ghbdtx"))
    }

    func testHasPrefixIsCaseInsensitive() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.hasPrefix("GHB"))
    }

    func testEmptyStringIsNeverAMember() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertFalse(trie.contains(""))
        XCTAssertFalse(trie.hasPrefix(""))
    }

    func testCountCompletionsStopsAtLimit() {
        let trie = TestDictionaries.makeTrie(["bear", "beast", "best", "beta"])
        XCTAssertEqual(trie.countCompletions(of: "be", limit: 3), 3)
        XCTAssertEqual(trie.countCompletions(of: "be", limit: 10), 4)
    }

    func testInsertOfEmptyStringIsIgnored() {
        let trie = Trie()
        trie.insert("")
        XCTAssertEqual(trie.wordCount, 0)
    }
}
