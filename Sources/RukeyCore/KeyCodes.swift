import Foundation

/// Keycode and event constants for macOS keyboard handling.
/// Centralizes magic numbers previously scattered across `EventTapManager` / `FixEngine`.
public enum KeyCode {
    public static let backspace: Int64 = 51
    public static let enter: Int64 = 36
    public static let tab: Int64 = 48
    public static let space: Int64 = 49
    public static let escape: Int64 = 53
    public static let leftOption: Int64 = 58
    public static let rightOption: Int64 = 61
    public static let arrows: Set<Int64> = [123, 124, 125, 126]

    /// Keys that end the current word (space, enter, tab, escape, arrows).
    public static let wordBoundaries: Set<Int64> = [36, 48, 49, 53, 123, 124, 125, 126]
}

/// Minimal logger to replace scattered `print` calls in the hot keystroke path.
/// `isVerbose` gates debug output; warnings/errors always print.
public struct RukeyLogger: Sendable {
    public var isVerbose: Bool

    public init(isVerbose: Bool = false) {
        self.isVerbose = isVerbose
    }

    public func debug(_ message: @autoclosure () -> String) {
        if isVerbose { print(message()) }
    }

    public func info(_ message: @autoclosure () -> String) {
        print(message())
    }
}
