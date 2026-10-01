import Testing
import Foundation
@testable import RukeyCore

/// The decision logic, tested with no event tap involved.
///
/// The thresholds here mirror the measurement in tools/measure_rules.py:
/// prefixTree at L=4 was the only combination with 0.0% false positives on correctly-typed
/// Russian while still correcting 83% of English typed on a Russian keyboard, firing
/// mid-word 67% of the time.
@Suite("Detector decision logic")
struct DetectorTests {

    /// Real layout tables from the system, real word lists from Resources/dict.
    private func makeDetector(
        minimumEvidence: Int = 4,
        rule: MatchRule = .prefixTree
    ) throws -> Detector {
        let en = LanguageTable(
            language: .english,
            layout: try LayoutLoader.load(language: .english),
            dictionary: try Self.loadWords("en")
        )
        let ru = LanguageTable(
            language: .russian,
            layout: try LayoutLoader.load(language: .russian),
            dictionary: try Self.loadWords("ru")
        )
        return Detector(english: en, russian: ru, minimumEvidence: minimumEvidence, rule: rule)
    }

    private static func loadWords(_ lang: String) throws -> DictionaryIndex {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/dict/\(lang).txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return DictionaryIndex(words: text.split(separator: "\n").map(String.init))
    }

    // MARK: - The headline case

    @Test("English typed on a Russian layout converts mid-word")
    func englishOnRussianLayout() throws {
        let d = try makeDetector()
        // h-e-l-l typed on a Russian keyboard puts "рудд" on screen. Re-decoded, those are
        // the keys of "hell", which is the start of "hello": enough to act on.
        #expect(d.intent(for: "руд", current: .russian) == .undecided,
                "3 characters is below the L=4 threshold")
        #expect(d.intent(for: "рудд", current: .russian) == .convert(to: .english, text: "hell"),
                "must fire before the last letter, not after the word ends")
    }

    @Test("Russian typed on an English layout converts mid-word")
    func russianOnEnglishLayout() throws {
        let d = try makeDetector()
        // п-р-и-в typed on a US keyboard puts "ghbd" on screen -> "прив", the start of
        // "привет".
        #expect(d.intent(for: "ghb", current: .english) == .undecided,
                "3 characters is below the L=4 threshold")
        #expect(d.intent(for: "ghbd", current: .english) == .convert(to: .russian, text: "прив"))
    }

    // MARK: - Never touch correct text

    @Test("correctly typed Russian is never converted", arguments: [
        "привет", "мир", "который", "человек", "сегодня", "наконец", "почему", "зачем",
    ])
    func correctRussianIsLeftAlone(word: String) throws {
        let d = try makeDetector()
        // Words shorter than the threshold are `undecided` rather than `correct`: there is
        // not enough evidence either way. The property that matters is that a correctly
        // typed word is never rewritten, so assert that directly.
        if case .convert = d.intent(for: word, current: .russian) {
            Issue.record("\(word) is correct Russian and must never be converted")
        }
        if word.count >= d.minimumEvidence {
            #expect(d.intent(for: word, current: .russian) == .correct,
                    "\(word) is long enough to judge, and it is correct Russian")
        }
    }

    @Test("correctly typed English is never converted", arguments: [
        "hello", "world", "because", "thought", "people", "should", "through",
    ])
    func correctEnglishIsLeftAlone(word: String) throws {
        let d = try makeDetector()
        if case .convert = d.intent(for: word, current: .english) {
            Issue.record("\(word) is correct English and must never be converted")
        }
        if word.count >= d.minimumEvidence {
            #expect(d.intent(for: word, current: .english) == .correct,
                    "\(word) is long enough to judge, and it is correct English")
        }
    }

    /// The false positives measured at L=2 and L=3 on the real corpora. At L=4 with the
    /// prefix tree, none of these may fire.
    @Test("the measured false-positive prefixes do not fire at L=4", arguments: [
        "вну", "дум", "куд", "пре", "пут", "сег", "смы", "туд", "усп",
    ])
    func measuredFalsePositivesAreSuppressed(word: String) throws {
        let d = try makeDetector()
        #expect(d.intent(for: word, current: .russian) == .undecided,
                "\(word) measured as a false positive at L=3; must not convert at L=4")
    }

    // MARK: - The threshold and the rule are what do the work

    @Test("the prefix tree is what makes mid-word firing possible")
    func ruleMatters() throws {
        // wholeWord cannot fire on "hell", because "hell" must itself be a word.
        // prefixTree can, because it is a prefix of "hello".
        let en = LanguageTable(language: .english, layout: try LayoutLoader.load(language: .english),
                               dictionary: DictionaryIndex(words: ["hello"]))
        let ru = LanguageTable(language: .russian, layout: try LayoutLoader.load(language: .russian),
                               dictionary: DictionaryIndex(words: ["привет"]))

        let strict = Detector(english: en, russian: ru, minimumEvidence: 4, rule: .wholeWord)
        #expect(strict.intent(for: "рудд", current: .russian) != .convert(to: .english, text: "hell"),
                "wholeWord has no evidence for 'hell' when only 'hello' is in the list")

        let eager = Detector(english: en, russian: ru, minimumEvidence: 4, rule: .prefixTree)
        #expect(eager.intent(for: "рудд", current: .russian) == .convert(to: .english, text: "hell"),
                "prefixTree sees 'hell' as the start of 'hello'")
    }

    @Test("lowering the threshold to L=3 lets the measured false positives through")
    func thresholdIsWhatSuppressesThem() throws {
        let d = try makeDetector(minimumEvidence: 3, rule: .prefixTree)
        // "пут" -> "gen" was a false positive at L=3 with the real corpus.
        if case .convert = d.intent(for: "пут", current: .russian) {
            // Expected at L=3; if this ever stops being true the corpora changed and the
            // numbers in PLAN.md need re-measuring.
            return
        }
        Issue.record("expected 'пут' to convert at L=3; if not, re-measure the thresholds")
    }

    // MARK: - Single-alphabet guarantee

    @Test("a conversion result can never mix alphabets", arguments: [
        "руддщ", "ghbdtn", "йцукен", "asdfgh", "привет", "hello",
    ])
    func conversionIsSingleAlphabet(sample: String) throws {
        // The user's "don't rewrite half a word" requirement. Re-decoding from one table
        // cannot mix alphabets: every output character comes from that table.
        let en = LanguageTable(language: .english, layout: try LayoutLoader.load(language: .english),
                               dictionary: DictionaryIndex(words: []))
        let ru = LanguageTable(language: .russian, layout: try LayoutLoader.load(language: .russian),
                               dictionary: DictionaryIndex(words: []))

        guard let converted = en.reencode(sample, into: ru) else { return }
        #expect(
            converted.allSatisfy { $0.isLetter && !$0.isASCII },
            "\(sample) -> \(converted) must be entirely Cyrillic"
        )
        #expect(ru.reencode(converted, into: en) == sample, "round trip must be lossless")
    }

    @Test("re-decoding fails on characters this layout cannot produce")
    func reencodeRejectsForeignCharacters() throws {
        let ru = LanguageTable(language: .russian, layout: try LayoutLoader.load(language: .russian),
                               dictionary: DictionaryIndex(words: []))
        let en = LanguageTable(language: .english, layout: try LayoutLoader.load(language: .english),
                               dictionary: DictionaryIndex(words: []))
        // Cyrillic letters that sit on US punctuation keys (ъ х э ж ё б ю) have no letter
        // on the other side, so those words cannot have come from a US keyboard.
        #expect(ru.reencode("ъ", into: en) == nil, "'ъ' has no US letter key")
        #expect(ru.reencode("5", into: en) == nil, "digits are not letters and are not mapped")
    }

    // MARK: - Bounds

    @Test("a runaway buffer is not rewritten")
    func overlongBufferIsSafe() throws {
        let d = try makeDetector()
        #expect(d.intent(for: String(repeating: "я", count: 200), current: .russian) == .correct)
    }

    @Test("an empty buffer decides nothing")
    func emptyBufferIsUndecided() throws {
        let d = try makeDetector()
        #expect(d.intent(for: "", current: .russian) == .undecided)
    }

    @Test("punctuation never converts", arguments: ["...", "!!!", "???"])
    func punctuationNeverConverts(sample: String) throws {
        let d = try makeDetector()
        if case .convert = d.intent(for: sample, current: .russian) {
            Issue.record("\(sample) must never convert")
        }
    }
}

