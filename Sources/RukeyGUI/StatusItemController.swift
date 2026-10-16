import AppKit
import RukeyCore

/// The last automatic correction, shaped for the "Последняя автозамена" row.
///
/// A GUI-local value rather than the engine's `CorrectionDecision`: the menu
/// needs two strings and nothing else, and the model stays constructible in a
/// test without a detector or a trie.
public struct CorrectionSummary: Equatable, Sendable {
    public let original: String
    public let converted: String

    public init(original: String, converted: String) {
        self.original = original
        self.converted = converted
    }
}

/// A word just added to the never-convert list, shaped for the banner row.
///
/// Built by the owner from `AppEventHub.lastLearned` — the same
/// `LearningNotice` the `Запомнено:` log line is built from, so the row and
/// the log can never disagree.
public struct LearnedWordBanner: Equatable, Sendable {
    public let prefix: String
    public let converted: String

    public init(prefix: String, converted: String) {
        self.prefix = prefix
        self.converted = converted
    }
}

/// Everything the status menu renders, as one comparable snapshot.
///
/// Plain data on purpose: menu construction must be testable without an
/// `NSStatusItem`. `AppDelegate` rebuilds the snapshot from the live state on
/// every relevant change and hands it to `StatusItemController.update(_:)`.
@MainActor
public struct StatusMenuModel: Equatable {
    /// The Accessibility gate's last word.
    public let permission: PermissionState
    /// Whether the tap is *actually running*: a grant whose `start()` failed
    /// must not read "Работает".
    public let running: Bool
    public let secureInputActive: Bool
    public let language: Language
    public let lastCorrection: CorrectionSummary?
    public let learningBanner: LearnedWordBanner?
    public let launchAtLogin: Bool
    /// The live app-exclusion snapshot, carried so the owner hands over one
    /// complete settings state; no row renders it yet.
    public let excludedBundleIDs: [String]

    public init(
        permission: PermissionState,
        running: Bool,
        secureInputActive: Bool,
        language: Language,
        lastCorrection: CorrectionSummary?,
        learningBanner: LearnedWordBanner?,
        launchAtLogin: Bool,
        excludedBundleIDs: [String]
    ) {
        self.permission = permission
        self.running = running
        self.secureInputActive = secureInputActive
        self.language = language
        self.lastCorrection = lastCorrection
        self.learningBanner = learningBanner
        self.launchAtLogin = launchAtLogin
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// The status row's text, in the exact strings of spec §8.1. A grant with a
    /// failed tap start reads "Не запущено" — the failure must be visible, not
    /// painted over as "Работает". Any non-granted gate state (including the
    /// pre-first-poll "unknown") reads "Нет прав Accessibility".
    public var statusTitle: String {
        guard permission == .granted else { return "Нет прав Accessibility" }
        guard running else { return "Не запущено" }
        guard !secureInputActive else { return "Приостановлено: защищённый ввод" }
        return "Работает"
    }

    /// The current layout row, e.g. `Текущая раскладка: RU`.
    public var layoutTitle: String {
        language == .russian ? "Текущая раскладка: RU" : "Текущая раскладка: EN"
    }

    /// The last correction row, e.g. `ghbdtn → привет`; `nil` until the first
    /// correction of the session. Long words are truncated by `prefix` plus `…`.
    public var lastCorrectionTitle: String? {
        lastCorrection.map { Self.truncated("\($0.original) → \($0.converted)") }
    }

    /// The learned-word banner row, exactly the `Запомнено:` line the engine
    /// logs: `Запомнено: ghb больше не станет при`.
    public var learningBannerTitle: String? {
        learningBanner.map { "Запомнено: \($0.prefix) больше не станет \($0.converted)" }
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > StatusItemController.menuTitleLimit else { return text }
        return String(text.prefix(StatusItemController.menuTitleLimit)) + "…"
    }
}

/// Owns the menu-bar `NSStatusItem`, its icon and its menu.
///
/// The controller renders; it does not decide. Every row comes from the
/// `StatusMenuModel` its owner last handed over, and the flash timing lives
/// here. The menu is rebuilt on every `update(_:)`, except while it is on
/// screen — a mutation then is deferred to `menuDidClose`, so a correction or
/// learned word arriving while the user has the menu open cannot corrupt it.
/// Immediately before display, `menuNeedsUpdate` asks the owner to refresh the
/// snapshot, which is how sampled states (Secure Input, the current layout)
/// stay fresh without polling.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    /// Longest prefix of a menu row's text before it is truncated with `…`.
    public static let menuTitleLimit = 40

