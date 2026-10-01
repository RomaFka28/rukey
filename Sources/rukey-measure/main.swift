// rukey-measure - replay real words through the REAL detector and engine.
//
// Why this exists rather than trusting tools/measure_rules.py: the Python script is a
// MIRROR of the decision logic, and a mirror can only ever prove that the logic is
// consistent with itself. Worse, the mirror gets the semantics wrong in a way that
// flatters it, documented in detail at the bottom of this file.
//
// This tool feeds characters through the same `KeyboardEngine` the live tap uses, so the
// numbers below describe the program that actually runs.
//
// Usage: swift run rukey-measure [sample-size]

import Foundation
import RukeyCore

let sampleSize = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 1000 : 1000
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// MARK: - Corpora

/// The exact alphabets, not `isalpha()` - see the `ƒа` note in the build script.
let alphabets: [Language: Set<Character>] = [
    .russian: Set("абвгдежзийклмнопрстуфхцчшщъыьэюя"),
    .english: Set("abcdefghijklmnopqrstuvwxyz"),
]

/// One entry per word, in frequency order.
struct Corpus: Sendable {
    let words: [String]

    init(path: URL, language: Language) {
        let allowed = alphabets[language]!
        var seen = Set<String>()
        var out: [String] = []
        for line in (try? String(contentsOf: path, encoding: .utf8))?
            .split(separator: "\n") ?? [] {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 2, let _ = Int(parts[1]) else { continue }
            let folded = Self.fold(String(parts[0]), language: language)
            guard folded.count >= 2 else { continue }
            guard folded.allSatisfy({ allowed.contains($0) }) else { continue }
            guard seen.insert(folded).inserted else { continue }
            out.append(folded)
        }
        words = out
    }

    /// Lowercase, and ё folded to е - the same normalisation the runtime dictionary uses.
    static func fold(_ word: String, language: Language) -> String {
        let lowered = word.lowercased()
        guard language == .russian else { return lowered }
        return String(lowered.map { $0 == "ё" ? "е" : $0 })
    }
}

let russianCorpus = Corpus(path: root.appendingPathComponent("tools/cache/ru_50k.txt"), language: .russian)
let englishCorpus = Corpus(path: root.appendingPathComponent("tools/cache/en_50k.txt"), language: .english)

func loadDictionary(_ language: String) throws -> DictionaryIndex {
    let text = try String(contentsOf: root.appendingPathComponent("Resources/dict/\(language).txt"),
                          encoding: .utf8)
    return DictionaryIndex(words: text.split(separator: "\n").map(String.init))
}

let russianTable = try LanguageTable(
    language: .russian,
    layout: LayoutLoader.load(language: .russian),
    dictionary: loadDictionary("ru"))
let englishTable = try LanguageTable(
    language: .english,
    layout: LayoutLoader.load(language: .english),
    dictionary: loadDictionary("en"))

// MARK: - Replay

/// What happened when one word was typed.
struct Outcome: Sendable {
    var fired = false
    /// Screen text at the moment it fired.
    var buffer = ""
    /// What it was rewritten to.
    var replacement = ""
    /// Index of the keystroke that fired, 0-based.
    var position = 0

    /// Whether it fired before the last keystroke. Set explicitly by `replay`, because the
    /// engine clears its own buffer on a match and so cannot report this afterwards.
    var isMidWordOverride = false
    var isMidWord: Bool { isMidWordOverride }
}

func replay(_ screenText: String, layout: Language,
            detector: Detector, switcher: InputSourceSwitcher) -> Outcome {
    var engine = KeyboardEngine(detector: detector, switcher: switcher,
                                russianLayout: russianTable.layout, englishLayout: englishTable.layout)
    var index = 0
    for character in screenText {
        switch engine.type(character, layout: layout) {
        case .correct(let original, let replacement, _):
            // `original` is the wrong-layout text consumed so far, i.e. the first `index + 1`
            // characters of screenText. Its length is the keystroke count, which is what
            // "mid-word" has to be measured against - the engine clears its own buffer, so
            // asking the engine would always report position == length.
            var outcome = Outcome(fired: true, buffer: original, replacement: replacement, position: index)
            outcome.isMidWordOverride = index < screenText.count - 1
            return outcome
        case .undo:
            break
        case .none:
            break
        }
        index += 1
    }
    return Outcome()
}

/// The text that physically appears when the keys of `word` are pressed while `typedIn` is
/// the active layout.
///
/// Direction matters, and getting it backwards silently yields nil for every word:
/// `reencode` looks each character's keycode up in the RECEIVER's table and asks the
/// argument what those keycodes produce. So the receiver must be the table the word is
/// written in, and the argument the layout actually active - not the other way round.
func garbage(for word: String, writtenIn wordLanguage: Language, typedIn layout: Language) -> String? {
    let wordTable = wordLanguage == .russian ? russianTable : englishTable
    let layoutTable = layout == .russian ? russianTable : englishTable
    return wordTable.reencode(word, into: layoutTable)
}

