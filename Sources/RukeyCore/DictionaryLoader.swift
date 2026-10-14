import Foundation

public final class DictionaryLoader: Sendable {
    public static let shared = DictionaryLoader()

    public init() {}

    public enum LoadError: Error {
        case resourceNotFound(String)
        case unreadable(URL, Error?)
    }

    /// Loads a Trie from a resource text file containing newline-delimited words.
    /// Throwing variant — prefer it over the silent fail-open version below.
    public func loadTrieThrowing(fromResource name: String, withExtension ext: String = "txt") throws -> Trie {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw LoadError.resourceNotFound("\(name).\(ext)")
        }
        let trie = Trie()
        try loadWordsThrowing(from: url, into: trie)
        return trie
    }

    /// Loads a Trie from a resource text file; returns an empty Trie when missing.
    /// Kept for backward compatibility — logs the miss so startup failures are visible.
    public func loadTrie(fromResource name: String, withExtension ext: String = "txt") -> Trie {
        do {
            return try loadTrieThrowing(fromResource: name, withExtension: ext)
        } catch {
            print("[Rukey] Dictionary '\(name).\(ext)' not found, using empty trie (\(error))")
            return Trie()
        }
    }

    public func loadWordsThrowing(from url: URL, into trie: Trie) throws {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LoadError.unreadable(url, error)
        }
        loadWords(content: content, into: trie)
    }

    /// Loads words from a local file URL into the specified Trie.
    public func loadWords(from url: URL, into trie: Trie) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        loadWords(content: content, into: trie)
    }

    private func loadWords(content: String, into trie: Trie) {
        // Single pass, no per-line `trimmingCharacters` allocation storm:
        // split on newlines, filter empties. `insert(contentsOf:)` locks once.
        let words = content.split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        trie.insert(contentsOf: words)
    }

    /// Loads a Trie directly from an array of strings.
    public func loadTrie(from words: [String]) -> Trie {
        let trie = Trie()
        for word in words {
            trie.insert(word)
        }
        return trie
    }
}