    /// The alternate icon shown for a moment when a word is learned: the same
    /// bolt, outlined instead of filled, so the blink is unmistakable.
    public static func flashImage() -> NSImage {
        Icon.outlinedTemplateImage()
    }

    private let statusItem: NSStatusItem
    /// The window openers; `nil` keeps the row disabled until the window exists
    /// (the settings window arrives in Task 4).
    private let onOpenSettings: (() -> Void)?
    /// The pre-grant row's action: opens System Settings on the Accessibility
    /// pane the red status row names (Review Focus 1 / Task 8 row 3). Hidden
    /// when nil, same guard style as `onOpenSettings` below.
    private let onOpenAccessibility: (() -> Void)?
    private let onOpenLog: (() -> Void)?
    private let onToggleLaunchAtLogin: (Bool) -> Void
    private let onRemoveLearnedWord: (String) -> Void
    /// Asked right before the menu displays, so the owner can republish the
    /// snapshot from sampled state.
    private let onRefreshModel: (() -> Void)?

    /// The last model handed over — the menu's single source of truth.
    private var renderedModel: StatusMenuModel?
    /// Menu rebuilds must never mutate a menu that is on screen.
    private var isMenuOpen = false
    private var needsRebuild = false
    private var flashTimer: Timer?

    public init(
        onOpenSettings: (() -> Void)? = nil,
        onOpenAccessibility: (() -> Void)? = nil,
        onOpenLog: (() -> Void)? = nil,
        onToggleLaunchAtLogin: @escaping (Bool) -> Void = { _ in },
        onRemoveLearnedWord: @escaping (String) -> Void = { _ in },
        onRefreshModel: (() -> Void)? = nil
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenAccessibility = onOpenAccessibility
        self.onOpenLog = onOpenLog
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onRemoveLearnedWord = onRemoveLearnedWord
        self.onRefreshModel = onRefreshModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        // Every row's enabled state is set explicitly below; auto-validation
        // would also dim informational rows that carry a nil action.
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.image = Icon.templateImage()
    }

