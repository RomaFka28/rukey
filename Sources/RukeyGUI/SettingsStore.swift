import Combine
import Foundation
import RukeyCore

/// The settings window's general tab and the menu's launch-at-login checkbox,
/// writing through to one shared home: this store.
///
/// Every property is a computed property. Reads come from the live
/// `SettingsState` — never from `engine.config`, an immutable launch-time
/// snapshot — and a write goes through in one action: the live engine object
/// (when there is one), the config file, and `SettingsState`. Every file write
/// re-reads the config immediately before mutating and hands the whole struct
/// to `RukeyConfig.write`: two tabs can each hold a stale base, and the writer
/// cannot fix that.
///
/// `launchAtLogin` is the one property with an external side effect: it writes
/// (or removes) a LaunchAgent plist. A failed write must not leave a checkbox
/// that lies (anti-goal 2), so it rolls back to the previous value, stores
/// `lastError` and logs a `.warn`.
///
/// `ObservableObject` and the manual `objectWillChange.send()` on every write
/// exist because the SwiftUI bindings are `Binding(get:set:)` over these
/// computed properties: without a published change the view would not learn
/// that a write rolled back, or that the visible log grew.
@MainActor
public final class SettingsStore: ObservableObject {
    /// The plist launchd reads at login. Written by `launchAtLogin`; the app's
    /// path is baked in, per the spec's LaunchAgent decision, which is why the
    /// write result is reported rather than assumed.
    public static let defaultLaunchAgentFileURL: URL =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.roman.rukey.plist")

    let engine: RukeyEngine
    let state: SettingsState

    /// Where the LaunchAgent plist is written. A stored property so the failure
    /// path is testable; the init parameter seeds it.
    public var launchAgentFileURLOverride: URL

    /// The last launch-at-login failure, cleared by the next successful change.
    /// The menu uses it to say why the checkbox snapped back.
    public private(set) var lastError: String?

    private let configFileURL: URL
    private let logBuffer: LogBuffer
    private var showOnlyErrorsStorage = false

    /// The visible-log poll. `LogBuffer` deliberately has no notification API,
    /// so the Журнал tab asks the store to watch while it is on screen.
    private var logRefreshTimer: Timer?
    private var lastLogCount = -1
    private var lastLogTailID: UUID?

    public init(
        engine: RukeyEngine,
        state: SettingsState,
        configFileURL: URL,
        launchAgentFileURL: URL = SettingsStore.defaultLaunchAgentFileURL,
        logBuffer: LogBuffer = .shared
    ) {
        self.engine = engine
        self.state = state
        self.configFileURL = configFileURL
        self.launchAgentFileURLOverride = launchAgentFileURL
        self.logBuffer = logBuffer
    }

    // MARK: - Scalars

    /// Clamped to `RukeyConfig.minPrefixLengthRange` (2...5): the stepper sends
    /// an in-range value, and the clamp is the store's own guard for any other
    /// caller. The detector is written first so the very next keystroke uses
    /// the new length.
    public var minPrefixLength: Int {
        get { state.minPrefixLength }
        set {
            let range = RukeyConfig.minPrefixLengthRange
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            engine.detector.minPrefixLength = clamped
            persist { $0.minPrefixLength = clamped }
            state.minPrefixLength = clamped
            objectWillChange.send()
        }
    }

    /// The stepper's admissible values are 0/2/3/5; any other write is refused
    /// rather than stored, so `state` and the file can never hold a value the
    /// loader would discard on the next launch. The learning controller reads
    /// `state.autoLearnThreshold` live, so this is the whole live path.
    public var autoLearnThreshold: Int {
        get { state.autoLearnThreshold }
        set {
            guard RukeyConfig.autoLearnThresholds.contains(newValue) else { return }
            persist { $0.autoLearnThreshold = newValue }
            state.autoLearnThreshold = newValue
            objectWillChange.send()
        }
    }

    /// Read live by `UndoLearningController` through AppDelegate's
    /// `notifyProvider`, exactly like the threshold.
    public var notifyOnEveryUndo: Bool {
        get { state.notifyOnEveryUndo }
        set {
            persist { $0.notifyOnEveryUndo = newValue }
            state.notifyOnEveryUndo = newValue
            objectWillChange.send()
        }
    }

    public var showCorrectionFlash: Bool {
        get { state.showCorrectionFlash }
        set {
            persist { $0.showCorrectionFlash = newValue }
            state.showCorrectionFlash = newValue
            objectWillChange.send()
        }
    }

    /// The live monitor is written first: the very next keystroke respects the
    /// checkbox, not the next relaunch.
    public var excludeTerminals: Bool {
        get { state.excludeTerminals }
        set {
            engine.secureMonitor.excludeTerminals = newValue
            persist { $0.excludeTerminals = newValue }
            state.excludeTerminals = newValue
            objectWillChange.send()
        }
    }

    // MARK: - Launch at login

    /// Writes the LaunchAgent plist (or removes it) and persists the flag.
    ///
    /// The plist is the registration — launchd reads it at login — so it is
    /// written first; a failed write or config save rolls the value back to
    /// where it was before the attempt, keeps the reason in `lastError`, and
    /// logs it. The checkbox can therefore never show a registration that did
    /// not happen.
    public var launchAtLogin: Bool {
        get { state.launchAtLogin }
        set {
            let previous = state.launchAtLogin
            guard newValue != previous else { return }
            guard toggleAgent(newValue, previous: previous) else { return }
            state.launchAtLogin = newValue
            lastError = nil
            objectWillChange.send()
        }
    }

