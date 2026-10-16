import XCTest
@testable import RukeyCore

final class DetectorTests: XCTestCase {
    /// An always-empty custom dictionary on a private temporary file.
    ///
    /// `Detector.init` defaults `customDictionary` to `CustomDictionary()`, which
    /// reads `~/.config/rukey/custom.json`. Every construction in this suite passes
    /// one explicitly so no test depends on — or writes to — the real config
    /// directory of whoever runs it.
    private func makeEmptyCustomDictionary() -> CustomDictionary {
        CustomDictionary(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString).json"))
    }

    private func makeDetector(
        minTargetCompletions: Int = 3,
        minPrefixLength: Int = 3
    ) -> Detector {
        Detector(
            enTrie: TestDictionaries.enTrie,
            ruTrie: TestDictionaries.ruTrie,
            minPrefixLength: minPrefixLength,
            minTargetCompletions: minTargetCompletions,
            customDictionary: makeEmptyCustomDictionary()
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
            wordFilter: filter,
            customDictionary: makeEmptyCustomDictionary()
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

    // MARK: - Custom dictionary

    private func makeTaughtDetector(words: Set<String>) -> (Detector, CustomDictionary) {
        // A per-test temporary file: `replaceAll` writes to disk, and tests must
        // never touch the real ~/.config/rukey/custom.json.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString).json")
        let dictionary = CustomDictionary(fileURL: url, words: words)
        let detector = Detector(
            enTrie: TestDictionaries.enTrie,
            ruTrie: TestDictionaries.ruTrie,
            minPrefixLength: 3,
            minTargetCompletions: 2,
            customDictionary: dictionary
        )
        return (detector, dictionary)
    }

    func testTaughtWordConvertsAtWordBoundary() {
        // "заозкздзаоз" is exactly what "pfjprplpfjp" spells. The word must be
        // comma-free: `б` sits on the comma key, so a word containing it types
        // with an interior comma, which splits the script run and yields nil.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        let decision = detector.evaluateFullWord(
            buffer: "pfjprplpfjp", currentLanguage: .russian)
        XCTAssertEqual(decision?.convertedText, "заозкздзаоз")
    }

    func testTaughtWordAlsoEnablesTheMidWordFlip() {
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        // Flipping at "pfj" is better UX than waiting for the boundary: the
        // remaining keys then spell "зкздзаоз" in the target layout and the
        // whole word lands correctly either way.
        XCTAssertEqual(detector.evaluate(buffer: "pfj", currentLanguage: .russian)?.convertedText, "зао")
    }

    func testTaughtWordIsNotConvertedBack() {
        // A word the user taught in Russian must survive being read as English.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        XCTAssertNil(detector.evaluateFullWord(
            buffer: "заозкздзаоз", currentLanguage: .russian))
    }

    func testTaughtWordDoesNotLicenseReverseConversion() {
        // Teaching a word teaches what may be typed, not what it may become:
        // the taught Russian word is never itself flipped into Latin.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        XCTAssertFalse(
            detector.customDictionary.contains("pfjprplpfjp"),
            "the Latin form must not be taught implicitly")
        XCTAssertNil(detector.evaluateFullWord(
            buffer: "заозкздзаоз", currentLanguage: .russian))
    }

    func testCustomDictionarySwappedAtRuntimeTakesEffectImmediately() {
        let (detector, dictionary) = makeTaughtDetector(words: [])
        XCTAssertNil(detector.evaluateFullWord(
            buffer: "pfjprplpfjp", currentLanguage: .russian))
        dictionary.replaceAll(with: ["заозкздзаоз"])
        XCTAssertNotNil(detector.evaluateFullWord(
            buffer: "pfjprplpfjp", currentLanguage: .russian))
    }

    func testCustomDictionaryPersistsToCustomJSON() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString).json")
        let dictionary = CustomDictionary(fileURL: url)
        dictionary.replaceAll(with: ["заозкздзаоз"])
        let reloaded = CustomDictionary(fileURL: url)
        XCTAssertTrue(reloaded.contains("заозкздзаоз"))
    }

    func testCorruptCustomFileStartsEmptyAndReports() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString).json")
        try? "{ broken".write(to: url, atomically: true, encoding: .utf8)
        let buffer = LogBuffer()
        let dictionary = CustomDictionary(fileURL: url, logBuffer: buffer)
        XCTAssertFalse(dictionary.contains("заозкздзаоз"))
        XCTAssertTrue(buffer.lines().contains { $0.level == .warn })
    }

    func testEmptyCustomDictionaryPreservesBaselineDecision() {
        let baseline = makeDetector().evaluateFullWord(
            buffer: "ghbdtn", currentLanguage: .english)
        let (detector, _) = makeTaughtDetector(words: [])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english),
            baseline)
    }
}
