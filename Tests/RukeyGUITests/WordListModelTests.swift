import XCTest
@testable import RukeyCore
@testable import RukeyGUI

@MainActor
final class WordListModelTests: XCTestCase {
    func testAddingANonBlankWordReachesTheFilter() {
        let filter = WordFilter()
        let dictionary = CustomDictionary(fileURL: temporaryURL())
        let model = WordListModel(
            filter: filter, dictionary: dictionary,
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addExcluded("ghbdtn")
        XCTAssertTrue(filter.isExcluded("ghbdtn"))
    }

    func testBlankInputIsIgnored() {
        let filter = WordFilter()
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addExcluded("   ")
        XCTAssertTrue(filter.isEmpty)
    }

    func testDuplicatesAreRejected() {
        let filter = WordFilter(words: ["ghbdtn"])
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addExcluded("ghbdtn")
        XCTAssertEqual(filter.words, ["ghbdtn"])
    }

    func testRemovingAWrittenWord() {
        let filter = WordFilter(words: ["ghbdtn"])
        var written: [Set<String>] = []
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()),
            writer: { written.append($0) })
        model.removeExcluded("ghbdtn")
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(written, [Set()])
    }

    func testTwoWordsBothPersistAsAUnion() {
        let filter = WordFilter()
        var written: [Set<String>] = []
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()),
            writer: { written.append($0) })
        model.addExcluded("ghbdtn")
        model.addExcluded("hello")
        XCTAssertEqual(written.last, ["ghbdtn", "hello"])
    }

    func testLearnedWordIsRemovableAndStaysGone() {
        let filter = WordFilter(words: ["ghb"])
        var written: [Set<String>] = []
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()),
            writer: { written.append($0) })
        model.removeExcluded("ghb")
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(written.last, [])
    }

    func testRemovingALearnedWordClearsItsStrikes() {
        let strikes = StrikeStore(fileURL: temporaryURL())
        _ = strikes.registerUndo(key: "ghb")
        let filter = WordFilter(words: ["ghb"])
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: strikes, writer: { _ in })
        model.removeExcluded("ghb")
        XCTAssertEqual(strikes.strikes(for: "ghb"), 0)
        XCTAssertEqual(strikes.registerUndo(key: "ghb"), 1,
                       "re-learning must start from a fresh count, not continue at the old one")
    }

    func testTaughtWordsGoToTheCustomDictionaryNotTheFilter() {
        let filter = WordFilter()
        let dictionary = CustomDictionary(fileURL: temporaryURL())
        let model = WordListModel(
            filter: filter, dictionary: dictionary,
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addTaught("абракадабра")
        XCTAssertTrue(dictionary.contains("абракадабра"))
        XCTAssertTrue(filter.isEmpty)
    }
}

/// A fresh path under the system temporary directory, so no test reads or
/// writes the real `~/.config/rukey`.
private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rukey-wordlist-\(UUID().uuidString).json")
}
