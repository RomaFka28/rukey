import AppKit

/// Longest rendered correction text, before the formatter cuts it and appends
/// `…` — the panel is 220pt wide, and 60 characters is the tested bound.
private let correctionFlashTextLimit = 60

/// The transient corner panel shown after an autocorrection.
///
/// One panel for the process lifetime: `show(_:)` reuses the same window,
/// re-anchors it 16pt from the top-right of the screen's visible frame, and
/// arms a one-shot timer that hides it again after `duration` — the same
/// block-Timer + `[weak self]` + `MainActor.assumeIsolated` pattern the
/// status item's icon flash already uses. A second correction while the panel
/// is up replaces the text and restarts the countdown; nothing is allocated
/// per correction.
///
/// The string is built by `text(original:converted:)` — the one formatter the
/// tests pin — and `show(_:)` takes an already-formatted string, so the panel
/// cannot re-implement (and drift from) the menu's last-correction row.
@MainActor
public final class CorrectionFlash {
    /// How long the panel stays on screen.
    static let duration: TimeInterval = 1.5

    /// `«original» → «converted»`, truncated to 60 characters with a trailing
    /// `…` when it does not fit; the whole text is kept when it does.
    public nonisolated static func text(original: String, converted: String) -> String {
        let full = "\(original) → \(converted)"
        guard full.count > correctionFlashTextLimit else { return full }
        return String(full.prefix(correctionFlashTextLimit - 1)) + "…"
    }

    private let panel: NSPanel
    private let label: NSTextField
    private var hideTimer: Timer?

    public init(size: CGSize = CGSize(width: 220, height: 54)) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // The panel must never take focus, outrank ordinary windows, hide on
        // a Space switch, or eat a click: it is a notification, not a control.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // A HUD-material background with rounded corners; a plain dark fill
        // would ignore the system's light/dark appearance.
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background

        self.panel = panel
        self.label = label
    }

    /// Shows `text` in the corner and (re)arms the auto-hide timer. Repeated
    /// corrections reuse the same panel: the text is replaced and the
    /// `duration` countdown starts over.
    public func show(_ text: String) {
        label.stringValue = text
        positionPanel()
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduleOnMain(interval: Self.duration) { [weak self] in
            self?.hide()
        }
    }

    /// Hides the panel and cancels a pending auto-hide.
    public func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }

    /// Re-anchors the panel 16pt from the top-right corner of the active
    /// screen's visible frame (the frame excludes the menu bar).
    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.maxX - size.width - 16,
                y: visible.maxY - size.height - 16))
    }
}
