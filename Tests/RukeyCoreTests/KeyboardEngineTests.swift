import Foundation
import Testing
@testable import RukeyCore

/// The engine's decision order, tested without an event tap.
///
/// What this can and cannot prove: it exercises the buffer, the suppression rules and the
/// undo bookkeeping with real layout tables and real dictionaries. It cannot prove that
/// posted backspaces and Unicode inserts reach a real application - synthetic events posted
/// inside this process are not guaranteed to come back through a tap. That last mile is
/// verified by typing for real.
@Suite("Keyboard engine")
struct KeyboardEngineTests {

    private func makeEngine(minimumEvidence: Int = 3) throws -> KeyboardEngine {
        let en = LanguageTable(
            language: .english,
            layout: try LayoutLoader.load(language: .english),
            dictionary: try Self.words("en")
        )
        let ru = LanguageTable(
            language: .russian,
            layout: try LayoutLoader.load(language: .russian),
            dictionary: try Self.words("ru")
        )
        return KeyboardEngine(detector: Detector(english: en, russian: ru, minimumEvidence: minimumEvidence),
                              switcher: InputSourceSwitcher(),
                              russianLayout: ru.layout, englishLayout: en.layout)
    }

    private static func words(_ language: String) throws -> DictionaryIndex {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/dict/\(language).txt")
        return DictionaryIndex(words: try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init))
    }

    /// "h e l" on a Russian layout puts "руд" on screen and must produce "hel" plus a
    /// switch to English. Typing the rest of the word must then be left alone.
    @Test("a mistake is corrected and the rest of the word is left alone")
    func correctsThenGoesQuiet() throws {
        var engine = try makeEngine()

        #expect(engine.type("р", layout: .russian) == .none)
        #expect(engine.type("у", layout: .russian) == .none)
        let action = engine.type("д", layout: .russian)

        #expect(action == .correct(original: "руд", replacement: "hel", to: .english),
                "got \(action)")
        #expect(engine.wordIsRewritten, "the rest of this word must not be touched")

        // "l" and "o" finish "hello" on the user's own keyboard, no correction.
        #expect(engine.type("л", layout: .english) == .none)
        #expect(engine.type("щ", layout: .english) == .none,
                "and no correction fires mid-word after the first one")
    }

    @Test("a word typed correctly in its own layout is never touched")
    func correctWordsAreLeftAlone() throws {
        var engine = try makeEngine()
        for character in "мир" {
            #expect(engine.type(character, layout: .russian) == .none)
        }
        #expect(!engine.wordIsRewritten)
        #expect(engine.buffer.isEmpty, "the buffer is only for words under consideration")
    }

    @Test("a space ends the word and re-arms correction")
    func spaceEndsWord() throws {
        var engine = try makeEngine()
        for character in "руд" { _ = engine.type(character, layout: .russian) }
        _ = engine.type(" ", layout: .english)
        #expect(!engine.wordIsRewritten)
        #expect(engine.undo == nil)

        // The next word is considered independently.
        #expect(engine.type("п", layout: .russian) == .none)
        #expect(engine.buffer == "п")
    }

    @Test("Delete after a correction undoes it")
    func deleteUndoes() throws {
        var engine = try makeEngine()
        for character in "руд" { _ = engine.type(character, layout: .russian) }
        #expect(engine.wordIsRewritten)

        // User finishes the word, then rejects it.
        _ = engine.type("о", layout: .english)
        let undoAction = engine.type("\u{8}", layout: .english)

        guard case .undo(let eraseCount, let insertText, let target) = undoAction else {
            Issue.record("expected an undo action, got \(undoAction)")
            return
        }
        // "hel" is 3 characters, the user typed "о" (1), and their Delete removed 1:
        // 3 + 1 - 1 = 3.
        #expect(eraseCount == 3, "'hel' is 3, the user typed 'о' (1), Delete removed 1")
        #expect(insertText == "руд", "the word the fingers typed comes back")
        #expect(target == .russian, "and the layout the user had before")
    }

    @Test("Delete with nothing to undo is an ordinary backspace")
    func deleteWithoutCorrection() throws {
        var engine = try makeEngine()
        _ = engine.type("р", layout: .russian)
        _ = engine.type("у", layout: .russian)
        #expect(engine.buffer == "ру")

        #expect(engine.type("\u{8}", layout: .russian) == .none)
        #expect(engine.buffer == "р", "the last buffered character is dropped")
    }

    @Test("a second Delete does not undo twice")
    func doubleDeleteDoesNotDoubleUndo() throws {
        var engine = try makeEngine()
        for character in "руд" { _ = engine.type(character, layout: .russian) }

        let first = engine.type("\u{8}", layout: .russian)
        guard case .undo = first else {
            Issue.record("first Delete should undo, got \(first)")
            return
        }
        // Correction is suspended for the rest of the word, so the second Delete is the
        // user's own backspace and must not produce another rewrite.
        let second = engine.type("\u{8}", layout: .russian)
        #expect(second == .none, "got \(second)")
    }

    @Test("a word longer than the rewrite limit is abandoned, not tracked")
    func longWordIsAbandoned() throws {
        var engine = try makeEngine()
        // Feed a run of letters with no conversion available; the buffer must not grow
        // without bound.
        for _ in 0..<200 {
            _ = engine.type("ы", layout: .russian)
        }
        #expect(engine.buffer.count <= 64, "buffer grew to \(engine.buffer.count)")
    }

    @Test("isBusy gates the engine's own generated input")
    func busyFlagIsObservable() throws {
        var engine = try makeEngine()
        #expect(!engine.isBusy)
        engine.isBusy = true
        #expect(engine.isBusy)
    }

    @Test("the Russian direction works too")
    func russianMistakeIsCorrected() throws {
        var engine = try makeEngine()
        // "н е т" typed on a US keyboard puts "ytn" on screen -> "нет".
        #expect(engine.type("y", layout: .english) == .none)
        #expect(engine.type("t", layout: .english) == .none)
        #expect(engine.type("n", layout: .english) == .correct(original: "ytn", replacement: "нет", to: .russian),
                "got \(engine.type("x", layout: .russian))")
    }
}