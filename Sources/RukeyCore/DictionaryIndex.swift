// Word-list lookup. The dictionary is loaded once at startup and never mutated.
//
// Storage is a sorted flat array of words plus a parallel index of offsets, so membership
// is a binary search with no per-word allocation and no hash table to corrupt.

import Foundation

public struct DictionaryIndex: Sendable {
    private let storage: [UInt8]
    private let offsets: [Int]
    private let count: Int

    /// Builds an index from words. Entries are normalized (lower-cased, yo folded) and
    /// deduplicated; the result is sorted by UTF-8 bytes, which for the supported scripts
    /// matches Unicode scalar order.
    public init(words: some Sequence<String>) {
        var seen: Set<String> = []
        var sorted: [String] = []
        for w in words {
            let n = Normalization.foldYo(w.lowercased())
            guard !n.isEmpty, seen.insert(n).inserted else { continue }
            sorted.append(n)
        }
        sorted.sort { Self.compareUTF8($0, $1) < 0 }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(sorted.reduce(0) { $0 + $1.utf8.count + 4 })
        var starts: [Int] = []
        starts.reserveCapacity(sorted.count)
        for w in sorted {
            starts.append(bytes.count)
            bytes.append(contentsOf: Array(w.utf8))
        }
        // Sentinel so the last word has an end offset without a special case in search.
        starts.append(bytes.count)

        self.storage = bytes
        self.offsets = starts
        self.count = sorted.count
    }

    public var wordCount: Int { count }

    public func contains(_ word: String) -> Bool {
        let target = Normalization.foldYo(word.lowercased())
        return !target.isEmpty && search(target)
    }

    /// Is `prefix` a proper prefix of at least one word in this list?
    ///
    /// This is what lets the detector fire mid-word: the re-decoded "hell" is not a
    /// dictionary word, but it is the start of "hello", which is enough evidence that the
    /// user is halfway through typing an English word on a Russian keyboard.
    ///
    /// All words sharing a prefix occupy one contiguous run in the sorted list, ordered
    /// shortest-first. So the lower bound of `prefix` lands either on the prefix itself
    /// (if it is also a word) or on the shortest longer word starting with it. Either way
    /// the answer is one or two steps away, never a scan.
    public func containsPrefix(_ prefix: String) -> Bool {
        let needle = Array(Normalization.foldYo(prefix.lowercased()).utf8)
        guard !needle.isEmpty else { return false }

        let start = lowerBound(needle)
        var i = start
        // The run cannot be long in practice, but stop at the first word that does not
        // share the prefix so a pathological list cannot turn this into a full scan.
        while i < count {
            let word = bytes(start: offsets[i], end: offsets[i + 1])
            guard word.count >= needle.count, startsWith(word, needle) else { return false }
            // A proper prefix: strictly longer than what we were asked about.
            if word.count > needle.count { return true }
            i += 1
        }
        return false
    }

    /// First index whose word is >= needle in UTF-8 byte order.
    private func lowerBound(_ needle: [UInt8]) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if Self.compare(bytes(start: offsets[mid], end: offsets[mid + 1]), needle) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func startsWith(_ word: [UInt8], _ needle: [UInt8]) -> Bool {
        guard word.count >= needle.count else { return false }
        for i in needle.indices where word[i] != needle[i] { return false }
        return true
    }

    private func bytes(start: Int, end: Int) -> [UInt8] {
        Array(storage[start..<end])
    }

    private func search(_ target: String) -> Bool {
        let needle = Array(target.utf8)
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let start = offsets[mid]
            let end = offsets[mid + 1]
            let slice = storage[start..<end]
            let order = Self.compare(needle, Array(slice))
            if order == 0 { return true }
            if order < 0 { high = mid - 1 } else { low = mid + 1 }
        }
        return false
    }

    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    private static func compareUTF8(_ a: String, _ b: String) -> Int {
        compare(Array(a.utf8), Array(b.utf8))
    }

    /// Iterates every word. Used by the build tools and by the FP harness.
    public func allWords() -> [String] {
        (0..<count).map { i in
            String(decoding: storage[offsets[i]..<offsets[i + 1]], as: UTF8.self)
        }
    }
}