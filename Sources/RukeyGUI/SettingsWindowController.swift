import AppKit
import RukeyCore
import SwiftUI

/// Owns the single settings window and the tabs' models.
///
/// One `NSWindow` for the whole app lifetime: it is built on first `show()`,
/// closed windows are reused (`isReleasedWhenClosed = false`), and the window
/// hosts the tabbed SwiftUI view through `NSHostingView`.
///
/// Both tab writers use the app's one `exclude.json` path: re-read the file,
/// merge the changed field into that fresh copy, and persist the whole struct
/// with `RukeyConfig.write` — never a snapshot write — so a write from this
/// window cannot drop a field another editor (the learning controller, the
/// menu's `Убрать`) has just written. The live `SettingsState` is updated in
/// the same call, so no part of the GUI reads a stale settings copy.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let engine: RukeyEngine
    /// The GUI's live settings copy; the writers keep it in sync exactly like
    /// the learning controller's writer does.
    private let state: SettingsState
    /// The general tab's writer, owned by `AppDelegate` so the menu's
    /// launch-at-login checkbox and the tab share one registration path.
    private let store: SettingsStore
    private let onClose: (() -> Void)?

    /// Built once, on first use; `show()` reopens the same window afterwards.
    private var window: NSWindow?
    /// Retained (the view observes it) and exposed to nothing else.
    private var wordList: WordListModel?
    /// The applications tab's model, retained for the same reason.
    private var appList: AppListModel?

    public init(
        engine: RukeyEngine,
        state: SettingsState,
        store: SettingsStore,
        onClose: (() -> Void)?
    ) {
        self.engine = engine
        self.state = state
        self.store = store
        self.onClose = onClose
        super.init()
    }

    /// Shows the window, building it on first use.
    public func show() {
        if window == nil {
            buildWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        // The app is an accessory (`LSUIElement`): without explicit activation
        // the window would come up behind the frontmost application.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let wordList = WordListModel(
            filter: engine.wordFilter,
            dictionary: engine.customDictionary,
            strikeStore: engine.strikeStore,
            writer: { [weak self] words in
                self?.persistExcludedWords(words)
            })
        // The model mutates the live monitor itself (that is what applies an
        // exclusion without a relaunch); these writers persist the same values.
        let appList = AppListModel(
            monitor: engine.secureMonitor,
            picker: AppPicker(),
            excludeTerminals: state.excludeTerminals,
            writer: { [weak self] ids in
                self?.persistExcludedBundleIDs(ids)
            },
            terminalsWriter: { [weak self] enabled in
                self?.persistExcludeTerminals(enabled)
            })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Rukey"
        // Closing must not deallocate the window: `show()` reopens this one.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SettingsView(store: store, words: wordList, apps: appList))
        window.delegate = self
        window.center()

        self.wordList = wordList
        self.appList = appList
        self.window = window
    }

    /// Re-read, merge, write: the file may have been edited since the window's
    /// last action, so the new full word set is merged into a *fresh* copy of
    /// the config and the whole struct goes to the one writer. The live
    /// settings copy is updated in the same call.
    private func persistExcludedWords(_ words: Set<String>) {
        var current = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
        current.excludedWords = words.sorted()
        RukeyConfig.write(current, to: RukeyConfig.configFileURL)
        state.excludedWords = current.excludedWords
    }

    /// The applications tab's writer, with the same re-read-merge-write
    /// contract as `persistExcludedWords`. The live monitor was already
    /// updated by the model — that is what makes the exclusion apply to the
    /// next keystroke — so this only persists the full set and mirrors the
    /// fresh file into the live settings copy.
    private func persistExcludedBundleIDs(_ ids: Set<String>) {
        var current = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
        current.excludedBundleIDs = ids
        RukeyConfig.write(current, to: RukeyConfig.configFileURL)
        state.excludedBundleIDs = current.excludedBundleIDs
    }

    /// The terminal checkbox's writer: same path, one flag. The monitor itself
    /// is set by the model before this runs. The store is republished at the
    /// end too: the general tab binds through it, and without a change signal
    /// its body would keep showing the pre-toggle value.
    private func persistExcludeTerminals(_ enabled: Bool) {
        var current = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
        current.excludeTerminals = enabled
        RukeyConfig.write(current, to: RukeyConfig.configFileURL)
        state.excludeTerminals = current.excludeTerminals
        store.objectWillChange.send()
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