    /// Applies a new snapshot: rebuilds the menu, and blinks the icon when a
    /// learned word has just appeared.
    public func update(_ model: StatusMenuModel) {
        let previous = renderedModel
        guard model != previous else { return }
        renderedModel = model
        if isMenuOpen {
            needsRebuild = true
        } else {
            rebuildMenu()
        }
        if model.learningBanner != previous?.learningBanner, model.learningBanner != nil {
            flashIcon()
        }
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        onRefreshModel?()
        if needsRebuild {
            rebuildMenu()
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if needsRebuild {
            rebuildMenu()
        }
    }

    // MARK: - Menu construction

    /// Menu order is exactly the spec's: status (disabled), current layout, last
    /// correction, learned-word banner, separator, launch-at-login checkbox,
    /// `Настройки…`, `Журнал…`, separator, `Выйти`. While the grant is missing,
    /// an Accessibility opener follows the status row (Review Focus 1).
    private func rebuildMenu() {
        guard let model = renderedModel, let menu = statusItem.menu else { return }
        needsRebuild = false
        menu.removeAllItems()

        // Status: disabled informational row. Coloured so "red" and "green"
        // state reads at a glance even though the icon itself must stay a
        // black template image.
        let status = NSMenuItem(title: model.statusTitle, action: nil, keyEquivalent: "")
        status.attributedTitle = NSAttributedString(
            string: model.statusTitle,
            attributes: [.foregroundColor: Self.statusColor(for: model)])
        status.isEnabled = false
        menu.addItem(status)

        // Review Focus 1 / Task 8 row 3: while the grant is missing the settings
        // window cannot be built, so the menu itself must offer a working button
        // to the exact System Settings pane the red row names. Hidden when no
        // handler is wired, like `settings.isEnabled` below.
        if model.permission != .granted, onOpenAccessibility != nil {
            let accessibility = NSMenuItem(
                title: "Открыть настройки Accessibility",
                action: #selector(openAccessibility(_:)), keyEquivalent: "")
            accessibility.target = self
            accessibility.isEnabled = true
            menu.addItem(accessibility)
        }

        let layout = NSMenuItem(title: model.layoutTitle, action: nil, keyEquivalent: "")
        layout.isEnabled = false
        menu.addItem(layout)

        if let title = model.lastCorrectionTitle {
            let correction = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            correction.isEnabled = false
            menu.addItem(correction)
        }

        if let bannerTitle = model.learningBannerTitle, let banner = model.learningBanner {
            let item = NSMenuItem(title: bannerTitle, action: nil, keyEquivalent: "")
            let remove = NSMenuItem(
                title: "Убрать", action: #selector(removeLearnedWord(_:)), keyEquivalent: "")
            remove.target = self
            // Carried on the item so the action always removes exactly the word
            // the row was built for, even if a newer notice rebuilt the menu.
            remove.representedObject = banner.prefix
            let submenu = NSMenu()
            submenu.addItem(remove)
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Автозапуск при входе",
            action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = self
        launch.state = model.launchAtLogin ? .on : .off
        menu.addItem(launch)

        let settings = NSMenuItem(
            title: "Настройки…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        settings.isEnabled = onOpenSettings != nil
        menu.addItem(settings)

        let log = NSMenuItem(title: "Журнал…", action: #selector(openLog(_:)), keyEquivalent: "")
        log.target = self
        log.isEnabled = onOpenLog != nil
        menu.addItem(log)

        menu.addItem(.separator())

        // No target: the action travels the responder chain to `NSApp`, whose
        // delegate stops the tap in `applicationShouldTerminate` first.
        menu.addItem(
            NSMenuItem(
                title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func statusColor(for model: StatusMenuModel) -> NSColor {
        guard model.permission == .granted, model.running else { return .systemRed }
        return model.secureInputActive ? .systemOrange : .systemGreen
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        // Immediate feedback; the close-time rebuild below re-grounds the item
        // from the last model `update(_:)` validated, so a refused or
        // rolled-back toggle cannot stick.
        sender.state = enabled ? .on : .off
        onToggleLaunchAtLogin(enabled)
        // `update(_:)` early-returns when its model did not change — which is
        // exactly the refused-toggle and rolled-back cases — so the rebuild
        // has to be requested here, or the optimistic flip would never be
        // corrected on close.
        needsRebuild = true
    }

    @objc private func removeLearnedWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        onRemoveLearnedWord(word)
    }

    @objc private func openAccessibility(_ sender: NSMenuItem) {
        onOpenAccessibility?()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings?()
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        onOpenLog?()
    }

    // MARK: - Icon flash

    /// Swaps the icon for the flash variant for about a second.
    private func flashIcon() {
        statusItem.button?.image = Self.flashImage()
        flashTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            // Timers added to `RunLoop.main` fire on the main thread, same as
            // the permission gate's poll; the isolation is real.
            MainActor.assumeIsolated { self?.restoreIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func restoreIcon() {
        flashTimer = nil
        statusItem.button?.image = Icon.templateImage()
    }
}
