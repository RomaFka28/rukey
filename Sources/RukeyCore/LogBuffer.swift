import Foundation

/// A single timestamped log record.
public struct LogLine: Identifiable, Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case debug, info, warn, error
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let text: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: Level,
        text: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.text = text
    }
}

/// Fixed-capacity ring of log lines, for the GUI's log pane and for tests.
///
/// Buffers are injected rather than read from `LogBuffer.shared` so a test never
/// sees the daemon's own lines. Writes are lossy by design: once the ring is full
/// the oldest line is dropped.
///
/// `@unchecked Sendable` is sound because all mutable state is reachable only
/// inside `lock.withLock`, and `LogLine` itself is a `Sendable` value type.
public final class LogBuffer: @unchecked Sendable {
    /// Process-wide buffer used by the daemon.
    public static let shared = LogBuffer()

    private let capacity: Int
    private let lock = NSLock()
    private var slots: [LogLine?]
    /// Index the next `append` writes to.
    private var writeIndex: Int = 0
    /// Number of live lines, capped at `capacity`.
    private var count: Int = 0

    public init(capacity: Int = 500) {
        let size = max(1, capacity)
        self.capacity = size
        self.slots = Array(repeating: nil, count: size)
    }

    /// Appends a line, evicting the oldest one when the ring is full.
    public func append(_ line: LogLine) {
        lock.withLock {
            slots[writeIndex] = line
            writeIndex = (writeIndex + 1) % capacity
            count = min(count + 1, capacity)
        }
    }

    /// Every retained line, oldest first. The returned array is a snapshot;
    /// mutating it does not affect the buffer.
    public func lines() -> [LogLine] {
        lock.withLock {
            guard count > 0 else { return [] }
            let oldest = (writeIndex - count + capacity) % capacity
            return (0..<count).compactMap { slots[(oldest + $0) % capacity] }
        }
    }

    public func clear() {
        lock.withLock {
            for index in slots.indices {
                slots[index] = nil
            }
            writeIndex = 0
            count = 0
        }
    }

    /// Convenience for callers that only have a level and a message.
    public func log(_ text: String, level: LogLine.Level = .info) {
        append(LogLine(level: level, text: text))
    }
}
