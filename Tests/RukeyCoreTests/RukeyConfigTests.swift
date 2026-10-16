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
                buffer.lines().contains {
                    $0.level == .warn && $0.text.contains("minPrefixLength = 0 is out of range")
                },
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
                buffer.lines().contains {
                    $0.level == .warn && $0.text.contains("autoLearnThreshold = 4 is out of range")
                },
                "an out-of-range autoLearnThreshold must be reported, not silently applied")
        }
    }

    func testAnOutOfRangeKeyDoesNotDropItsValidNeighbours() throws {
        // Anti-goal 2's file-side twin: rejecting the whole file because one key
        // is out of range would silently drop every other value in it.
        let buffer = LogBuffer()
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{ \"autoLearnThreshold\": 5, \"minPrefixLength\": 0 }"
                .write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: [],
                verbose: false,
                configFileURL: url,
                logBuffer: buffer
            )
            XCTAssertEqual(config.autoLearnThreshold, 5)
            XCTAssertEqual(config.minPrefixLength, 3)
            XCTAssertTrue(
                buffer.lines().contains {
                    $0.level == .warn && $0.text.contains("minPrefixLength = 0 is out of range")
                },
                "the offending key must still be reported")
        }
    }

    func testAdmissibleValuesPassThroughWithoutWarnings() throws {
        // `0` is the spec's "disabled" setting: a guard written as `value > 0`
        // would silently reject it. The set's members and the range's edges are
        // pinned so a narrowing refactor cannot pass unnoticed.
        let cases: [(threshold: Int, prefix: Int)] = [(0, 2), (2, 3), (3, 4), (5, 5)]
        try withTempHome { home in
            for (threshold, prefix) in cases {
                let url = home.appendingPathComponent("exclude-\(threshold).json")
                try? "{ \"autoLearnThreshold\": \(threshold), \"minPrefixLength\": \(prefix) }"
                    .write(to: url, atomically: true, encoding: .utf8)
                let buffer = LogBuffer()
                let config = RukeyConfig.load(
                    excludeTerminalsFlag: false,
                    extraBundleIDs: [],
                    verbose: false,
                    configFileURL: url,
                    logBuffer: buffer
                )
                XCTAssertEqual(config.autoLearnThreshold, threshold)
                XCTAssertEqual(config.minPrefixLength, prefix)
                XCTAssertFalse(
                    buffer.lines().contains { $0.level == .warn },
                    "admissible values (\(threshold), \(prefix)) must not be reported")
            }
        }
    }

    func testTypeMismatchIsReportedAndFallsBack() throws {
        // `.typeMismatch` is a reachable decode failure (`"minPrefixLength": "3"`):
        // the file is rejected as a whole, the CLI values survive, and the reason
        // names the actual problem.
        let buffer = LogBuffer()
        try withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{ \"minPrefixLength\": \"3\" }".write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: ["com.example.flag"],
                verbose: false,
                configFileURL: url,
                logBuffer: buffer
            )
            XCTAssertEqual(config.minPrefixLength, 3)
            XCTAssertEqual(config.excludedBundleIDs, ["com.example.flag"])
            XCTAssertTrue(
                buffer.lines().contains { $0.level == .warn && $0.text.contains("wrong type") },
                "a type mismatch must be reported with its actual reason")
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
                buffer.lines().contains {
                    $0.level == .warn && $0.text.contains("exclude.json")
                        && $0.text.contains("Unexpected character")
                },
                "a corrupt config must be warned about with its parse failure, not silently swallowed")
        }
    }

    func testWriteRoundTripsEveryField() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exclude-\(UUID().uuidString).json")
        let config = RukeyConfig(
            excludedWords: ["ghbdtn"],
            excludeTerminals: true,
            excludedBundleIDs: ["com.example.app"],
            launchAtLogin: true,
            autoLearnThreshold: 2,
            notifyOnEveryUndo: false,
            showCorrectionFlash: false,
            minPrefixLength: 5,
            verbose: true
        )
        XCTAssertTrue(RukeyConfig.write(config, to: url))
        let reloaded = RukeyConfig.load(
            excludeTerminalsFlag: false,
            extraBundleIDs: [],
            verbose: false,
            configFileURL: url
        )
        XCTAssertEqual(reloaded.excludedWords, ["ghbdtn"])
        XCTAssertEqual(reloaded.excludedBundleIDs, ["com.example.app"])
        XCTAssertTrue(reloaded.excludeTerminals)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertEqual(reloaded.autoLearnThreshold, 2)
        XCTAssertFalse(reloaded.notifyOnEveryUndo)
        XCTAssertFalse(reloaded.showCorrectionFlash)
        XCTAssertEqual(reloaded.minPrefixLength, 5)
        // `verbose` is CLI-only: the file never carries it.
        XCTAssertFalse(reloaded.verbose)
    }

    func testWriteCreatesTheConfigDirectory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-\(UUID().uuidString)/nested/exclude.json")
        XCTAssertTrue(RukeyConfig.write(RukeyConfig(), to: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteFailureIsReported() {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let buffer = LogBuffer()
        XCTAssertFalse(RukeyConfig.write(
            RukeyConfig(), to: blocker.appendingPathComponent("exclude.json"),
            logBuffer: buffer))
        XCTAssertTrue(buffer.lines().contains {
            $0.level == .warn && $0.text.contains(blocker.path)
        })
    }
}
