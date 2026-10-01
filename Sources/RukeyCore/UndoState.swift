import Foundation

/// Everything needed to take back one conversion, and the arithmetic for it.
///
/// Why this is a value type with no I/O: the delete-count and insert-text must be
/// computable and testable without an event tap, because the tap part cannot be verified
/// with synthetic events in the same process. If this arithmetic is wrong, undo quietly
/// corrupts the word instead of restoring it.
///
/// The lifecycle of one conversion:
///
///     typed:      "рудд"          (physically h, e, l, l on a Russian layout)
///     fired:      erase 4, insert "hell", switch to English
///     continued:  "hello"         (user types "o" in English now)
///     user hits Delete -> screen shows "hell"
///     undo:       erase 4, insert "рудд", switch back to Russian
///
/// The arithmetic is deliberately written in terms of what is on screen now and what the
/// user intended, not in terms of "one character back". See `plan` for the derivation.
public struct UndoState: Equatable, Sendable {

    /// What the user physically typed before we touched anything. This is what undo
    /// restores, because it is what their fingers did.
    public let originalText: String

    /// What we put on screen instead.
    public let convertedText: String

    /// The layout that was active when we fired, so undo switches back to it.
    public let originalLanguage: Language

    /// Everything the user has typed since we fired. Undo has to preserve all but the last
    /// character, because that last one is the one the user's Delete already removed.
    public private(set) var continuation: String = ""

    /// False once the word is over. A word ends at a space, Return, or punctuation - and
    /// after undo, automatic correction stays off for the rest of that word, so the user
    /// can finish typing "hello" on their keyboard without us interfering again.
    public private(set) var correctionSuspended = false

    public init(
        originalText: String,
        convertedText: String,
        originalLanguage: Language
    ) {
        self.originalText = originalText
        self.convertedText = convertedText
        self.originalLanguage = originalLanguage
    }

    // MARK: - Word lifecycle

    /// True when the character ends the current word and therefore resets undo.
    public static func endsWord(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }

    /// Fold a typed character into the continuation, or return true if it ended the word
    /// and this undo state is finished with.
    ///
    /// Word-ending characters are deliberately not folded in: after "hello" + space, undo
    /// must not try to put a space back inside the restored word.
    @discardableResult
    public mutating func consume(_ character: Character) -> Bool {
        if Self.endsWord(character) {
            return true
        }
        continuation.append(character)
        return false
    }

    /// Turn undo off for the remainder of the current word, without discarding the state.
    /// Used right after an undo fires so a second Delete does not undo again.
    public mutating func suspend() {
        correctionSuspended = true
    }

    // MARK: - The arithmetic

    /// The edit that turns the current screen back into what the user meant.
    ///
    /// Derivation. Before the user's Delete the screen held `convertedText + continuation`
    /// with the cursor at the end. The Delete removed exactly one character, so the screen
    /// now holds the first `count(convertedText) + count(continuation) - 1` characters of
    /// that. The intended result is `originalText + continuation` minus the same final
    /// character, i.e. `originalText + continuation.dropLast()`.
    ///
    /// Rather than counting the deletion and inserting at the cursor - which would leave
    /// the block we replaced still in front of the insertion point - erase the whole block
    /// and reinsert the intended text. That keeps the invariant that what remains to the
    /// right of the cursor is exactly what the user typed after we fired.
    public func plan() -> (eraseCount: Int, insertText: String, switchTo: Language) {
        (
            eraseCount: convertedText.count + continuation.count - 1,
            insertText: originalText + continuation.dropLast(),
            switchTo: originalLanguage
        )
    }
}