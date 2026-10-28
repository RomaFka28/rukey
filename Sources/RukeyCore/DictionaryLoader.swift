import Foundation

public final class DictionaryLoader: Sendable {
    public static let shared = DictionaryLoader()

    public init() {}

    public enum LoadError: Error {
        case resourceNotFound(String)
        case unreadable(URL, Error?)
    }

    /// Loads a Trie from a resource text file containing newline-delimited words.
    /// The throwing variant reports misses through `LogBuffer`; the silent
    /// variant below returns an empty trie and is what production callers use.
    public func loadTrieThrowing(fromResource name: String, withExtension ext: String = "txt") throws -> Trie {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw LoadError.resourceNotFound("\(name).\(ext)")
        }
        let trie = Trie()
        try loadWordsThrowing(from: url, into: trie)
        return trie
    }

    /// Loads a Trie from a resource text file; returns an empty Trie when missing,
    /// logging the miss so startup failures are visible.
    public func loadTrie(fromResource name: String, withExtension ext: String = "txt") -> Trie {
        do {
            return try loadTrieThrowing(fromResource: name, withExtension: ext)
        } catch {
            LogBuffer.shared.log(
                "[Rukey] Dictionary '\(name).\(ext)' not found, using empty trie (\(error))",
                level: .warn)
            return Trie()
        }
    }

    private func loadWordsThrowing(from url: URL, into trie: Trie) throws {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LoadError.unreadable(url, error)
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
}
