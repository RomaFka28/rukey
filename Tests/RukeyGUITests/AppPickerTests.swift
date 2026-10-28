import XCTest
@testable import RukeyGUI

final class AppPickerTests: XCTestCase {
    private func makeApp(_ name: String, _ bundleID: String) -> InstalledApp {
        InstalledApp(id: bundleID, name: name)
    }

    func testSearchMatchesNameCaseInsensitively() {
        let apps = [makeApp("Safari", "com.apple.Safari"), makeApp("Slack", "com.tinyspeck.slack")]
        let found = AppPicker.search("saf", in: apps)
        XCTAssertEqual(found.map(\.name), ["Safari"])
    }

    func testSearchMatchesBundleIdentifier() {
        let apps = [makeApp("Safari", "com.apple.Safari"), makeApp("Slack", "com.tinyspeck.slack")]
        XCTAssertEqual(AppPicker.search("tinyspeck", in: apps).map(\.name), ["Slack"])
    }

    func testEmptyQueryReturnsEverything() {
        let apps = [makeApp("Safari", "com.apple.Safari"), makeApp("Slack", "com.tinyspeck.slack")]
        XCTAssertEqual(AppPicker.search("", in: apps).count, 2)
    }

    func testResultsAreSortedByName() {
        let apps = [makeApp("Slack", "b"), makeApp("Safari", "a")]
        XCTAssertEqual(AppPicker.search("", in: apps).map(\.name), ["Safari", "Slack"])
    }

    func testNoMatchReturnsEmpty() {
        let apps = [makeApp("Safari", "com.apple.Safari")]
        XCTAssertTrue(AppPicker.search("zzzz", in: apps).isEmpty)
    }
}
