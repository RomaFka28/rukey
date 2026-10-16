import XCTest
@testable import RukeyGUI

@MainActor
final class PermissionGateTests: XCTestCase {
    func testStartsUnknownAndReportsGranted() {
        var trusted = false
        let gate = PermissionGate { trusted }
        gate.start()
        XCTAssertEqual(gate.state, .unknown)
        trusted = true
        gate.pollNow()
        XCTAssertEqual(gate.state, .granted)
        gate.stop()
    }

    func testDeniedIsReported() {
        let trusted = false
        let gate = PermissionGate { trusted }
        gate.start()
        gate.pollNow()
        XCTAssertEqual(gate.state, .denied)
        gate.stop()
    }

    func testChangeCallbackFiresOnlyOnTransition() {
        let trusted = false
        var calls: [PermissionState] = []
        let gate = PermissionGate { trusted }
        gate.onChange = { calls.append($0) }
        gate.start()
        gate.pollNow()
        gate.pollNow()
        XCTAssertEqual(calls, [.denied])
        gate.stop()
    }
}
