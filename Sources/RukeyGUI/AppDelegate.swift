import AppKit
import RukeyCore

/// Owns the process-lifetime objects of the GUI.
///
/// The tap is deliberately not started in `applicationDidFinishLaunching`:
/// without the Accessibility grant an event tap cannot be created, and this
/// app must stay alive and wait for the grant instead of exiting. The gate
/// polls in the background; the first `.granted` transition builds the
/// engine, then the learning controller, then the hub — on the main actor, in
/// that order (none of the three is `Sendable`) — and starts the tap. The
/// engine is built lazily because `RukeyEngine.init` loads ~1.1 MB of
/// dictionaries, so that work belongs after launch, not in `init`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The launch-time config; the engine is built from it when the grant
    /// appears, while `state` mirrors the settings live from here on.
    private let initialConfig: RukeyConfig
    /// The GUI's single live copy of the settings.
    private let state: SettingsState
    private let gate = PermissionGate()

    /// Built lazily, at most once: on the first `.granted` transition.
    private var engine: RukeyEngine?
    /// Retained: the hub owns the tap's callbacks; nothing else holds it.
    private var hub: AppEventHub?

    public override init() {
        let config = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
        self.initialConfig = config
        self.state = SettingsState(config: config)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        gate.start()
        gate.onChange = { [weak self] newState in
            self?.permissionStateChanged(newState)
        }
        // Check once up front so an already-granted launch starts the tap
        // immediately; the timer then picks up a grant that appears later.
        gate.pollNow()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        engine?.tapManager.stop()
        return .terminateNow
    }

    private func permissionStateChanged(_ newState: PermissionState) {
        guard newState == .granted else { return }
        buildEngineIfNeeded()
    }

    /// Builds the engine, then the controller, then the hub, and starts the
    /// tap exactly once, after the hub exists. Every failure is reported and
    /// the app keeps running; there is no `exit(1)` anywhere in this target.
    private func buildEngineIfNeeded() {
        guard engine == nil else { return }
        let state = self.state
        do {
            let engine = try RukeyEngine(config: initialConfig, verbose: false)
            let learningController = UndoLearningController(
                strikeStore: engine.strikeStore,
                wordFilter: engine.wordFilter,
                // Live reads through `state`: never a captured config snapshot,
                // or a settings change would not apply until relaunch.
                thresholdProvider: { MainActor.assumeIsolated { state.autoLearnThreshold } },
                notifyProvider: { MainActor.assumeIsolated { state.notifyOnEveryUndo } },
                configWriter: { words in
                    // Re-read before mutating — the writer may not be the only editor.
                    var current = RukeyConfig.load(
                        excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
                    current.excludedWords = words.sorted()
                    RukeyConfig.write(current, to: RukeyConfig.configFileURL)
                    MainActor.assumeIsolated { state.excludedWords = current.excludedWords }
                })
            // The hub's initialiser owns all five hooks; assigning any of them
            // by hand would break the one-owner-per-process rule.
            let hub = AppEventHub(
                tapManager: engine.tapManager, learningController: learningController)
            self.engine = engine
            self.hub = hub

            let started = engine.tapManager.start()
            if !started {
                // Task 3's status item is the intended channel; until it
                // exists the log is the only user-facing surface. Not fatal.
                LogBuffer.shared.log(
                    "Не удалось запустить перехват клавиатуры. Проверьте права Accessibility.",
                    level: .error)
            }
        } catch RukeyEngineError.emptyDictionary(let resource) {
            LogBuffer.shared.log(
                "Словарь \(resource) пуст или отсутствует — движок не запущен.",
                level: .error)
        } catch {
            LogBuffer.shared.log("Не удалось инициализировать Rukey: \(error)", level: .error)
        }
    }
}
