import Foundation
import XCTest
@testable import RukeyCore

final class RukeyConfigTests: XCTestCase {
    // `throws`, not `rethrows`: creating the temp directory is a throwing call in
    // its own right, so `rethrows` would not compile.
    private func withTempHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    func testMergesFlagsWithFileBundleIDs() {
        let config = RukeyConfig.load(
            excludeTerminalsFlag: true,
            extraBundleIDs: ["com.example.fromFlag"],
            verbose: false,
            configFileURL: URL(fileURLWithPath: "/nonexistent/exclude.json")
        )
        XCTAssertTrue(config.excludeTerminals)
        XCTAssertEqual(config.excludedBundleIDs, ["com.example.fromFlag"])
    }

    func testFileAddsToFlagBundleIDs() throws {
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{ \"excludeBundleIDs\": [\"com.example.fromFile\"] }".write(
                to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: ["com.example.fromFlag"],
                verbose: false,
                configFileURL: url
            )
            XCTAssertEqual(
                config.excludedBundleIDs,
                ["com.example.fromFlag", "com.example.fromFile"])
        }
    }

    func testNewKeysFallBackToDefaults() {
        let config = RukeyConfig.load(
            excludeTerminalsFlag: false,
            extraBundleIDs: [],
            verbose: false,
            configFileURL: URL(fileURLWithPath: "/nonexistent/exclude.json")
        )
        XCTAssertEqual(config.autoLearnThreshold, 3)
        XCTAssertEqual(config.minPrefixLength, 3)
        XCTAssertTrue(config.notifyOnEveryUndo)
        XCTAssertTrue(config.showCorrectionFlash)
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertEqual(config.excludeTerminals, false)
        XCTAssertEqual(config.excludedWords, [])
    }

    func testValuesAreReadFromFile() throws {
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? """
            {
              "excludeBundleIDs": ["com.example.app"],
              "excludedWords": ["ghbdtn", "иуикф"],
              "excludeTerminals": true,
              "launchAtLogin": true,
              "autoLearnThreshold": 5,
              "notifyOnEveryUndo": false,
              "minPrefixLength": 4
            }
            """.write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: [],
                verbose: false,
                configFileURL: url
            )
            XCTAssertEqual(Set(config.excludedWords), ["ghbdtn", "иуикф"])
            XCTAssertEqual(config.excludeTerminals, true)
            XCTAssertEqual(config.autoLearnThreshold, 5)
            XCTAssertEqual(config.notifyOnEveryUndo, false)
            XCTAssertEqual(config.minPrefixLength, 4)
            XCTAssertTrue(config.launchAtLogin)          // read path
            XCTAssertTrue(config.showCorrectionFlash)    // omitted from the file -> default
        }
    }

    func testExplicitFlagSurvivesAFileThatSaysFalse() throws {
        // Anti-goal 2: an explicit CLI flag must not be silently discarded by a config file.
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{\"excludeTerminals\": false}".write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: true,
                extraBundleIDs: [],
                verbose: false,
                configFileURL: url
            )
            XCTAssertTrue(config.excludeTerminals)
        }
    }

    func testOutOfRangeMinPrefixLengthFallsBackAndWarns() throws {
        let buffer = LogBuffer()
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{\"minPrefixLength\": 0}".write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: [],
                verbose: false,
                configFileURL: url,
                logBuffer: buffer
            )
            XCTAssertEqual(config.minPrefixLength, 3)
            XCTAssertTrue(
                buffer.lines().contains { $0.level == .warn && $0.text.contains("minPrefixLength") },
                "an out-of-range minPrefixLength must be reported, not silently applied")
        }
    }

    func testOutOfRangeAutoLearnThresholdFallsBackAndWarns() throws {
        let buffer = LogBuffer()
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{\"autoLearnThreshold\": 4}".write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: [],
                verbose: false,
                configFileURL: url,
                logBuffer: buffer
            )
            XCTAssertEqual(config.autoLearnThreshold, 3)
            XCTAssertTrue(
                buffer.lines().contains { $0.level == .warn && $0.text.contains("autoLearnThreshold") },
                "an out-of-range autoLearnThreshold must be reported, not silently applied")
        }
    }

    func testCorruptFileFallsBackAndReportsReason() throws {
        let buffer = LogBuffer()
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{ not json at all ".write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: ["com.example.flag"],
                verbose: false,
                configFileURL: url,
                logBuffer: buffer
            )
            XCTAssertEqual(config.excludedBundleIDs, ["com.example.flag"])
            XCTAssertTrue(
                buffer.lines().contains { $0.level == .warn && $0.text.contains("exclude.json") },
                "a corrupt config must be reported, not silently swallowed")
            XCTAssertTrue(
                buffer.lines().contains { $0.text.contains("exclude.json") && $0.text.contains("Unexpected character") },
                "the warning must name the parse failure, not a generic Cocoa message")
        }
    }
}
