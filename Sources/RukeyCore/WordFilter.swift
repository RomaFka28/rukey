import Foundation

/// User-supplied list of words that must never be converted.
///
/// Two questions are asked of the filter, and they are deliberately different:
/// - `isPrefixOfExcluded` blocks the on-the-fly (mid-word) flip *and* the bare
///   whole-word (boundary) run path, so an excluded word is inert from its very
///   first keystroke instead of being corrected and then re-typed in the source
///   layout. It also gates the punctuation-wrapped token path, so the three
///   detector paths cannot disagree about the same typing.
/// - `isExcluded` is the exact-membership query, for callers that already hold a
///   complete word (tests, a settings check). The detector does not gate on it:
///   an exact test is precisely what let an excluded word's *prefix* convert once,
///   so every decision path uses `isPrefixOfExcluded` instead.
///
/// Membership is checked against the *typed* word, never the conversion result:
/// excluding `привет` leaves the Latin typing `ghbdtn` convertible, and excluding
/// `ghbdtn` leaves the already-Russian word alone.
///
/// Swaps are whole-set: `replaceAll(with:)` builds a fresh Trie off to the side
/// and publishes it together with its backing word set, so a reader either sees
/// the whole old list or the whole new one.
public final class WordFilter: @unchecked Sendable {
    // `@unchecked Sendable` is sound because `lock` guards every access to both
    // stored properties, and the pair is only ever swapped together, so no
    // reader can observe a trie that disagrees with `normalisedWords`. The
    // published trie is never mutated afterwards (a replacement gets a new one),
    // which also makes the per-query lookups below safe outside the lock.
    private let lock = NSLock()
    /// The trimmed, non-blank word set: the source of truth for `words`/`isEmpty`.
    /// `Trie` has no enumeration API, so the set is kept alongside its index.
    private var normalisedWords: Set<String>
    /// Prefix index over `normalisedWords`, answering both filter queries in O(len).
    private var current: Trie

    public init(words: Set<String> = []) {
        let normalised = Self.normalise(words)
        self.normalisedWords = normalised
        self.current = Trie()
        self.current.insert(contentsOf: normalised)
    }

    /// The current exclusion set, trimmed of whitespace and free of blanks.
    public var words: Set<String> {
        lock.withLock { normalisedWords }
    }

    public var isEmpty: Bool {
        lock.withLock { normalisedWords.isEmpty }
    }

    /// Replaces the whole exclusion set. Readers never see a partially built trie.
    public func replaceAll(with words: Set<String>) {
        let normalised = Self.normalise(words)
        let replacement = Trie()
        replacement.insert(contentsOf: normalised)
        lock.withLock {
            normalisedWords = normalised
            current = replacement
        }
    }

    /// True when the whole word is excluded. Case-insensitive.
    public func isExcluded(_ word: String) -> Bool {
        lock.withLock { current }.contains(word)
    }

    /// True when the word starts an excluded word — every shorter run of it too.
    /// Case-insensitive; the empty candidate is never a prefix.
    public func isPrefixOfExcluded(_ candidate: String) -> Bool {
        lock.withLock { current }.hasPrefix(candidate)
    }

    /// Trims surrounding whitespace and drops blanks, which would otherwise
    /// exclude nothing while inflating the word list (and its memory).
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
