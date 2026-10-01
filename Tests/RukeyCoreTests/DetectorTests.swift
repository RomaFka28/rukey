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
    ///
    /// Defaults mirror the measured optimum: L=3 with `wholeWord` (96.1% detection,
    /// 2.1% false positives on Russian). See the MatchRule doc comment.
    private func makeDetector(
        minimumEvidence: Int = 3,
        rule: MatchRule = .wholeWord
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
        // h-e-l on a Russian keyboard puts "руд" on screen. Re-decoded, those are the keys
        // of "hel" - itself a word, so wholeWord fires here at L=3.
        #expect(d.intent(for: "ру", current: .russian) == .undecided,
                "2 characters is below the L=3 threshold")
        #expect(d.intent(for: "руд", current: .russian) == .convert(to: .english, text: "hel"),
                "fires on the third letter, before the word ends")
    }

    @Test("Russian typed on an English layout converts mid-word")
    func russianOnEnglishLayout() throws {
        let d = try makeDetector()
        // "yt" is the English-layout rendering of н-е; "ytn" adds т, giving "нет".
        #expect(d.intent(for: "yt", current: .english) == .undecided,
                "2 characters is below the L=3 threshold")
        #expect(d.intent(for: "ytn", current: .english) == .convert(to: .russian, text: "нет"),
                "н-е-т typed on a US keyboard is 'ytn' and must become 'нет'")
    }

    @Test("a sample that is a word in BOTH layouts is left alone")
    func ambiguousSampleIsNotConverted() throws {
        // "ghb" re-decodes to "при", which is a valid Russian word - so this sample looks
        // like a mistake. But "ghb" is also in the English corpus, and a word the user is
        // typing correctly must never be rewritten. The current-language check has to win.
        // Found by a failing test: the assumption that short garbage is never a real
        // English word was wrong.
        let d = try makeDetector()
        #expect(d.intent(for: "ghb", current: .english) == .correct)
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

    /// The false positives measured on the real corpora at L=3 with the real dictionary.
    /// They are accepted at L=3: the measured rate is 2.1% on Russian and Delete-to-undo
    /// exists for exactly this case. L=4 + prefixTree is the zero-FP alternative.
    @Test("the measured L=3 false positives are the accepted cost", arguments: [
        "вну", "дум", "куд", "пре", "пут", "сег", "смы", "туд", "усп",
    ])
    func measuredFalsePositivesAtL3(word: String) throws {
        let d = try makeDetector()
        if case .convert = d.intent(for: word, current: .russian) {
            return  // a known false positive; undo covers it
        }
        Issue.record("\(word) used to be a known L=3 false positive; re-measure the tables")
    }

    @Test("L=4 with the prefix tree suppresses the false positives")
    func l4PrefixTreeIsClean() throws {
        let d = try makeDetector(minimumEvidence: 4, rule: .prefixTree)
        for word in ["вну", "дум", "куд", "пре", "пут", "сег", "смы", "туд", "усп"] {
            #expect(d.intent(for: word, current: .russian) == .undecided,
                    "\(word) must not convert at L=4 + prefixTree")
        }
    }

    // MARK: - The threshold and the rule are what do the work

    @Test("the rule decides whether a mid-word prefix counts as evidence")
    func ruleMatters() throws {
        // "hell" is a real word, so wholeWord fires on it. "hellp" is not a word but is
        // the start of "hello", so only prefixTree fires there.
        let en = LanguageTable(language: .english, layout: try LayoutLoader.load(language: .english),
                               dictionary: DictionaryIndex(words: ["hello"]))
        let ru = LanguageTable(language: .russian, layout: try LayoutLoader.load(language: .russian),
                               dictionary: DictionaryIndex(words: ["привет"]))

        let strict = Detector(english: en, russian: ru, minimumEvidence: 3, rule: .wholeWord)
        #expect(strict.intent(for: "рудд", current: .russian) != .convert(to: .english, text: "hell"),
                "wholeWord has no evidence: 'hell' is not in a list that only has 'hello'")

        let eager = Detector(english: en, russian: ru, minimumEvidence: 3, rule: .prefixTree)
        #expect(eager.intent(for: "рудд", current: .russian) == .convert(to: .english, text: "hell"),
                "prefixTree sees 'hell' as the start of 'hello'")
    }

    @Test("at L=3 the prefix tree costs false positives without buying detection")
    func prefixTreeIsNotWorthItAtL3() throws {
        // The measurement that chose wholeWord for L=3, asserted so a corpus change that
        // flips it is visible.
        let d = try makeDetector(minimumEvidence: 3, rule: .prefixTree)
        #expect(d.intent(for: "пут", current: .russian) == .convert(to: .english, text: "gen"),
                "prefixTree at L=3 admits the measured 'пут->gen' false positive")
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