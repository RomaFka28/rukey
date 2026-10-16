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
    /// The settings writer shared by the general tab and the menu's
    /// launch-at-login checkbox. Built with the engine (it holds the live
    /// engine objects); nil until the grant appears.
    private var settingsStore: SettingsStore?
    /// The correction flash panel; built with the engine because corrections
    /// can only arrive once the tap runs.
    private var correctionFlash: CorrectionFlash?
    /// The notification centre wrapper. Built **only** when this process is a
    /// real `.app` bundle: `UNUserNotificationCenter.current()` aborts an
    /// unbundled process and the default argument evaluates at the call site
    /// (see `buildEngineIfNeeded`). Nil under `swift run` and in tests.
    private var notificationService: NotificationService?
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
        // The Журнал… row now opens the settings window on the log tab via
        // `openLog()`; it used to be disabled while `onOpenLog` was nil.
        let statusItem = StatusItemController(
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onOpenLog: { [weak self] in
                self?.openLog()
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
            // The flash panel is plain AppKit and harmless anywhere; it is
            // built with the engine so the first correction of the session
            // already has its one reused panel.
            self.correctionFlash = CorrectionFlash()
            // `UNUserNotificationCenter.current()` aborts a process that is
            // not a real bundle ("bundleProxyForCurrentProcess is nil"), and
            // the service's default argument evaluates right here — so the
            // service is constructed only when this process is the packaged
            // `Rukey.app`. Under `swift run` and in tests the whole
            // notification path stays quiet, and the hub's notifications
            // fall to the nil-guard in `showUndoNotice`/`showLearnedNotice`.
            if Bundle.main.bundleIdentifier != nil {
                let service = NotificationService()
                self.notificationService = service
                Task { await service.requestAuthorization() }
            }
            observe(hub)
            self.settingsStore = SettingsStore(
                engine: engine, state: state, configFileURL: RukeyConfig.configFileURL)

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
                self?.flashCorrection(decision)
            },
            hub.$lastLearned.sink { [weak self] notice in
                guard let notice else { return }
                // The same `LearningNotice` the `Запомнено:` log line is built
                // from: no log parsing, no `LogBuffer.shared` reads.
                self?.learnedWordBanner = LearnedWordBanner(
                    prefix: notice.prefix, converted: notice.converted)
                self?.refreshStatusModel()
                self?.showLearnedNotice(notice)
            },
            hub.$lastUndo.sink { [weak self] notice in
                guard let notice else { return }
                // Gated upstream by the learning controller's live
                // `notifyProvider` (`state.notifyOnEveryUndo`), exactly like
                // the console's own `Отменено:` line — never a second time
                // here, or the menu and the banners would drift apart.
                self?.showUndoNotice(notice)
            },
        ]
    }

    /// The corner panel: the tested formatter builds the string and the live
    /// `showCorrectionFlash` setting decides whether it appears.
    private func flashCorrection(_ decision: CorrectionDecision) {
        guard state.showCorrectionFlash, let flash = correctionFlash else { return }
        flash.show(
            CorrectionFlash.text(
                original: decision.originalText, converted: decision.convertedText))
    }

    /// The undo banner, already gated upstream (see `observe`). Quiet when no
    /// bundle means no notification service exists.
    private func showUndoNotice(_ notice: UndoNotice) {
        guard let service = notificationService else { return }
        Task {
            await service.showUndoNotice(
                prefix: notice.prefix, converted: notice.converted,
                count: notice.count, threshold: notice.threshold)
        }
    }

    /// The learned banner, always attempted — the same rule as the engine's
    /// `Запомнено:` line, which is written whenever the word is learned.
    private func showLearnedNotice(_ notice: LearnedNotice) {
        guard let service = notificationService else { return }
        Task {
            await service.showLearnedNotice(
                prefix: notice.prefix, converted: notice.converted)
        }
    }

    /// Rebuilds the menu's snapshot from the live state and hands it over.
    ///
    /// The learned-word banner is validated here on every refresh: a word
    /// removed from the settings window's list is the one removal path that
    /// cannot clear the banner itself, and without this check an open menu
    /// would keep rendering «Запомнено: … больше не станет …» for a word that
    /// is no longer excluded. A false drop cannot occur — the banner is only
    /// ever set for a word that is in the filter at that moment, and the
    /// menu's own `Убрать` path clears it itself.
    private func refreshStatusModel() {
        if let banner = learnedWordBanner, let engine,
            !engine.wordFilter.isExcluded(banner.prefix)
        {
            learnedWordBanner = nil
        }
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

    /// The menu checkbox, wired to the same store the general tab uses — one
    /// source of truth, one registration path. The store writes the LaunchAgent
    /// plist and rolls the flag back when it cannot; the menu only mirrors
    /// `state.launchAtLogin`, so a failed registration leaves the checkbox off.
    /// Before the engine exists (pre-grant) the store does not exist yet: the
    /// click is refused with a log line rather than persisting a flag that
    /// would make the checkbox lie.
    private func setLaunchAtLogin(_ enabled: Bool) {
        guard let store = settingsStore else {
            LogBuffer.shared.log(
                "Автозапуск станет доступен после получения прав Accessibility.",
                level: .warn)
            refreshStatusModel()
            return
        }
        store.launchAtLogin = enabled
        if let error = store.lastError {
            // The general tab shows this too; the menu is closed by the time
            // the write runs, so the log is the visible record here.
            LogBuffer.shared.log("Автозапуск: \(error)", level: .warn)
        }
        refreshStatusModel()
    }

    /// The `Настройки…` opener. The window edits the live word lists and hosts
    /// the general tab, so it needs the engine and the settings store — and
    /// both only exist once the grant has appeared; a click before that is a
    /// no-op, with the red status row already explaining why. The controller is
    /// created once and reused and `show()` lands on the default tab.
    private func openSettings() {
        makeSettingsWindowIfNeeded()?.show()
    }

    /// The `Журнал…` opener: the same window, opened on the log tab. The tab
    /// selection is the window's held model (`SettingsTabModel`), which the
    /// `TabView` binds to.
    private func openLog() {
        makeSettingsWindowIfNeeded()?.show(selecting: .log)
    }

    /// Builds the settings window on first use, against the engine and store
    /// that only exist post-grant; returns nil before that, which keeps both
    /// menu rows no-ops (the status row already explains why).
    private func makeSettingsWindowIfNeeded() -> SettingsWindowController? {
        guard let engine, let settingsStore else { return nil }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                engine: engine,
                state: state,
                store: settingsStore,
                onClose: { [weak self] in
                    self?.settingsWindowDidClose()
                })
        }
        return settingsWindow
    }

    /// Closing the settings window triggers a status refresh; the refresh
    /// itself drops the banner if its word was removed there.
    private func settingsWindowDidClose() {
        refreshStatusModel()
    }
}
