import Foundation

/// Undo counts per typed word, persisted in `learned.json`.
///
/// Each key is the spelling the user typed (`ghb`), and the count is how many
/// times that correction has been taken back. The store only counts: the
/// threshold that turns a count into an exclusion rule lives in the caller
/// (`UndoLearningController`), so this type stays free of the settings it would
/// otherwise have to be rebuilt to change.
///
/// `registerUndo` is the writer that grows the table; `removeAll` and
/// `removeAllKeys(for:)` only shrink it. Every mutation persists immediately —
/// a restart must not resurrect a count the user cleared, or the word could
/// never be learned again.
public final class StrikeStore: @unchecked Sendable {
    // `@unchecked Sendable` is sound because `lock` guards every access to the
    // strike table, so the only mutable state is reachable solely inside
    // `lock.withLock`.
    private let lock = NSLock()
    /// Where the counts live on disk. Immutable: swapping the counts must not
    /// move the file a running daemon is writing to.
    public let fileURL: URL
    private let logBuffer: LogBuffer
    /// The recorded undos by typed word.
    private var strikesByKey: [String: Int]

    /// `~/.config/rukey/learned.json`. Production call sites use this; tests pass
    /// a private temporary URL instead, so no test reads or writes the real config
    /// directory.
    public static let defaultFileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rukey/learned.json")

    /// On-disk shape: `{"strikes": {"ghb": 2}}`.
    private struct FileShape: Codable {
        var strikes: [String: Int]
    }

    /// Loads `learned.json` under the lock. A missing file starts empty and
    /// silent — a fresh install has no strikes yet — while a corrupt one logs a
    /// `.warn` and starts empty, because silently ignoring a damaged file is
    /// exactly what the log pane exists to prevent.
    public init(fileURL: URL = StrikeStore.defaultFileURL, logBuffer: LogBuffer = .shared) {
        self.fileURL = fileURL
        self.logBuffer = logBuffer
        self.strikesByKey = [:]
        lock.withLock {
            strikesByKey = Self.read(from: fileURL, into: logBuffer)
        }
    }

    /// The recorded number of undos for a word, zero when it has none.
    public func strikes(for key: String) -> Int {
        lock.withLock { strikesByKey[key] ?? 0 }
    }

    /// Records one undo for `key`, persists the new count, and returns it.
    @discardableResult
    public func registerUndo(key: String) -> Int {
        lock.withLock {
            let count = (strikesByKey[key] ?? 0) + 1
            strikesByKey[key] = count
            persist()
            return count
        }
    }

    /// Clears every count and persists the empty table.
    public func removeAll() {
        lock.withLock {
            strikesByKey.removeAll()
            persist()
        }
    }

    /// Clears every key starting with `prefix` and persists the result.
    public func removeAllKeys(for prefix: String) {
        lock.withLock {
            strikesByKey = strikesByKey.filter { !$0.key.hasPrefix(prefix) }
            persist()
        }
    }

    /// Writes the counts. Called under `lock` so two concurrent saves cannot
    /// interleave. A failed write is reported rather than swallowed: counts that
    /// silently do not survive a restart are worse than counts the user knows are
    /// missing.
    private func persist() {
        do {
            // `~/.config/rukey` does not exist on a fresh install.
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(FileShape(strikes: strikesByKey)).write(
                to: fileURL, options: .atomic)
        } catch {
            logBuffer.log(
                "Could not save undo counts to \(fileURL.path): "
                    + "\(error.localizedDescription)",
                level: .warn
            )
        }
    }

    /// The only reader of `learned.json`. Runs before `self` is usable, so it is a
    /// static taking its collaborators as parameters.
    private static func read(from url: URL, into logBuffer: LogBuffer) -> [String: Int] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode(FileShape.self, from: Data(contentsOf: url)).strikes
        } catch {
            logBuffer.log(
                "Could not read undo counts from \(url.path): "
                    + "\(error.localizedDescription). Starting with none.",
                level: .warn
            )
            return [:]
        }
    }
}
