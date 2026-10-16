import XCTest
@testable import RukeyCore

final class SecureInputMonitorTests: XCTestCase {
    private func makeMonitor(
        excludeTerminals: Bool = false,
        customExcludedBundleIDs: Set<String> = []
    ) -> SecureInputMonitor {
        SecureInputMonitor(
            excludeTerminals: excludeTerminals,
            customExcludedBundleIDs: customExcludedBundleIDs,
            secureInputCheck: { false },
            frontmostBundleID: { nil }
        )
    }

    func testSecureInputAlwaysBypasses() {
        XCTAssertTrue(makeMonitor().shouldBypass(bundleID: nil, secureInput: true))
    }

    func testSecuritySensitiveBundlesAreAlwaysExcluded() {
        let monitor = makeMonitor()
        for bundleID in SecureInputMonitor.securitySensitiveBundleIDs {
            XCTAssertTrue(
                monitor.shouldBypass(bundleID: bundleID, secureInput: false),
                "\(bundleID) must be excluded whatever the settings say")
        }
    }

    func testExcludeTerminalsSettingIsHonouredWhenChanged() {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.apple.Terminal", secureInput: false))
        monitor.excludeTerminals = true
        XCTAssertTrue(monitor.excludeTerminals)
        XCTAssertTrue(monitor.shouldBypass(bundleID: "com.apple.Terminal", secureInput: false))
        monitor.excludeTerminals = false
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.apple.Terminal", secureInput: false))
    }

    func testCustomExcludedBundleIDsSettingIsHonouredWhenChanged() {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.example.app", secureInput: false))
        monitor.customExcludedBundleIDs = ["com.example.app"]
        XCTAssertEqual(monitor.customExcludedBundleIDs, ["com.example.app"])
        XCTAssertTrue(monitor.shouldBypass(bundleID: "com.example.app", secureInput: false))
        monitor.customExcludedBundleIDs = []
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.example.app", secureInput: false))
    }

    func testUnrelatedBundleIsNotExcluded() {
        XCTAssertFalse(
            makeMonitor(excludeTerminals: true).shouldBypass(
                bundleID: "com.apple.Safari", secureInput: false))
    }
}
