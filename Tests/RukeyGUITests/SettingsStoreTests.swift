import XCTest
@testable import RukeyCore
@testable import RukeyGUI

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeStore(logBuffer: LogBuffer = LogBuffer()) throws -> (SettingsStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("com.roman.rukey.plist")
        let config = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false,
            configFileURL: base.appendingPathComponent("exclude.json"))
        let engine = try RukeyEngine(
            config: config,
            verbose: false,
            customDictionaryFileURL: base.appendingPathComponent("custom.json"),
            strikeStoreFileURL: base.appendingPathComponent("learned.json")
        )
        let store = SettingsStore(
            engine: engine, state: SettingsState(config: config),
            configFileURL: base.appendingPathComponent("exclude.json"),
            launchAgentFileURL: url, logBuffer: logBuffer)
        return (store, url)
    }

    func testEnablingLaunchAtLoginWritesALaunchAgent() throws {
        let (store, url) = try makeStore()
        store.launchAtLogin = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["Label"] as? String, "com.roman.rukey")
        XCTAssertNotNil((plist?["ProgramArguments"] as? [String])?.first)
        store.launchAtLogin = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailingRegistrationReportsRatherThanLying() throws {
        let (store, _) = try makeStore()
        store.launchAgentFileURLOverride = URL(fileURLWithPath: "/nonexistent-dir/x.plist")
        store.launchAtLogin = true
        XCTAssertFalse(store.launchAtLogin, "a failed write must not leave the checkbox on")
        XCTAssertTrue(store.lastError != nil)
    }

    func testLogFilterShowsOnlyErrors() throws {
        let buffer = LogBuffer()
        let (store, _) = try makeStore(logBuffer: buffer)
        buffer.log("noise", level: .debug)
        buffer.log("boom", level: .error)
        store.showOnlyErrors = true
        XCTAssertEqual(store.logLines.map(\.text), ["boom"])
    }

    func testMinPrefixLengthChangeReachesTheDetector() throws {
        let (store, _) = try makeStore()
        store.minPrefixLength = 4
        XCTAssertEqual(store.engine.detector.minPrefixLength, 4)
    }
}
