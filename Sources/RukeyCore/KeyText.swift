import CoreGraphics

/// Which keystrokes the live tap forwards to the engine.
///
/// This lives in `RukeyCore` rather than in the tap on purpose. The rule below was the
/// single cause of the first live test failing: whitespace was filtered out before it
/// reached the engine, so no word ever ended, the buffer grew for the whole session, and
/// the program did nothing while looking like it was working. It was untested because it
/// sat in glue code that no test could reach. Pure, tested, and shared is the fix.
///
/// A keystroke is forwarded when it is something the user typed into a text field:
///
/// - letters, digits, punctuation and symbols can be part of a word;
/// - whitespace is NOT optional - the space, Return and Tab are how the engine learns a
///   word ended, which clears the buffer, releases the correction lock and re-arms undo.
///   Dropping them leaves the engine mid-word forever.
///
/// Everything else is rejected: control characters, and the private-use range some
/// applications send for function keys. Those are never word content.
public enum KeyText {

    /// True when this character should be handed to the engine.
    ///
    /// Note this decides only whether the engine *learns about* the keystroke. The
    /// character is still delivered to the foreground application by the system; the tap
    /// never swallows input.
    public static func isForwardable(_ character: Character) -> Bool {
        // Control characters, except the three that mean "the word ended".
        if character.unicodeScalars.contains(where: { $0.value < 0x20 })
            && character != "\n" && character != "\r" && character != "\t" {
            return false
        }
        // C1 controls and DEL.
        if character.unicodeScalars.contains(where: { $0.value == 0x7F }) {
            return false
        }
        return character.isLetter
            || character.isNumber
            || character.isPunctuation
            || character.isSymbol
            || character.isWhitespace
            || character.isNewline
    }

    /// Key codes that mean a word ended, used when the event carries no Unicode string.
    ///
    /// Keyed by hardware key code. These are layout-independent - the space bar produces a
    /// space on every layout we support - so the mapping is safe to hardcode here.
    public static let wordEndingKeyCodes: [CGKeyCode: Character] = [
        49: " ",   // space
        36: "\r",  // return
        48: "\t",  // tab
    ]
}
