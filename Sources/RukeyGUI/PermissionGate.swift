import AppKit

/// What the Accessibility permission check last reported.
///
/// `unknown` is the state before the first poll, so a consumer can tell
/// "not asked yet" apart from "asked and refused". The poll itself only ever
/// produces `granted`/`denied` — there is no third "prompt pending" state,
/// because the gate never prompts: it watches the grant the user opens
/// manually.
@MainActor
public enum PermissionState: Equatable {
    case unknown
    case granted
    case denied
}

/// Watches the Accessibility grant without blocking or exiting the app.
///
/// The state machine is deliberately tiny: a repeating main-run-loop timer
/// reads an injectable probe (`AXIsProcessTrusted` in production, a captured
/// variable in tests) and reports every real transition through `onChange`.
/// A denial is not fatal — the app stays alive and starts working the moment
/// the grant appears.
@MainActor
public final class PermissionGate {
    /// The last reported state; `.unknown` until the first poll.
    public private(set) var state: PermissionState = .unknown

    /// Fires on every real transition, never on a repeated poll.
    public var onChange: ((PermissionState) -> Void)?

    private let pollInterval: TimeInterval
    private let probe: () -> Bool
    private var timer: Timer?

    /// - Parameter probe: the accessibility check. Injectable so the gate can
    ///   be tested without real permissions.
    public init(
        pollInterval: TimeInterval = 2.0,
        probe: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.pollInterval = pollInterval
        self.probe = probe
    }

    /// Schedules the repeating poll on the main run loop in `.common` mode, so
    /// it keeps firing while menus or window tracking runs. Does not poll
    /// immediately; the caller decides when the first check happens.
    public func start() {
        guard timer == nil else { return }
        // The probe reads main-actor state; `scheduleOnMain` guarantees every
        // tick runs there.
        timer = Timer.scheduleOnMain(interval: pollInterval) { [weak self] in
            self?.pollNow()
        }
    }

    /// Test-only teardown: invalidates the poll while keeping the gate itself
    /// usable for the next `start()`.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the probe once. Updates `state` and fires `onChange` only when
    /// the value actually changed.
    public func pollNow() {
        let newState: PermissionState = probe() ? .granted : .denied
        guard newState != state else { return }
        state = newState
        onChange?(newState)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    /// - Returns: whether the system accepted the open request.
    @discardableResult
    public func openSystemSettings() -> Bool {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return false }
        return NSWorkspace.shared.open(url)
    }
}
