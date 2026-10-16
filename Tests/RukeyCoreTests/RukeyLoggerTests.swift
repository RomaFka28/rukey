import XCTest
@testable import RukeyCore

final class RukeyLoggerTests: XCTestCase {
    func testLogLevelsReachTheBuffer() {
        let buffer = LogBuffer()
        let logger = RukeyLogger(
            isVerbose: false, mirrorToStandardOutput: false, logBuffer: buffer)
        logger.debug("quiet")
        logger.info("plain")
        logger.warn("careful")
        logger.error("broken")
        XCTAssertEqual(buffer.lines().map(\.level), [.info, .warn, .error])
    }

    func testVerboseGatesDebugAndKeepsItsText() {
        let buffer = LogBuffer()
        let logger = RukeyLogger(
            isVerbose: true, mirrorToStandardOutput: false, logBuffer: buffer)
        logger.debug("loud")
        XCTAssertEqual(buffer.lines().last?.level, .debug)
        XCTAssertEqual(buffer.lines().last?.text, "loud")
    }
}
