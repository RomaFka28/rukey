import CoreGraphics
import Foundation

/// The keyboard state machine: buffers the current word, decides when to correct it, and
/// remembers enough to undo.
///
/// Kept separate from the event tap so the decision order is readable in one place and can
/// be tested without a tap. The tap's only job is to hand it characters and honour
/// `isBusy`.
public struct KeyboardEngine {

    public private(set) var detector: Detector
    public private(set) var switcher: InputSourceSwitcher

    /// Characters of the word being typed, as they appear on screen.
    public private(set) var buffer = ""

    /// Set after a correction, until the word ends. Suppresses further corrections so a
    /// half-corrected word can never be corrected again mid-word.
    public private(set) var wordIsRewritten = false

    /// Non-nil while an undo is possible. Cleared when the word ends.
    public private(set) var undo: UndoState?

    /// True while we are generating events. The tap must ignore everything while this is set:
    /// our own backspaces and inserts come back through the tap and would be read as the
    /// user typing.
    public var isBusy = false

    /// Records the conversion we just performed, so Delete can take it back.
    public private(set) var lastLayoutBeforeSwitch: Language?

    public init(detector: Detector, switcher: InputSourceSwitcher) {
        self.detector = detector
        self.switcher = switcher
    }

    /// What the engine decided to do about one keystroke.
    public enum Action: Equatable {
        /// Nothing to do.
        case none

        /// Erase, insert, switch layout.
        case correct(original: String, replacement: String, to: Language)

        /// Take back the last correction.
        case undo(eraseCount: Int, insertText: String, to: Language)
    }

    /// Feed one typed character. Pure: returns the action, changes nothing about the world.
    public mutating func type(_ character: Character, layout: Language) -> Action {
        defer { lastLayoutBeforeSwitch = layout }

        // Delete first, before the character can end the word and clear the undo state.
        if character == "\u{8}" || character == "\u{7F}" {
            return handleDelete(layout: layout)
        }

        // A correction is pending: fold this character into it.
        if undo != nil {
            let wordEnded = undo!.consume(character)
            if wordEnded { finishWord() }
            return .none
        }

        // The word was already corrected - stay quiet until it ends, or the tail of the
        // word gets typed in a different layout than its head.
        if wordIsRewritten {
            if Self.endsWord(character) { finishWord() }
            return .none
        }

        if Self.endsWord(character) {
            finishWord()
            return .none
        }

        // Longer than we are willing to rewrite: give up on this word rather than track it.
        guard buffer.count < detector.maximumRewritableLength else {
            finishWord()
            return .none
        }

        buffer.append(character)

        switch detector.intent(for: buffer, current: layout) {
        case .correct:
            // A word in the layout the user is typing in. It is settled: keep waiting for
            // the next character as a fresh candidate rather than growing the buffer over
            // the whole word. Leaving "мир" in the buffer would let the next letter be
            // tested as "мира", and eventually a long enough prefix of a legitimate word
            // could be re-decoded into the other language and fire a false correction.
            buffer = ""
            return .none

        case .undecided:
            return .none

        case .convert(let target, let text):
            let original = buffer
            buffer = ""
            wordIsRewritten = true
            undo = UndoState(originalText: original, convertedText: text, originalLanguage: layout)
            return .correct(original: original, replacement: text, to: target)
        }
    }

    /// Delete: undo the last correction, or fall through to ordinary backspacing.
    private mutating func handleDelete(layout: Language) -> Action {
        // A suspended undo means we already undid once for this word. This Delete is the
        // user's own backspace, and letting it through as a second undo would rewrite the
        // text again while they are simply erasing characters.
        guard var state = undo, !state.correctionSuspended else {
            if !buffer.isEmpty { buffer.removeLast() }
            return .none
        }

        let plan = state.plan()
        // Keep the state around so the word stays "already rewritten" for the rest of its
        // life, but mark it consumed so no further Delete can trigger another rewrite.
        state.suspend()
        undo = state
        wordIsRewritten = true
        return .undo(eraseCount: plan.eraseCount, insertText: plan.insertText, to: plan.switchTo)
    }

    /// End of word: drop all state.
    public mutating func finishWord() {
        buffer = ""
        wordIsRewritten = false
        undo = nil
    }

    static func endsWord(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }
}