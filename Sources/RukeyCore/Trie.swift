import Foundation

/// Fast Prefix Tree (Trie) for dictionary prefix checks and full word lookups.
///
/// Keys are lowercased `Unicode.Scalar` values (not `Character`): scalar hashing
/// is cheaper, avoids grapheme-cluster normalization surprises, and matches the
/// lowercase-then-compare contract of `hasPrefix` / `contains`.
public final class Trie: @unchecked Sendable {
    private final class Node {
        var isEndOfWord: Bool = false
        var children: [Unicode.Scalar: Node] = [:]
    }

    private let root: Node = Node()
    private(set) public var wordCount: Int = 0
    private let lock = NSLock()

    public init() {}

    /// Inserts a word into the Trie (converts to lowercase).
    public func insert(_ word: String) {
        guard !word.isEmpty else { return }
        lock.withLock {
            var current = root
            for scalar in word.lowercased().unicodeScalars {
                if let next = current.children[scalar] {
                    current = next
                } else {
                    let next = Node()
                    current.children[scalar] = next
                    current = next
                }
            }
            if !current.isEndOfWord {
                current.isEndOfWord = true
                wordCount += 1
            }
        }
    }

    /// Bulk insert without re-locking per word.
    public func insert(contentsOf words: some Sequence<String>) {
        lock.withLock {
            for word in words where !word.isEmpty {
                var current = root
                for scalar in word.lowercased().unicodeScalars {
                    if let next = current.children[scalar] {
                        current = next
                    } else {
                        let next = Node()
                        current.children[scalar] = next
                        current = next
                    }
                }
                if !current.isEndOfWord {
                    current.isEndOfWord = true
                    wordCount += 1
                }
            }
        }
    }

    private func node(for key: String) -> Node? {
        var current = root
        for scalar in key.lowercased().unicodeScalars {
            guard let next = current.children[scalar] else { return nil }
            current = next
        }
        return current
    }

    /// Counts dictionary words under a prefix, stopping early at `limit`.
    /// Used to ignore conversions into ultra-rare prefixes backed by a single
    /// junk entry (e.g. EN `ghu` exists only via `ghul`).
    public func countCompletions(of prefix: String, limit: Int) -> Int {
        guard !prefix.isEmpty, limit > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard let start = node(for: prefix) else { return 0 }
        var count = 0
        var stack = [start]
        while let node = stack.popLast() {
            if node.isEndOfWord {
                count += 1
                if count >= limit { return count }
            }
            stack.append(contentsOf: node.children.values)
        }
        return count
    }

    /// Checks if any word in the Trie starts with the given prefix.
    public func hasPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return node(for: prefix) != nil
    }

    /// Checks if the exact word exists in the Trie.
    public func contains(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return node(for: word)?.isEndOfWord == true
    }
}
