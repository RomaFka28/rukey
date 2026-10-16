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

    // MARK: - Word filter

    private func makeFilteredDetector(
        excluding words: Set<String>
    ) -> (Detector, WordFilter) {
        let filter = WordFilter(words: words)
        let detector = Detector(
            enTrie: TestDictionaries.enTrie,
            ruTrie: TestDictionaries.ruTrie,
            minPrefixLength: 3,
            minTargetCompletions: 2,
            wordFilter: filter
        )
        return (detector, filter)
    }

    func testExcludedFullWordIsNotConverted() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
    }

    func testExcludedWordStopsTheMidWordFlip() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluate(buffer: "ghb", currentLanguage: .english))
    }

    func testCapitalisedExcludedWordIsStillExcluded() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "Ghbdtn", currentLanguage: .english))
    }

    func testExclusionIsPerInputNotPerResult() {
        // "привет" is in the filter only as the Russian spelling, so the Latin
        // typing that produces it is unaffected.
        let (detector, _) = makeFilteredDetector(excluding: ["привет"])
        let decision = detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "привет")
    }

    func testUnrelatedWordsKeepConverting() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
        // "ntcn" is the Latin typing of "тест"; excluding "ghbdtn" must not stop it.
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ntcn", currentLanguage: .english)?.convertedText,
            "тест")
    }

    func testPunctuatedExcludedWordIsBlockedLikeTheBareWord() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn,", currentLanguage: .english))
        XCTAssertNil(detector.evaluateFullWord(buffer: ",ghbdtn", currentLanguage: .english))
    }

    func testExcludedPrefixIsBlockedOnThePunctuatedPathToo() {
        // "ntcnbhjdfnm" is the Latin typing of "тестировать" and "ntcn" is a prefix
        // of it — the Latin typing of "тест", which IS in the dictionary. Excluding
        // the longer word must not let its prefix convert on the punctuated path,
        // where the check has to be a prefix test, not an exact one.
        let (detector, _) = makeFilteredDetector(excluding: ["ntcnbhjdfnm"])
        XCTAssertNil(detector.evaluate(buffer: "ntcn", currentLanguage: .english))
        XCTAssertNil(detector.evaluateFullWord(buffer: "ntcn,", currentLanguage: .english))
        XCTAssertNil(detector.evaluateFullWord(buffer: ",ntcn", currentLanguage: .english))
    }

    func testEmptyFilterLeavesEveryBehaviourUnchanged() {
        let (detector, _) = makeFilteredDetector(excluding: [])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english)?.convertedText,
            "привет")
    }

    func testFilterSwappedAtRuntimeTakesEffectImmediately() {
        let (detector, filter) = makeFilteredDetector(excluding: [])
        XCTAssertNotNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
        filter.replaceAll(with: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
    }
}
