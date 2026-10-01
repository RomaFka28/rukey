import Foundation
import Testing

@testable import RukeyCore

/// Tests for which keystrokes reach the engine at all.
///
/// These exist because of a real failure. In the first live run the tap filtered
/// whitespace out before it reached the engine, so the space never arrived, the word never
/// ended, and the buffer accumulated the whole session:
///
///     «n» buffer «n»      «e» buffer «ne»     «a» buffer «nea»
///     «7» buffer «nea7»  «y» buffer «nea78y» ... «q» buffer «nea78yfcnhjq»
///
/// No word could ever be finished, so nothing was ever corrected, and the program looked
/// merely idle rather than broken. The rule lived in untested glue code inside the tap.
@Suite("Which keystrokes reach the engine")
struct KeyTextTests {

    @Test("the word-ending keys are forwarded")
    func forwardsWordEnders() {
        // The three characters whose absence broke the first live run. If any of these is
        // not forwardable, the engine can never finish a word.
        for character: Character in [" ", "\n", "\r", "\t"] {
            #expect(KeyText.isForwardable(character), "\(character) must reach the engine")
        }
    }

    @Test("letters, digits and punctuation are forwarded in both scripts")
    func forwardsWordContent() {
        let samples: [Character] = [
            "a", "z", "h", "e", "l", "o",              // english
            "а", "б", "ё", "ж", "ш", "ф",              // russian
            "7", "8", "0",                              // digits
            ".", ",", "!", "?", "-", ";",               // punctuation
        ]
        for character in samples {
            #expect(KeyText.isForwardable(character), "\(character) should be forwarded")
        }
    }

    @Test("control characters and DEL are not forwarded")
    func rejectsControlCharacters() {
        // Only genuine non-whitespace controls. U+000A and U+000B are the same characters
        // as "\n" and line-tab, so they are legitimately forwarded - do not use them here.
        let rejected: [Character] = [
            "\u{0}", "\u{1}", "\u{1B}",   // null, start of heading, escape
            "\u{7F}",                     // delete
            "\u{8}",                      // backspace - handled separately, never as text
            "\u{E}", "\u{F}",             // shift out, shift in
        ]
        for character in rejected {
            #expect(!KeyText.isForwardable(character), "\(character) should be dropped")
        }
    }

    @Test("the space bar is mapped when the event carries no text")
    func mapsWordEndingKeyCodes() {
        // The fallback path: some events arrive without a Unicode string, and the space
        // still has to be reported or the word never ends on those events.
        #expect(KeyText.wordEndingKeyCodes[49] == " ")
        #expect(KeyText.wordEndingKeyCodes[36] == "\r")
        #expect(KeyText.wordEndingKeyCodes[48] == "\t")
    }

    @Test("a word finishes when the space arrives through the engine")
    func spaceEndsWordInEngine() throws {
        // End to end through the real engine: the buffer must be empty after a space, not
        // still holding the word. This is the assertion the first live run would have
        // failed, had there been any test standing behind the tap's filter.
        let russian = try LanguageTable(
            language: .russian,
            layout: try LayoutLoader.load(language: .russian),
            dictionary: try Self.words("ru")
        )
        let english = try LanguageTable(
            language: .english,
            layout: try LayoutLoader.load(language: .english),
            dictionary: try Self.words("en")
        )
        var engine = KeyboardEngine(
            detector: Detector(english: english, russian: russian),
            switcher: InputSourceSwitcher(),
            russianLayout: russian.layout,
            englishLayout: english.layout
        )

        for character in "неа" { _ = engine.type(character, layout: .english) }
        #expect(engine.buffer == "неа", "buffer holds the word so far")

        _ = engine.type(" ", layout: .english)
        #expect(engine.buffer.isEmpty, "the space must clear the buffer")
    }

    /// Words typed one after another must not bleed into each other. This is the same
    /// failure seen live, reproduced in a test: without word boundaries the buffer only
    /// ever grows, and by the end of a sentence nothing can match.
    @Test("consecutive words do not accumulate")
    func consecutiveWordsStaySeparate() throws {
        let russian = try LanguageTable(
            language: .russian,
            layout: try LayoutLoader.load(language: .russian),
            dictionary: try Self.words("ru")
        )
        let english = try LanguageTable(
            language: .english,
            layout: try LayoutLoader.load(language: .english),
            dictionary: try Self.words("en")
        )
        var engine = KeyboardEngine(
            detector: Detector(english: english, russian: russian),
            switcher: InputSourceSwitcher(),
            russianLayout: russian.layout,
            englishLayout: english.layout
        )

        // Type four words, each properly closed by a space. The buffer must never hold
        // more than one word at a time.
        var longest = 0
        for word in ["abc", "def", "ghi", "jkl"] {
            for character in word { _ = engine.type(character, layout: .english) }
            longest = max(longest, engine.buffer.count)
            _ = engine.type(" ", layout: .english)
            #expect(engine.buffer.isEmpty, "buffer empty after the space in «\(word)»")
        }
        #expect(longest == 3, "buffer must never hold more than one word, saw \(longest)")
    }

    private static func words(_ language: String) throws -> DictionaryIndex {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/dict/\(language).txt")
        return DictionaryIndex(words: try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init))
    }
}
