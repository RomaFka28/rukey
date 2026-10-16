import AppKit
import RukeyCore
import SwiftUI

/// Owns the single settings window and the `Слова` tab's model.
///
/// One `NSWindow` for the whole app lifetime: it is built on first `show()`,
/// closed windows are reused (`isReleasedWhenClosed = false`), and the window
/// hosts the tabbed SwiftUI view through `NSHostingView`.
///
/// The word model's writer is the app's one `exclude.json` path: re-read the
/// file, merge the full new word set into that fresh copy, and persist it whole
/// with `RukeyConfig.write` — never a snapshot write — so a write from this
/// window cannot drop a field another editor (the learning controller, the
/// menu's `Убрать`) has just written. The live `SettingsState.excludedWords` is
/// updated in the same call, so no part of the GUI reads a stale word list.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let engine: RukeyEngine
    /// The GUI's live settings copy; the writer keeps its `excludedWords` in
    /// sync exactly like the learning controller's writer does.
    private let state: SettingsState
    private let onClose: (() -> Void)?

    /// Built once, on first use; `show()` reopens the same window afterwards.
    private var window: NSWindow?
    /// Retained (the view observes it) and exposed to nothing else.
    private var wordList: WordListModel?

    public init(engine: RukeyEngine, state: SettingsState, onClose: (() -> Void)?) {
        self.engine = engine
        self.state = state
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Rukey"
        // Closing must not deallocate the window: `show()` reopens this one.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(words: wordList))
        window.delegate = self
        window.center()

        self.wordList = wordList
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

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
