import XCTest
import Foundation
@testable import RukeyCore

final class LogBufferTests: XCTestCase {
    func testAppendedLinesComeBackOldestFirst() {
        let buffer = LogBuffer()
        buffer.log("first")
        buffer.log("second")
        buffer.log("third")
        XCTAssertEqual(buffer.lines().map(\.text), ["first", "second", "third"])
    }

    func testFullRingEvictsOldestAndKeepsOrder() {
        let buffer = LogBuffer(capacity: 3)
        for text in ["one", "two", "three", "four"] {
            buffer.log(text)
        }
        XCTAssertEqual(buffer.lines().map(\.text), ["two", "three", "four"])
    }

    func testZeroCapacityClampsToAUsableBuffer() {
        let buffer = LogBuffer(capacity: 0)
        buffer.log("only")
        XCTAssertEqual(buffer.lines().map(\.text), ["only"])
    }

    func testClearEmptiesTheBuffer() {
        let buffer = LogBuffer()
        buffer.log("before")
        buffer.clear()
        XCTAssertEqual(buffer.lines().count, 0)
        buffer.log("after")
        XCTAssertEqual(buffer.lines().map(\.text), ["after"])
    }

    func testLogDefaultsToInfoLevel() {
        let buffer = LogBuffer()
        buffer.log("plain")
        buffer.log("loud", level: .error)
        XCTAssertEqual(buffer.lines().map(\.level), [.info, .error])
    }

    func testLinesReturnsASnapshotNotTheStore() {
        let buffer = LogBuffer()
        buffer.log("kept")
        var snapshot = buffer.lines()
        snapshot.removeAll()
        XCTAssertEqual(buffer.lines().map(\.text), ["kept"])
    }

    func testAppendedLinesCarryTheGivenLevelAndText() {
        let buffer = LogBuffer()
        buffer.append(LogLine(level: .warn, text: "manual"))
        let line = buffer.lines().first
        XCTAssertEqual(line?.level, .warn)
        XCTAssertEqual(line?.text, "manual")
    }
}
