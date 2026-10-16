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

    func testTaughtWordIsNotConvertedBackEvenWhenItsLatinFormIsReal() {
        // The discriminating fixture for the *current*-side widening: "руддщ"
        // spells "hello", a real English dictionary word, so without
        // `isCurrentValid` widening the classic flip fires and returns hello.
        // With it, the taught word wins. The заозкздзаоз pair cannot show this —
        // there the converted side is not a word at all, so the branch is
        // unreachable either way and the mutation survives.
        let (detector, _) = makeTaughtDetector(words: ["руддщ"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "руддщ", currentLanguage: .russian))
        // Positive control: without the taught word the very same pair converts,
        // so the nil above cannot be a dead path.
        let (control, _) = makeTaughtDetector(words: [])
        XCTAssertEqual(
            control.evaluateFullWord(buffer: "руддщ", currentLanguage: .russian)?.convertedText,
            "hello")
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

    // MARK: - The custom dictionary on the punctuated path

    func testTaughtWordWithEdgePunctuationIsNotFlipped() {
        // The punctuated path is the third decision site and must consult the
        // custom dictionary exactly as the other two do. Without the widening this
        // exact case returned `привет!` while `ghbdtn` alone returned nil.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn!", currentLanguage: .english))
        // Control: with nothing taught the very same token really does convert, so
        // the nil above cannot be a dead path.
        let (control, _) = makeTaughtDetector(words: [])
        XCTAssertEqual(
            control.evaluateFullWord(buffer: "ghbdtn!", currentLanguage: .english)?.convertedText,
            "привет!")
    }

    func testTaughtWordConvertsWithEdgePunctuation() {
        // The converse direction: teaching `заозкздзаоз` lets its Latin typing
        // convert, and that must keep working when the token carries punctuation —
        // otherwise the taught word would land only sometimes.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "pfjprplpfjp,", currentLanguage: .english)?
                .convertedText,
            "заозкздзаоз,")
    }

    func testTaughtWordPrefixIsNotProtectedOnEitherPath() {
        // A longer taught word does not promote its own prefix to a word of its
        // own. The boundary path and the punctuated path must agree, exactly as
        // they do for the bare form; protecting a prefix on one path but not the
        // other is the shape of defect Review Focus #5 exists to prevent. This is
        // why the punctuated path takes `contains`, not `isPrefixOfKnown`.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtnabc"])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english)?.convertedText,
            "привет")
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn!", currentLanguage: .english)?.convertedText,
            "привет!")
    }

    // MARK: - Pinning the widened arms

    func testTaughtRussianPrefixIsNotFlippedIntoLatinMidWord() {
        // Pins the Russian branch's `isCurrentValid` widening. The Latin form is
        // taught too, so the flip branch is reachable: only that widening stands
        // between the taught word's prefix and a mid-word flip into Latin.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз", "pfjhello"])
        XCTAssertNil(detector.evaluate(buffer: "зао", currentLanguage: .russian))
    }

    func testTaughtLatinWordConvertsFromItsCyrillicKeystrokesMidWord() {
        // Pins the Russian branch's `isConvertedValid` widening *and* its junk-gate
        // waiver at once: `чндщзр` spells `xyloph`, which starts no `enTrie` word
        // (`countCompletions == 0`), so the gate would block a flip the waiver must
        // let through.
        let (detector, _) = makeTaughtDetector(words: ["xylophone"])
        XCTAssertEqual(
            detector.evaluate(buffer: "чндщзр", currentLanguage: .russian)?.convertedText,
            "xyloph")
    }

    func testTaughtLatinWordIsNotFlippedBackMidWord() {
        // Pins the English branch's on-the-fly `isCurrentValid` widening. `привет`
        // clears the junk bar and `ghbdtn` starts no `enTrie` word, so nothing but
        // the widening can make the taught word valid here.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtnabc"])
        XCTAssertNil(detector.evaluate(buffer: "ghbdtn", currentLanguage: .english))
    }

    func testTaughtLatinWordSurvivesAtTheWordBoundary() {
        // The same widening on the boundary path, mirroring the `руддщ` case on
        // the English side.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
    }

    // MARK: - Persistence behaviours worth a pin

    func testPersistCreatesTheConfigDirectory() {
        // A fresh install has no `~/.config/rukey` yet; the first taught word must
        // still reach the disk rather than fail inside the caught write error.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-\(UUID().uuidString)")  // does not exist
        let url = directory.appendingPathComponent("custom.json")
        let dictionary = CustomDictionary(fileURL: url)
        dictionary.replaceAll(with: ["заозкздзаоз"])
        XCTAssertTrue(CustomDictionary(fileURL: url).contains("заозкздзаоз"))
    }

    func testUnwritableSaveIsReportedNotSwallowed() {
        // A silently lost taught word is exactly what spec anti-goal 2 forbids. Put
        // a *file* where the directory must be created, so the save throws.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        try? Data().write(to: blocker)
        let buffer = LogBuffer()
        let dictionary = CustomDictionary(
            fileURL: blocker.appendingPathComponent("custom.json"), logBuffer: buffer)
        dictionary.replaceAll(with: ["заозкздзаоз"])
        XCTAssertTrue(buffer.lines().contains { $0.level == .warn })
    }
}
