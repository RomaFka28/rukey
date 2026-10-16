import XCTest
@testable import RukeyCore

final class DaemonBootstrapTests: XCTestCase {
    private func makeConfig() -> RukeyConfig {
        RukeyConfig.load(
            excludeTerminalsFlag: false,
            extraBundleIDs: [],
            verbose: false,
            configFileURL: URL(fileURLWithPath: "/nonexistent/exclude.json")
        )
    }

    /// Both stores default to files under the real `~/.config/rukey`, so every
    /// engine in this suite is built on per-test temporary paths: no test may
    /// read or write the developer's own configuration.
    private func makeTempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    func testEngineBuildsEveryStoreFromOneConfig() throws {
        let engine = try RukeyEngine(
            config: makeConfig(),
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertTrue(engine.wordFilter.isEmpty)
        XCTAssertEqual(engine.undoManager.canUndo, false)
        XCTAssertEqual(engine.strikeStore.strikes(for: "anything"), 0)
    }

    func testExcludedWordsFromConfigReachTheFilter() throws {
        var config = makeConfig()
        config.excludedWords = ["ghbdtn"]
        let engine = try RukeyEngine(
            config: config,
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertTrue(engine.wordFilter.isExcluded("ghbdtn"))
    }

    func testCustomWordsReachTheDetector() throws {
        let url = makeTempURL("custom")
        CustomDictionary(fileURL: url).replaceAll(with: ["заозкздзаоз"])
        let engine = try RukeyEngine(
            config: makeConfig(),
            verbose: false,
            customDictionaryFileURL: url,
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertTrue(engine.customDictionary.contains("заозкздзаоз"))
    }

    func testBundleIDExclusionsReachTheSecureMonitor() throws {
        var config = makeConfig()
        config.excludedBundleIDs = ["com.example.app"]
        let engine = try RukeyEngine(
            config: config,
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertEqual(engine.secureMonitor.customExcludedBundleIDs, ["com.example.app"])
    }

    /// Every setting the user can change must reach the object that reads it.
    /// The brief singles out `minPrefixLength` ("not a literal 3, or the
    /// settings would not take effect") and `verbose` ("that is what the
    /// `verbose` parameter is for"); both directions are pinned.
    func testSettingsReachTheObjectsThatReadThem() throws {
        var config = makeConfig()
        config.minPrefixLength = 2
        config.excludeTerminals = true
        let changed = try RukeyEngine(
            config: config,
            verbose: true,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertEqual(changed.detector.minPrefixLength, 2)
        XCTAssertTrue(changed.secureMonitor.excludeTerminals)
        XCTAssertTrue(changed.tapManager.logger.isVerbose)

        let plain = try RukeyEngine(
            config: makeConfig(),
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertEqual(plain.detector.minPrefixLength, 3)
        XCTAssertFalse(plain.secureMonitor.excludeTerminals)
        XCTAssertFalse(plain.tapManager.logger.isVerbose)
    }
}
