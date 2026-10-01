import Testing
@testable import RukeyCore

@Suite("Undo arithmetic")
struct UndoStateTests {

    /// The headline case: "h e l l" typed on a Russian layout, we replaced "рудд" with
    /// "hell", the user finished the word with "o", then pressed Delete.
    @Test("undo after the word was finished restores what the fingers typed")
    func undoAfterCompletion() {
        var state = UndoState(originalText: "рудд", convertedText: "hell", originalLanguage: .russian)
        // User types "o" to finish "hello", then presses Delete -> screen shows "hell".
        state.consume("o")

        let plan = state.plan()
        #expect(plan.eraseCount == 4, "erase 'hell' (4) plus the 1 the user already deleted")
        #expect(plan.insertText == "рудд", "restore exactly what was typed, the 'o' is gone")
        #expect(plan.switchTo == .russian)
    }

    @Test("undo right after firing drops only the character's the user deleted")
    func undoImmediatelyAfterFiring() {
        var state = UndoState(originalText: "пут", convertedText: "gen", originalLanguage: .russian)
        // No continuation. The Delete removes the last character of "gen" -> "ge".
        let plan = state.plan()
        #expect(plan.eraseCount == 2, "'gen' is 3 characters, Delete already removed 1")
        #expect(plan.insertText == "пут")
    }

    /// Erase count and insert text must describe the same edit. If insert is longer than
    /// erase plus what was there, the word grows; this catches off-by-one in the algebra.
    @Test("erase count and insert text agree in length")
    func eraseCountMatchesInsertLength() {
        // Note: no word-ending characters in `typed`. `consume` returns false for those and
        // does not fold them in, so a "!" would change the arithmetic under the test.
        let samples: [(String, String, [Character])] = [
            ("рудд", "hell", []),
            ("пут", "gen", ["x"]),
            ("привет", "ghbdtn", ["o", "l"]),
            ("ручка", "herf", Array("пролд")),
        ]
        for (original, converted, typed) in samples {
            var state = UndoState(originalText: original, convertedText: converted, originalLanguage: .russian)
            var ended = false
            for c in typed { ended = state.consume(c) || ended }
            #expect(!ended, "\(converted): the samples must not contain word-ending characters")

            let plan = state.plan()
            let continuation = state.continuation

            // Screen before the user's Delete, and after it:
            let screenBeforeDelete = converted.count + continuation.count
            let screenAfterDelete = screenBeforeDelete - 1
            let screenAfterUndo = screenAfterDelete - plan.eraseCount + plan.insertText.count

            // The expected result depends on whether the user typed anything after we fired,
            // because the Delete removed a different character in each case:
            //   - continuation non-empty: the Delete removed the last character the USER
            //     typed, so undo restores the typed word minus that one character.
            //   - continuation empty: the Delete removed a character WE inserted, so undo
            //     restores the full typed word. This is the "immediately rejected" case.
            let expected = original.count + max(0, continuation.count - 1)

            #expect(screenAfterDelete >= 0, "\(converted): nothing left to erase")
            #expect(screenAfterUndo == expected,
                    "\(converted) + \(String(continuation)): expected \(expected) got \(screenAfterUndo)")
        }
    }

    /// The case that catches the algebra when the user rejects instantly, having typed
    /// nothing after the conversion. Delete then removes one of OUR characters, so undo has
    /// to insert one more character than it erases.
    @Test("rejecting immediately restores the full word")
    func rejectWithoutTypingAnythingAfterwards() {
        var state = UndoState(originalText: "пут", convertedText: "gen", originalLanguage: .russian)
        // "пут" -> "gen" fires; the user immediately hits Delete. Screen: "gen" -> "ge".
        let plan = state.plan()

        #expect(plan.eraseCount == 2, "'gen' is 3 characters; Delete already removed the 'n'")
        #expect(plan.insertText == "пут", "all three characters come back, including the deleted one")
        // 2 erased, 3 inserted: the word is one longer than what was on screen, and that is
        // correct - the user wants the word their fingers produced.
    }

    @Test("the continuation is inserted verbatim, in the layout the user was typing in")
    func continuationKeepsTheLayoutTheUserChose() {
        var state = UndoState(originalText: "прив", convertedText: "ghbd", originalLanguage: .russian)
        // After firing, the user is typing in English, so "e" here is Latin.
        state.consume("e")
        state.consume("t")

        let plan = state.plan()
        // The Latin "e" is preserved as Latin: undo does not re-decode what the user typed
        // after the conversion. Only the first block, which we replaced, gets put back in
        // the original layout. Mixing alphabets is not a bug here - the user's keyboard is
        // in English and Latin letters are what they mean to have there.
        let expected = "прив" + String(UnicodeScalar(0x65)!)  // "привe": Cyrillic прив + Latin e
        #expect(plan.insertText == expected,
                "got \(plan.insertText.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        #expect(plan.eraseCount == 5, "'ghbd' is 4, continuation 'et' is 2, Delete removed 1")
    }

    @Test("word-ending characters are not folded into the continuation")
    func wordEndingsAreNotPartOfTheWord() throws {
        var state = UndoState(originalText: "прив", convertedText: "ghbd", originalLanguage: .russian)
        // `consume` is mutating, so it must be called outside #expect: the macro captures the
        // expression as an immutable closure parameter.
        let letterEnded = state.consume("е")
        let spaceEnded = state.consume(" ")

        #expect(!letterEnded, "a letter is not a word end")
        #expect(spaceEnded, "a space ends the word")
        #expect(state.continuation == "е", "the space must not end up inside the restored word")
    }

    @Test("word-ending punctuation is recognised across kinds")
    func recognisesWordEnders() {
        for c: Character in [" ", "\n", "\t", ".", ",", "!", "?", ";", ":", "-"] {
            #expect(UndoState.endsWord(c), "\(c) should end a word")
        }
        for c: Character in ["a", "б", "1", "z", "я"] {
            #expect(!UndoState.endsWord(c), "\(c) should not end a word")
        }
    }

    @Test("suspend blocks a second undo for the rest of the word")
    func suspendIsSticky() {
        var state = UndoState(originalText: "пут", convertedText: "gen", originalLanguage: .russian)
        #expect(!state.correctionSuspended)
        state.suspend()
        #expect(state.correctionSuspended, "after an undo the user finishes the word without interference")
    }

    @Test("the layout to restore is the one that was active, not the converted one")
    func restoresOriginalLayout() {
        let ru = UndoState(originalText: "пут", convertedText: "gen", originalLanguage: .russian)
        #expect(ru.plan().switchTo == .russian)

        // Typed in English, meant Russian: undo must go back to English.
        let en = UndoState(originalText: "gen", convertedText: "пут", originalLanguage: .english)
        #expect(en.plan().switchTo == .english)
        #expect(en.plan().insertText == "gen")
    }
}