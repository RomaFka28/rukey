import Foundation

public extension String {
    /// Authoritative number of Backspace presses needed to erase this string.
    ///
    /// `FixEngine.sendBackspace` erases per press while `insertUnicodeString`
    /// writes UTF-16 code units, so erase length must be `utf16.count` — not
    /// `count` (grapheme clusters), which undercounts emoji/ZWJ sequences.
    /// Identical to `count` for ASCII/BMP text.
    var utf16EraseLength: Int { utf16.count }
}
