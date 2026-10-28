import Foundation

/// Keycode and event constants for macOS keyboard handling.
/// Centralizes magic numbers previously scattered across `EventTapManager` / `FixEngine`.
public enum KeyCode {
    public static let backspace: Int64 = 51
    public static let space: Int64 = 49
    public static let leftOption: Int64 = 58
    public static let rightOption: Int64 = 61

    /// Keys that end the current word (space, enter, tab, escape, arrows).
    public static let wordBoundaries: Set<Int64> = [36, 48, 49, 53, 123, 124, 125, 126]
}

/// Minimal logger to replace scattered `print` calls in the hot keystroke path.
///
/// Every line is appended to a `LogBuffer` — the daemon's `.shared` by default,
/// so the GUI's log pane can read what the console saw — and, while
/// `mirrorToStandardOutput` is true, also printed, which keeps `swift run rukey`
/// behaving as it always has. `isVerbose` gates debug output; `warn` and `error`
/// are buffered and mirrored unconditionally.
public struct RukeyLogger: Sendable {
    public var isVerbose: Bool
    /// When true, lines that pass their level gate are also written to standard
    /// output. Settable so the GUI can silence the console once it owns the UI.
    public var mirrorToStandardOutput: Bool
    private let logBuffer: LogBuffer

    public init(
        isVerbose: Bool = false,
        mirrorToStandardOutput: Bool = true,
        logBuffer: LogBuffer = .shared
    ) {
        self.isVerbose = isVerbose
        self.mirrorToStandardOutput = mirrorToStandardOutput
        self.logBuffer = logBuffer
    }

    public func debug(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        append(message(), level: .debug)
    }

    func info(_ message: @autoclosure () -> String) {
        append(message(), level: .info)
    }

    func warn(_ message: @autoclosure () -> String) {
        append(message(), level: .warn)
    }

    func error(_ message: @autoclosure () -> String) {
        append(message(), level: .error)
    }

    /// The single point where a line reaches both consumers, so the buffer and
    /// the console can never disagree about what was logged.
    private func append(_ message: String, level: LogLine.Level) {
        logBuffer.log(message, level: level)
        if mirrorToStandardOutput {
            print(message)
        }
    }
}