func measure(detector: Detector, switcher: InputSourceSwitcher) {
    // False positives: words typed correctly in their own layout must not be rewritten.
    var fpRussian: [Outcome] = []
    for word in russianCorpus.words.prefix(sampleSize) {
        let outcome = replay(word, layout: .russian, detector: detector, switcher: switcher)
        if outcome.fired { fpRussian.append(outcome) }
    }
    var fpEnglish: [Outcome] = []
    for word in englishCorpus.words.prefix(sampleSize) {
        let outcome = replay(word, layout: .english, detector: detector, switcher: switcher)
        if outcome.fired { fpEnglish.append(outcome) }
    }

    // Detection: the word's keys pressed in the WRONG layout, so the screen shows garbage.
    var caughtEnglish: [Outcome] = []
    for word in englishCorpus.words.prefix(sampleSize) {
        // The word is English but the keys are pressed on a Russian keyboard: the screen
        // shows Russian letters, so the replayed buffer must be checked against the Russian
        // alphabet.
        guard let shown = garbage(for: word, writtenIn: .english, typedIn: .russian),
              shown.allSatisfy({ alphabets[.russian]!.contains($0) }) else { continue }
        let outcome = replay(shown, layout: .russian, detector: detector, switcher: switcher)
        if outcome.fired { caughtEnglish.append(outcome) }
    }
    var caughtRussian: [Outcome] = []
    for word in russianCorpus.words.prefix(sampleSize) {
        guard let shown = garbage(for: word, writtenIn: .russian, typedIn: .english),
              shown.allSatisfy({ alphabets[.english]!.contains($0) }) else { continue }
        let outcome = replay(shown, layout: .english, detector: detector, switcher: switcher)
        if outcome.fired { caughtRussian.append(outcome) }
    }

    func percent(_ count: Int) -> String {
        String(format: "%5.2f%%", 100 * Double(count) / Double(sampleSize))
    }
    let midEnglish = caughtEnglish.filter(\.isMidWord).count
    let midRussian = caughtRussian.filter(\.isMidWord).count

    print(String(format: "  FP ru %@ (%d)   FP en %@ (%d)   caught en-on-ru %@ (%d)   ru-on-en %@ (%d)",
                 percent(fpRussian.count), fpRussian.count,
                 percent(fpEnglish.count), fpEnglish.count,
                 percent(caughtEnglish.count), caughtEnglish.count,
                 percent(caughtRussian.count), caughtRussian.count))
    print(String(format: "        mid-word: en-on-ru %d/%d   ru-on-en %d/%d",
                 midEnglish, caughtEnglish.count, midRussian, caughtRussian.count))

    if !fpRussian.isEmpty {
        let shown = Array(Set(fpRussian.map { "\($0.buffer)->\($0.replacement)" })).sorted()
        print("        ru FP: \(shown.prefix(12).joined(separator: " "))")
    }
    if !fpEnglish.isEmpty {
        let shown = Array(Set(fpEnglish.map { "\($0.buffer)->\($0.replacement)" })).sorted()
        print("        en FP: \(shown.prefix(12).joined(separator: " "))")
    }
}

// MARK: - Report

let switcher = InputSourceSwitcher()
print("replaying through the real KeyboardEngine, sample = top \(sampleSize) by frequency")
print("corpora: ru=\(russianCorpus.words.count) en=\(englishCorpus.words.count)")
print("runtime dictionaries: ru=\(russianTable.words.wordCount) en=\(englishTable.words.wordCount)")
print("ru head: \(russianCorpus.words.prefix(10).joined(separator: " "))")
print("en head: \(englishCorpus.words.prefix(10).joined(separator: " "))\n")

for rule in [MatchRule.wholeWord, .prefixTree] {
    let name = rule == .wholeWord ? "A whole-word " : "B prefix-tree"
    print("=== rule \(name) ===")
    for threshold in 2...5 {
        print("  L=\(threshold)")
        let detector = Detector(english: englishTable, russian: russianTable,
                                minimumEvidence: threshold, rule: rule)
        measure(detector: detector, switcher: switcher)
    }
    print()
}

// MARK: - Why the Python mirror cannot be trusted

print("""
--- a bug in tools/measure_rules.py, found by writing this ---

For the DETECTION case the mirror passes an English word as the screen buffer and then
re-encodes it, which is the identity: reencode("hello", US) == "hello". It then finds
"hello" in the English dictionary and reports a detection.

That is not the scenario. When the user physically types h-e-l-l-o on a RUSSIAN layout
the screen shows руддщ, and only THAT must be re-decoded back into English. Feeding the
English word itself measures "is this word in its own dictionary", which is true almost
always - that is where the suspiciously flat 96-98% detection came from, and it is why
the mirror looked insensitive to L.

The FP case in the mirror is sound: it feeds a correctly-typed word and checks whether
re-decoding it into the other language hits a word. Those numbers stand.

The tool above fixes the direction by rendering each word through the real
LanguageTable.reencode, so the buffer is the text that would actually be on screen.
""")
