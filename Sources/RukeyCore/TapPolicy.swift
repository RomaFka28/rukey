import CoreGraphics

/// Pure decisions for the global event tap.
///
/// The tap callback itself is not reachable from a unit test, so the three
/// decisions it makes live here as values; `EventTapManager` keeps only the
/// wiring and the Cocoa-free logic stays testable.
public enum TapPolicy {
  /// Events the tap needs to see: typing and Option handling, plus the two
  /// mouse clicks that act as the same "the user moved on" boundary as
  /// Escape/Enter.
  public static let eventMask =
    CGEventMask(1 << CGEventType.keyDown.rawValue)
    | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)

  /// A click puts the caret somewhere unpredictable, so a pending undo would
  /// restore text in the wrong place. Clicks must disarm it.
  public static func isUndoResettingEvent(_ type: CGEventType) -> Bool {
    type == .leftMouseDown || type == .rightMouseDown
  }

  /// An Option tap normally toggles the layout, but while Secure Input is
  /// active (a password field) switching layouts would misroute the password.
  /// Refuse the toggle there.
  public static func shouldToggleLayoutOnOptionTap(isSecureInputActive: Bool) -> Bool {
    !isSecureInputActive
  }
}
