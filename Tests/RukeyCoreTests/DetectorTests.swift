import XCTest
@testable import RukeyCore

final class DetectorTests: XCTestCase {
    private func makeDetector(
        minTargetCompletions: Int = 3,
        minPrefixLength: Int = 3
    ) -> Detector {
        Detector(
            enTrie: TestDictionaries.enTrie,
            ruTrie: TestDictionaries.ruTrie,
            minPrefixLength: minPrefixLength,
            minTargetCompletions: minTargetCompletions
        )
    }

    func testFullWordLatinTypingRussianLayoutConverts() {
        let decision = makeDetector().evaluateFullWord(
            buffer: "ghbdtn", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "привет")
        XCTAssertEqual(decision?.triggerRule, "full_word_en_to_ru")
    }

    func testFullWordRussianTypingLatinLayoutConverts() {
        let decision = makeDetector().evaluateFullWord(
            buffer: "руддщ", currentLanguage: .russian)
        XCTAssertEqual(decision?.convertedText, "hello")
        XCTAssertEqual(decision?.triggerRule, "full_word_ru_to_en")
    }

    func testValidWordIsLeftAlone() {
        XCTAssertNil(makeDetector().evaluateFullWord(buffer: "привет", currentLanguage: .russian))
    }

    func testCapitalisedWordBehavesLikeLowercase() {
        // Capitalisation is carried through the mapping table, not stripped:
        // "Ghbdtn" yields "Привет". Identical behaviour, capital P preserved.
        let decision = makeDetector().evaluateFullWord(
            buffer: "Ghbdtn", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "Привет")
        XCTAssertEqual(decision?.triggerRule, "full_word_en_to_ru")
    }

    func testJunkBackedPrefixDoesNotFlipOnTheFly() {
        // "ghb" -> "при" is backed by exactly two RU entries (привет, приветствие),
        // one below the bar of 3 — the mid-word flip must not fire.
        // (testWellBackedPrefixFlipsOnTheFly flips the very same buffer at a bar of 2.)
        XCTAssertNil(makeDetector(minTargetCompletions: 3).evaluate(
            buffer: "ghb", currentLanguage: .english))
    }

    func testWellBackedPrefixFlipsOnTheFly() {
        // "ghb" -> "при": two dictionary entries sit behind "при"
        // (привет, приветствие), which clears the junk-backed-prefix bar.
        let decision = makeDetector(minTargetCompletions: 2).evaluate(
            buffer: "ghb", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "при")
        XCTAssertEqual(decision?.triggerRule, "en_invalid_prefix_ru_valid")
    }

    func testShortBufferIsIgnored() {
        XCTAssertNil(makeDetector().evaluate(buffer: "be", currentLanguage: .english))
    }

    func testPunctuatedTokenConvertsVerbatimEdges() {
        let decision = makeDetector().evaluateFullWord(
            buffer: "ghbdtn,", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "привет,")
    }

    func testTrailingPunctuationOnlyRunIsIgnored() {
        XCTAssertNil(makeDetector().evaluateFullWord(buffer: "hello!", currentLanguage: .english))
    }
}