@Suite("Dictionary index")
struct DictionaryIndexTests {
    @Test("membership is exact, not a prefix match")
    func exactMembership() {
        let d = DictionaryIndex(words: ["hello", "hell", "world"])
        #expect(d.contains("hello"))
        #expect(d.contains("hell"))
        #expect(!d.contains("hel"), "contains() is not a prefix test")
        #expect(!d.contains("hellow"))
        #expect(!d.contains(""))
    }

    @Test("prefix matching accepts only real prefixes", arguments: [
        ("hel", true), ("hell", true),
        ("hz", false), ("z", false), ("helloo", false), ("o", false),
    ])
    func prefixMatching(prefix: String, expected: Bool) {
        // "hello" is in the list but nothing longer starts with it, so it is not a
        // proper prefix. See the dedicated test below.
        let d = DictionaryIndex(words: ["hello", "world"])
        #expect(d.containsPrefix(prefix) == expected,
                "containsPrefix(\(prefix)) should be \(expected)")
    }

    @Test("a word is not its own prefix")
    func wholeWordIsNotAProperPrefix() {
        let d = DictionaryIndex(words: ["hello"])
        #expect(d.contains("hello"))
        #expect(!d.containsPrefix("hello"),
                "nothing longer starts with 'hello', so it is not evidence")
    }

    @Test("a short word can be a prefix of a longer one")
    func shortWordCanBeAPrefix() {
        let d = DictionaryIndex(words: ["he", "hello"])
        #expect(d.containsPrefix("he"),
                "'he' is itself a word AND a proper prefix of 'hello'")
    }

    @Test("prefix lookup finds a longer word past an exact match")
    func prefixLookupSkipsPastExactMatch() {
        // The lower bound lands on "he" itself; the answer is the NEXT word. A lookup that
        // stops at the exact match answers false here, which silently disables mid-word
        // firing for every word that is itself a prefix of another.
        let d = DictionaryIndex(words: ["he", "hello", "help", "helm"])
        #expect(d.containsPrefix("he"))
        #expect(d.containsPrefix("hel"))
        #expect(d.containsPrefix("hell"), "'hello' and 'help' both start with 'hell'")
        #expect(!d.containsPrefix("hellp"), "nothing starts with 'hellp'")
        #expect(!d.containsPrefix("helloo"))
    }

    @Test("duplicates collapse and case is ignored")
    func dedupAndCaseFold() {
        let d = DictionaryIndex(words: ["Hello", "hello", "HELLO"])
        #expect(d.wordCount == 1)
        #expect(d.contains("Hello"))
    }

    @Test("allWords round-trips the input")
    func allWordsRoundTrips() {
        let words = ["alpha", "beta", "gamma"]
        #expect(Set(DictionaryIndex(words: words).allWords()) == Set(words))
    }

    @Test("UTF-8 byte ordering puts lookalike letters apart")
    func byteOrdering() {
        let sorted = DictionaryIndex(words: ["zebra", "абрикос", "apple"]).allWords()
        #expect(sorted == sorted.sorted {
            Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
        })
    }
}