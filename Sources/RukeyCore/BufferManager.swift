import Foundation

/// Thread-safe buffer for the word currently being typed.
/// Extracted from `EventTapManager.swift` (God-object split).
/// Adds a capacity cap so a runaway session (e.g. long paste without
/// boundaries) cannot grow the buffer unboundedly.
public final class BufferManager: @unchecked Sendable {
    /// Hard cap: longest real words are < 40 chars; 256 leaves huge margin.
    public static let maxLength = 256

    private var buffer: String = ""
    private let lock = NSLock()

    public init() {}

    public var currentBuffer: String {
        return lock.withLock { buffer }
    }

    public func append(contentsOf text: String) {
        lock.withLock {
            for char in text {
                guard buffer.count < Self.maxLength else { break }
                buffer.append(char)
            }
        }
    }

    public func dropLast() {
        lock.withLock {
            if !buffer.isEmpty { buffer.removeLast() }
        }
    }

    public func replaceBuffer(with text: String) {
        lock.withLock {
            // Keep only the tail — the detector only looks at the trailing run.
            buffer = text.count > Self.maxLength ? String(text.suffix(Self.maxLength)) : text
        }
    }

    public func reset() {
        lock.withLock { buffer.removeAll(keepingCapacity: true) }
    }
}
