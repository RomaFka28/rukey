import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Puts the corrected text on screen by erasing the wrong characters and inserting the
/// right ones.
///
/// Why `keyboardSetUnicodeString` and not synthesised key presses: a key press is decoded
/// through whatever layout is active at the moment the event is delivered. We erase the old
/// text and insert the new one in the same breath, and the layout switch that happens in
/// between would otherwise make the insert produce the wrong alphabet - or nothing at all,
/// which is the race that produces half-Russian-half-English words. A Unicode string is
/// inserted literally, so the result does not depend on layout timing.
///
/// Why erasing is a loop of backspaces rather than a text-range API: there is no public API
/// to replace the last N characters of the focused text field. Backspaces are the only
/// portable way, and they respect whatever the app's own undo stack thinks is happening
/// better than a synthetic "select all and retype".
public struct TextRewriter: Sendable {

    public init() {}

    /// macOS keycode for the forward-delete key (the one on the main block, labelled delete
    /// on a US keyboard and "backspace" in the arrow cluster).
    static let deleteKeyCode: CGKeyCode = 51

    /// Post `count` backspaces to the focused element.
    ///
    /// `before` and `after` bracket the whole operation. Anything they set is expected to
    /// gate re-entrancy: the events generated here come back through our own event tap, and
    /// reacting to them would start erasing the text we just inserted.
    public func erase(count: Int, postingTo post: CGEventTapLocation) {
        guard count > 0 else { return }
        for _ in 0..<count {
            Self.postKey(Self.deleteKeyCode, down: true, to: post)
            Self.postKey(Self.deleteKeyCode, down: false, to: post)
        }
    }

    /// Insert `text` literally, independent of the active layout.
    public func insert(_ text: String, postingTo post: CGEventTapLocation) {
        guard !text.isEmpty else { return }
        // A keyDown carrying a Unicode string, paired with a keyUp of the same virtual key.
        // The virtual key value is irrelevant: the target application reads the Unicode
        // string, not the key code. 0 is the conventional "no key" value.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }

        let utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        down.post(tap: post)
        up.post(tap: post)
    }

    /// Erase then insert, as one logical operation.
    ///
    /// Order matters and is not interchangeable: the erase must land before the insert, or
    /// the insert lands at the wrong offset.
    public func replace(eraseCount: Int, with text: String, postingTo post: CGEventTapLocation) {
        erase(count: eraseCount, postingTo: post)
        insert(text, postingTo: post)
    }

    static func postKey(_ keyCode: CGKeyCode, down: Bool, to post: CGEventTapLocation) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        event.post(tap: post)
    }
}