import Foundation

/// Words the user taught the daemon, persisted in `custom.json`.
///
/// This is the widening half of the pair with `WordFilter`: a taught word is one
/// the daemon must accept as real even though neither shipped trie knows it, so
/// the detector treats it exactly as it treats a dictionary word. Two questions
/// are asked of it, and they are deliberately different:
/// - `contains` is exact membership, used by the boundary (whole-word) path, where
///   the buffer really is a finished word.
/// - `isPrefixOfKnown` is prefix membership, used by the on-the-fly path, where
///   the detector is asked whether `pfj` is the *start* of a taught word rather
///   than whether it is one.
///
/// Membership is a membership question about the taught word only. Teaching
/// `заозкздзаоз` never teaches `pfjprplpfjp`: the Latin spelling is not derived,
/// stored, or implied, so a taught word can never licence flipping itself into
/// Latin.
///
/// `init` is the only reader. Everything after it is in-memory, so a setting
/// changed by the GUI takes effect on the next keystroke without rebuilding the
/// tries and without re-parsing the file.
public final class CustomDictionary: @unchecked Sendable {
    // `@unchecked Sendable` is sound because `lock` guards every access to both
    // stored properties, the pair is only ever swapped together, and the
    // published trie is never mutated afterwards. A reader therefore cannot
    // observe a trie that disagrees with its backing word set, and the per-query
    // lookups below — which take `Trie`'s own lock, so they must run outside this
    // one — only ever see a fully built, immutable index.
    private let lock = NSLock()
    /// Where the words live on disk. Immutable: swapping the taught words must not
    /// move the file a running daemon is writing to.
    private let fileURL: URL
    private let logBuffer: LogBuffer
    /// The trimmed, non-blank taught words: the source of truth for `words`.
    /// `Trie` has no enumeration API, so the set is kept alongside its index.
    private var normalisedWords: Set<String>
    /// Prefix index over `normalisedWords`, answering both queries in O(len) —
    /// no scan over the word list on the per-keystroke path.
    private var current: Trie

    /// `~/.config/rukey/custom.json`. Production call sites use this; tests pass
    /// a private temporary URL instead, so no test reads or writes the real config
    /// directory.
    public static let defaultFileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rukey/custom.json")

    /// On-disk shape. `words` is optional so a file written by an older build
    /// still decodes.
    private struct FileShape: Codable {
        var words: [String]?
    }

    /// Loads `custom.json` and adds it to `words`, which is what a caller already
    /// holds in memory. A missing file starts empty and silent — a fresh install
    /// has nothing to teach yet — while a corrupt one logs a `.warn` and starts
    /// empty, because silently ignoring a hand-edited file is exactly what the
    /// log pane exists to prevent.
    public init(
        fileURL: URL = CustomDictionary.defaultFileURL,
        words: Set<String> = [],
        logBuffer: LogBuffer = .shared
    ) {
        self.fileURL = fileURL
        self.logBuffer = logBuffer
        let normalised = Self.normalise(words).union(Self.read(from: fileURL, into: logBuffer))
        self.normalisedWords = normalised
        self.current = Trie()
        self.current.insert(contentsOf: normalised)
    }

    /// The current taught words, trimmed of whitespace and free of blanks.
    public var words: Set<String> {
        lock.withLock { normalisedWords }
    }

    /// Replaces the whole taught set and persists it. Readers never see a
    /// partially built trie.
    public func replaceAll(with words: Set<String>) {
        let normalised = Self.normalise(words)
        let replacement = Trie()
        replacement.insert(contentsOf: normalised)
        // Sorted, so a save that changes nothing writes nothing different back and
        // the file does not churn under version control or a file watcher.
        let payload = FileShape(words: normalised.sorted())
        lock.withLock {
            normalisedWords = normalised
            current = replacement
            persist(payload)
        }
    }

    /// True when the whole word was taught. Case-insensitive.
    public func contains(_ word: String) -> Bool {
        lock.withLock { current }.contains(word)
    }

    /// True when the word starts a taught word — every shorter run of it too.
    /// Case-insensitive; the empty candidate is never a prefix.
    public func isPrefixOfKnown(_ candidate: String) -> Bool {
        lock.withLock { current }.hasPrefix(candidate)
    }

    /// Writes the taught words. Called under `lock` so two concurrent saves
    /// cannot interleave. A failed write is reported rather than swallowed: words
    /// that silently do not survive a restart are worse than words the user knows
    /// are missing.
    private func persist(_ payload: FileShape) {
        do {
            try JSONPersistence.write(payload, to: fileURL)
        } catch {
            logBuffer.log(
                "Could not save taught words to \(fileURL.path): "
                    + "\(error.localizedDescription)",
                level: .warn
            )
        }
    }

    /// The only reader of `custom.json`. Runs before `self` is usable, so it is a
    /// static taking its collaborators as parameters.
    private static func read(from url: URL, into logBuffer: LogBuffer) -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let shape = try JSONPersistence.read(FileShape.self, from: url)
            return normalise(Set(shape.words ?? []))
        } catch {
            logBuffer.log(
                "Could not read taught words from \(url.path): "
                    + "\(error.localizedDescription). Starting with none.",
                level: .warn
            )
            return []
        }
    }

    /// Trims surrounding whitespace and drops blanks, which would otherwise teach
    /// nothing while inflating the word list (and its memory).
    private static func normalise(_ words: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result.insert(trimmed)
        }
        return result
    }
}
