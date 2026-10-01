import Carbon.HIToolbox
import CoreGraphics
import Foundation
import RukeyCore

/// The live part: a session-level event tap that watches keyDown events, feeds characters
/// to `KeyboardEngine`, and performs the resulting edits.
///
/// Everything here runs on the main run loop, because a `CGEventTap` callback must return
/// promptly and the engine's work is small and synchronous.
///
/// Threading. The class is deliberately NOT actor-isolated. A `CGEventTapCallBack` is a C
/// function pointer: Swift 6 will not let it carry an actor-isolated reference, and
/// `CGEvent` is not `Sendable`, so routing the event through an isolation boundary fails to
/// compile at all. The tap is installed on the main run loop and CoreGraphics delivers tap
/// callbacks on the thread that created the tap, so in practice everything here touches one
/// thread. That invariant is enforced by `main.swift`, which only ever installs the tap and
/// services the run loop from `run()` on the main actor - not by the type system.
///
/// Re-entrancy: `engine.isBusy` is set while we post our own backspaces and inserts. Those
/// events come back through this same tap. Without the flag they would be read as the user
/// typing and we would erase the text we had just inserted. The flag is checked at the top
/// of the callback and every event we generate while it is set is passed straight through.
final class LiveCorrector {

    private var engine: KeyboardEngine
    private let rewriter = TextRewriter()
    private let tapLocation: CGEventTapLocation = .cghidEventTap
    private var tap: CFMachPort?

    /// Set by the tap callback; read on the main run loop for the status line.
    private(set) var lastEventSummary = "waiting for the first keystroke"

    init(detector: Detector, switcher: InputSourceSwitcher) {
        self.engine = KeyboardEngine(detector: detector, switcher: switcher)
    }

    /// Install the tap. Returns false if the process is not trusted for Accessibility, which
    /// is the only reason this can fail.
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        // The callback is a C function pointer, so it cannot capture state. `refcon` is how
        // the corrector gets back in: an unretained pointer, which is safe because `self`
        // outlives the tap - `stop()` in deinit removes it.
        //
        // `CGEvent` is not Sendable, so it must not cross the isolation boundary. Only the
        // type enum does; the event is unpacked inside `MainActor.assumeIsolated`, where it
        // never leaves the main actor. The assumption is that the callback runs on the run
        // loop that installed the tap, which is the main run loop in `run()`.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let corrector = Unmanaged<LiveCorrector>.fromOpaque(refcon).takeUnretainedValue()
            return corrector.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// Remove the tap. Called before the run loop stops, and from deinit; both run on the
    /// thread that installed the tap, which is where the run loop source lives.
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
    }

    /// Decide what to do with one event, and do it. Returns the event unchanged in every
    /// case: this program never swallows keystrokes, it only edits text around them.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disables a tap that blocks too long. Re-enable or die silently.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let isDelete = keyCode == 51 || keyCode == 117
            let flags = event.flags
            let isShift = flags.contains(.maskShift)

            // Only the unmodified delete undoes a correction. Shift-delete is a different
            // gesture (delete to end of line in most editors) and must be left alone.
            if isDelete && !isShift {
                apply(engine.type("\u{8}", layout: currentLayout()))
                return Unmanaged.passUnretained(event)
            }

            // Ignore our own generated events while an edit is in flight.
            guard !engine.isBusy else {
                return Unmanaged.passUnretained(event)
            }

            // Modifiers mean the user is doing something deliberate (a capital, a shortcut).
            // Never correct in that case: rewriting under a held Shift or Cmd is how you
            // produce text the user did not ask for.
            guard !flags.contains(.maskCommand), !flags.contains(.maskControl),
                  !flags.contains(.maskAlternate) else {
                return Unmanaged.passUnretained(event)
            }

            guard let character = character(from: event, keyCode: keyCode) else {
                return Unmanaged.passUnretained(event)
            }

            apply(engine.type(character, layout: currentLayout()))
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Perform an engine action against the real screen.
    private func apply(_ action: KeyboardEngine.Action) {
        switch action {
        case .none:
            return

        case .correct(let original, let replacement, let target):
            engine.isBusy = true
            lastEventSummary = "«\(original)» → «\(replacement)» (\(target.rawValue))"
            // Erase and insert are posted as one block with the tap muted, then the layout is
            // switched. The insert uses a Unicode string, so it lands correctly regardless of
            // which layout is active at that instant; switching afterwards means the next
            // physical key the user presses is decoded in the new layout.
            rewriter.replace(eraseCount: original.count, with: replacement, postingTo: tapLocation)
            engine.switcher.select(target)
            engine.isBusy = false

        case .undo(let eraseCount, let insertText, let target):
            engine.isBusy = true
            lastEventSummary = "undo → «\(insertText)» (\(target.rawValue))"
            rewriter.replace(eraseCount: eraseCount, with: insertText, postingTo: tapLocation)
            engine.switcher.select(target)
            engine.isBusy = false
        }
    }

    private func currentLayout() -> Language {
        engine.switcher.currentLanguage ?? .russian
    }

    /// Turn a keyDown event into the character it produced.
    ///
    /// Uses the event's own Unicode string where available, because that is already
    /// layout-correct - it is what the target application will receive. Falls back to the
    /// physical key when the event carries no text (modifier keys, dead keys, arrows).
    private func character(from event: CGEvent, keyCode: CGKeyCode) -> Character? {
        if let text = Self.typedText(of: event), let first = text.first {
            // Reject anything that is not a single character we care about: control
            // characters, and the private-use range some apps send for function keys.
            guard first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else {
                return nil
            }
            return first
        }

        // No text on the event: for the layouts we support, a printable letter always
        // carries text, so treat this as a key we ignore rather than guessing.
        _ = keyCode
        return nil
    }

    /// Read the text an event carries, using the SDK's exact signature:
    /// `keyboardGetUnicodeString(self:maxStringLength:actualStringLength:unicodeString:)`.
    /// There is no event field for "how long is the Unicode string" - the length is an
    /// out-parameter, so the max length has to be supplied and the real one comes back.
    private static func typedText(of event: CGEvent) -> String? {
        let capacity = 64
        var buffer = [UniChar](repeating: 0, count: capacity)
        var actualLength = 0
        event.keyboardGetUnicodeString(
            maxStringLength: capacity,
            actualStringLength: &actualLength,
            unicodeString: &buffer
        )
        guard actualLength > 0, actualLength <= capacity else { return nil }
        return String(utf16CodeUnits: buffer, count: actualLength)
    }

    deinit {
        stop()
    }
}