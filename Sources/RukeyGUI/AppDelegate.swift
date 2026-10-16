import AppKit
import Combine
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
///
/// The status item is the one surface that reports all of this: it is created
/// at launch (so the no-grant state is visible immediately), and every change
/// — permission transitions, the tap's real start result, corrections and
/// learned words from the hub, settings — republishes a `StatusMenuModel` to it.
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
    /// The hub's subscriptions. The hub's initialiser owns its five hooks, so
    /// the GUI only ever *observes* `@Published` values — it never reassigns a
    /// callback by hand.
    private var hubObservations: Set<AnyCancellable> = []

    /// The menu-bar item; retained here so the menu is rebuilt from one place.
    private var statusItem: StatusItemController?
    /// The settings window, built on first use and held for the app's lifetime.
    private var settingsWindow: SettingsWindowController?
    /// Whether `engine.tapManager.start()` actually started the tap. A grant
    /// alone must not read "Работает": the status line distinguishes a real
    /// running tap from a failed start ("Не запущено").
    private var tapRunning = false
    /// The hub-derived menu state: the last correction and the newest learned
    /// word. The learned banner stays until the user removes the word.
    private var lastCorrection: CorrectionSummary?
    private var learnedWordBanner: LearnedWordBanner?

    public override init() {
        let config = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
        self.initialConfig = config
        self.state = SettingsState(config: config)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The log window does not exist yet (Task 6); its menu row stays
        // disabled until the opener is wired (nil below).
        let statusItem = StatusItemController(
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onToggleLaunchAtLogin: { [weak self] enabled in
                self?.setLaunchAtLogin(enabled)
            },
            onRemoveLearnedWord: { [weak self] word in
                self?.removeLearnedWord(word)
            },
            onRefreshModel: { [weak self] in
                self?.refreshStatusModel()
            })
        self.statusItem = statusItem
        refreshStatusModel()

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
        if newState == .granted {
            buildEngineIfNeeded()
        }
        // A revocation repaints the status row too; the rebuild is cheap and
        // idempotent, and the grant may be lost and regained over a session.
        refreshStatusModel()
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
            observe(hub)

            let started = engine.tapManager.start()
            tapRunning = started
            if !started {
                // The status item now shows "Не запущено"; this log line stays
                // as the record of why.
                LogBuffer.shared.log(
                    "Не удалось запустить перехват клавиатуры. Проверьте права Accessibility.",
                    level: .error)
            }
        } catch RukeyEngineError.emptyDictionary(let resource) {
            // The status row reports "Не запущено" (no engine, no running tap);
            // the log keeps the reason.
            LogBuffer.shared.log(
                "Словарь \(resource) пуст или отсутствует — движок не запущен.",
                level: .error)
        } catch {
            LogBuffer.shared.log("Не удалось инициализировать Rukey: \(error)", level: .error)
        }
    }

    /// Subscribes to the hub's `@Published` values. The tap lives on the main
    /// run loop, so the emissions arrive on the main thread; the subscriptions
    /// are formed on the main actor, which is where they read and write it.
    private func observe(_ hub: AppEventHub) {
        hubObservations = [
            hub.$lastCorrection.sink { [weak self] decision in
                guard let decision else { return }
                self?.lastCorrection = CorrectionSummary(
                    original: decision.originalText, converted: decision.convertedText)
                self?.refreshStatusModel()
            },
            hub.$lastLearned.sink { [weak self] notice in
                guard let notice else { return }
                // The same `LearningNotice` the `Запомнено:` log line is built
                // from: no log parsing, no `LogBuffer.shared` reads.
                self?.learnedWordBanner = LearnedWordBanner(
                    prefix: notice.prefix, converted: notice.converted)
                self?.refreshStatusModel()
            },
        ]
    }

    /// Rebuilds the menu's snapshot from the live state and hands it over.
    private func refreshStatusModel() {
        let model = StatusMenuModel(
            permission: gate.state,
            running: tapRunning,
            secureInputActive: engine?.secureMonitor.isSecureInputActive() ?? false,
            language: InputSourceManager.shared.effectiveLanguage(),
            lastCorrection: lastCorrection,
            learningBanner: learnedWordBanner,
            launchAtLogin: state.launchAtLogin,
            excludedBundleIDs: state.excludedBundleIDs.sorted())
        statusItem?.update(model)
    }

    /// The banner's `Убрать`: remove the word from the filter, clear its
    /// strikes so it can be learned again, and persist the remaining list.
    private func removeLearnedWord(_ word: String) {
        learnedWordBanner = nil
        if let engine {
            engine.wordFilter.replaceAll(with: engine.wordFilter.words.subtracting([word]))
            // Without this the exact-match learning condition can never fire
            // for the word again — the same reason Task 4's removal clears
            // strikes.
            engine.strikeStore.removeAllKeys(for: word)
            // Re-read before mutating — the writer may not be the only editor.
            var current = RukeyConfig.load(
                excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
            current.excludedWords = engine.wordFilter.words.sorted()
            RukeyConfig.write(current, to: RukeyConfig.configFileURL)
            state.excludedWords = current.excludedWords
        }
        refreshStatusModel()
    }

    /// The menu checkbox writes the flag and persists it for now; Task 6's
    /// `SettingsStore` replaces this with the LaunchAgent registration path.
    private func setLaunchAtLogin(_ enabled: Bool) {
        state.launchAtLogin = enabled
        // Re-read before mutating — the writer may not be the only editor.
        var current = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
        current.launchAtLogin = enabled
        RukeyConfig.write(current, to: RukeyConfig.configFileURL)
        refreshStatusModel()
    }

    /// The `Настройки…` opener. The window edits the live word lists, so it
    /// needs the engine — and the engine only exists once the grant has
    /// appeared; a click before that is a no-op, with the red status row
    /// already explaining why. The controller is created once and reused.
    private func openSettings() {
        guard let engine else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                engine: engine,
                state: state,
                onClose: { [weak self] in
                    self?.settingsWindowDidClose()
                })
        }
        settingsWindow?.show()
    }

    /// Closing the settings window can invalidate the learned-word banner: the
    /// word may have just been removed there. The banner is dropped when its
    /// word is no longer excluded, and the menu is refreshed either way.
    private func settingsWindowDidClose() {
        if let banner = learnedWordBanner, let engine,
            !engine.wordFilter.isExcluded(banner.prefix)
        {
            learnedWordBanner = nil
        }
        refreshStatusModel()
    }
}