    /// Registering and deregistering are mirror images: set or remove the
    /// plist, persist the flag, and undo the plist when the config save
    /// failed — in both directions the checkbox and the file must not
    /// disagree. The exact failure strings stay distinct per direction.
    /// - Returns: whether both the plist step and the config write succeeded;
    ///   the failure path has already restored `previous` via `fail`.
    @discardableResult
    private func toggleAgent(_ on: Bool, previous: Bool) -> Bool {
        do {
            if on {
                try writeLaunchAgent()
            } else {
                // Removing an entry that is not there is a success: the
                // desired end state (no agent) already holds.
                try removeLaunchAgent()
            }
        } catch {
            fail(
                previous,
                on
                    ? "Не удалось зарегистрировать автозапуск: \(error.localizedDescription)"
                    : "Не удалось отключить автозапуск: \(error.localizedDescription)")
            return false
        }
        guard persist({ $0.launchAtLogin = on }) else {
            // The config file could not be written; undo the plist so the
            // settings file and the agent cannot disagree. For "off" that
            // means putting the plist back: the checkbox must keep matching
            // the file it could not update.
            if on {
                do {
                    try FileManager.default.removeItem(at: launchAgentFileURLOverride)
                } catch {
                    logBuffer.log(
                        "Не удалось откатить регистрацию автозапуска: "
                            + "\(error.localizedDescription)",
                        level: .error
                    )
                }
            } else {
                do {
                    try writeLaunchAgent()
                } catch {
                    logBuffer.log(
                        "Не удалось восстановить регистрацию автозапуска: "
                            + "\(error.localizedDescription)",
                        level: .error
                    )
                }
            }
            fail(
                previous,
                on
                    ? "Не удалось сохранить настройку автозапуска; регистрация отменена."
                    : "Не удалось сохранить настройку автозапуска; отключение отменено.")
            return false
        }
        return true
    }

    /// The LaunchAgent plist: label, `RunAtLoad`, and the app bundle's fixed
    /// `Contents/MacOS/Rukey` executable. The parent directory is created when
    /// missing (`~/Library/LaunchAgents` is not guaranteed on a fresh account).
    private func writeLaunchAgent() throws {
        let url = launchAgentFileURLOverride
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": "com.roman.rukey",
            "ProgramArguments": [Self.launchAgentExecutablePath],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Removing an entry that is not there is a success: the desired end state
    /// (no agent) already holds.
    private func removeLaunchAgent() throws {
        let url = launchAgentFileURLOverride
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Rolls the checkbox back to its previous value, keeps the reason, and
    /// says it in the log.
    private func fail(_ previous: Bool, _ message: String) {
        state.launchAtLogin = previous
        lastError = message
        logBuffer.log(message, level: .warn)
        objectWillChange.send()
    }

    /// The app entry point the LaunchAgent starts: the bundle's
    /// `Contents/MacOS/Rukey`, not this process's own path, which is a build
    /// directory during development.
    static let launchAgentExecutablePath: String =
        Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/Rukey")
        .path

    // MARK: - Log

    /// «Только ошибки» in the Журнал tab. Kept on the store so the picker is a
    /// plain `Binding(get:set:)`, like every other control.
    public var showOnlyErrors: Bool {
        get { showOnlyErrorsStorage }
        set {
            guard newValue != showOnlyErrorsStorage else { return }
            showOnlyErrorsStorage = newValue
            objectWillChange.send()
        }
    }

    /// The injected buffer's retained lines, oldest first — newest last, as the
    /// tab renders them — filtered to errors when asked. `LogBuffer.shared` in
    /// the app, a per-test buffer in tests.
    public var logLines: [LogLine] {
        let lines = logBuffer.lines()
        guard showOnlyErrorsStorage else { return lines }
        return lines.filter { $0.level == .error }
    }

    /// Starts the visible-log poll. `LogBuffer` has no observation hook, so the
    /// Журнал tab calls this while it is on screen; a tick republishes only
    /// when the tail changed, so an unchanged log costs one snapshot read per
    /// second and no view update.
    public func beginLogRefresh() {
        guard logRefreshTimer == nil else { return }
        logRefreshTimer = Timer.scheduleOnMain(interval: 1.0) { [weak self] in
            self?.refreshLogIfChanged()
        }
        refreshLogIfChanged()
    }

    public func endLogRefresh() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = nil
    }

    private func refreshLogIfChanged() {
        let lines = logBuffer.lines()
        guard lines.count != lastLogCount || lines.last?.id != lastLogTailID else { return }
        lastLogCount = lines.count
        lastLogTailID = lines.last?.id
        objectWillChange.send()
    }

    // MARK: - Config plumbing

    /// Re-read, merge, write: the file may have been edited since the store's
    /// last action, so the change lands on a *fresh* copy and the whole struct
    /// goes to the one writer. The live `state` is updated by the caller in the
    /// same action.
    /// - Returns: whether the file write succeeded; `RukeyConfig.write` has
    ///   already logged a `.warn` when it did not.
    @discardableResult
    private func persist(_ mutate: (inout RukeyConfig) -> Void) -> Bool {
        RukeyConfig.update(
            atFileURL: configFileURL, logBuffer: logBuffer, apply: mutate)
    }
}
