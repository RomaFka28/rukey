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

    /// Every keystroke the tap sees, with what was decided about it. Without this, "the tap
    /// saw nothing" and "the tap saw it and dropped it" look identical from outside the
    /// process - which is exactly why the first live test produced no information at all.
    private let log: Log

    init(detector: Detector, switcher: InputSourceSwitcher,
         russianLayout: LayoutTable, englishLayout: LayoutTable, log: Log) {
        self.engine = KeyboardEngine(detector: detector, switcher: switcher,
                                     russianLayout: russianLayout, englishLayout: englishLayout)
        self.log = log
    }

    /// Install the tap. Returns false if the process is not trusted for Accessibility, which
    /// is the only reason this can fail.
    func start() -> Bool {
        // The mask MUST include the two "the system disabled you" types. A tap whose mask
        // omits them gets disabled without telling anyone, and then the program does nothing
        // forever with no error anywhere. That failure is indistinguishable from a broken
        // program, so it is logged explicitly when it happens.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        // The callback is a C function pointer, so it cannot capture state. `refcon` is how
        // the corrector gets back in: an unretained pointer, which is safe because `self`
        // outlives the tap - `stop()` in deinit removes it.
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
            log.write("tapCreate returned nil - the tap was NOT installed")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        log.write("tap installed on the session tap, watching keyDown")
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
            // The system disables a tap that blocks too long. Re-enable, and say so - a tap
            // that is disabled and silent looks exactly like a tap that never works.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.write("TAP DISABLED BY SYSTEM (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) - re-enabled")
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let isDelete = keyCode == 51 || keyCode == 117
            let isShift = flags.contains(.maskShift)
            let layout = currentLayout()

            // Only the unmodified delete undoes a correction. Shift-delete is a different
            // gesture (delete to end of line in most editors) and must be left alone.
            if isDelete && !isShift {
                let action = engine.type("\u{8}", layout: layout)
                log.write("DELETE -> \(describe(action))")
                apply(action)
                return Unmanaged.passUnretained(event)
            }

            // Ignore our own generated events while an edit is in flight.
            guard !engine.isBusy else {
                log.write("kc \(keyCode) dropped: busy with our own edit")
                return Unmanaged.passUnretained(event)
            }

            // Modifiers mean the user is doing something deliberate (a capital, a shortcut).
            // Never correct in that case: rewriting under a held Shift or Cmd is how you
            // produce text the user did not ask for.
            guard !flags.contains(.maskCommand), !flags.contains(.maskControl),
                  !flags.contains(.maskAlternate) else {
                log.write("kc \(keyCode) dropped: modifier held")
                return Unmanaged.passUnretained(event)
            }

            guard let character = character(from: event, keyCode: keyCode, layout: layout) else {
                log.write("kc \(keyCode) dropped: no character could be derived")
                return Unmanaged.passUnretained(event)
            }

            let action = engine.type(character, layout: layout)
            log.write("«\(character)» kc \(keyCode) [\(layout.rawValue)] buffer «\(engine.buffer)» -> \(describe(action))")
            apply(action)
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func describe(_ action: KeyboardEngine.Action) -> String {
        switch action {
        case .none:
            return "nothing"
        case .correct(let original, let replacement, let target):
            return "CORRECT «\(original)» -> «\(replacement)» [\(target.rawValue)]"
        case .undo(let eraseCount, let insert, let target):
            return "UNDO erase \(eraseCount) insert «\(insert)» [\(target.rawValue)]"
        }
    }

    /// Perform an engine action against the real screen.
    private func apply(_ action: KeyboardEngine.Action) {
        switch action {
        case .none:
            return

        case .correct(let original, let replacement, let target):
            engine.isBusy = true
            // Erase and insert are posted as one block with the tap muted, then the layout is
            // switched. The insert uses a Unicode string, so it lands correctly regardless of
            // which layout is active at that instant; switching afterwards means the next
            // physical key the user presses is decoded in the new layout.
            rewriter.replace(eraseCount: original.count, with: replacement, postingTo: tapLocation)
            let switched = engine.switcher.select(target)
            engine.isBusy = false
            log.write("  applied: erased \(original.count), inserted «\(replacement)», layout -> \(target.rawValue) ok=\(switched)")

        case .undo(let eraseCount, let insertText, let target):
            engine.isBusy = true
            rewriter.replace(eraseCount: eraseCount, with: insertText, postingTo: tapLocation)
            let switched = engine.switcher.select(target)
            engine.isBusy = false
            log.write("  applied undo: erased \(eraseCount), inserted «\(insertText)», layout -> \(target.rawValue) ok=\(switched)")
        }
    }

    private func currentLayout() -> Language {
        engine.switcher.currentLanguage ?? .russian
    }

    /// Turn a keyDown event into the character it produced.
    ///
    /// The event's own Unicode string is preferred: it is what the target application will
    /// receive, and it already accounts for Shift and dead keys.
    ///
    /// The fallback derives the character from the key code and the layout table we already
    /// read from the system. It exists because the Unicode string is not always present:
    /// when it comes back empty, the old code returned nil and the program did nothing at
    /// all, silently. That is exactly what the first live test did.
    ///
    /// Whitespace is deliberately NOT filtered out. The engine needs the space and the
    /// Return to know a word ended - it is what clears the buffer, releases the correction
    /// lock, and re-arms the undo. Dropping whitespace here made the buffer grow for the
    /// whole session ("nea78yfcnhjq" in the first live log) and no word could ever be
    /// finished. The engine treats these as signals and never tries to rewrite them.
    private func character(from event: CGEvent, keyCode: CGKeyCode, layout: Language) -> Character? {
        if let text = Self.typedText(of: event), let first = text.first {
            // Whitespace is kept on purpose: the space, Return and Tab are how the engine
            // learns a word ended. Dropping them left the buffer growing for the whole
            // session ("nea78yfcnhjq" in the first live log) and no word could ever finish.
            guard KeyText.isForwardable(first) else { return nil }
            return first
        }

        // No text on the event. The word-ending keys must still be reported, or the engine
        // never learns where a word ended.
        if let wordEnding = KeyText.wordEndingKeyCodes[keyCode] { return wordEnding }

        // Otherwise: the same layout table the correction is based on cannot disagree with
        // the dictionary check, so this is a safe source for the character.
        let table = layout == .russian ? engine.russianLayout : engine.englishLayout
        guard let produced = table.character(forKeyCode: keyCode) else { return nil }
        let shifted = event.flags.contains(.maskShift)
        let character = shifted ? Character(produced.uppercased()) : produced
        return KeyText.isForwardable(character) ? character : nil
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

/// Appends a running log to a file and to stdout.
///
/// Written synchronously and unbuffered on purpose. If the program is failing in a way that
/// only shows up while typing, the log has to survive being killed seconds later.
struct Log {
    private let handle: FileHandle?

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try? handle?.seekToEnd()
        write("--- rukey started, log at \(path) ---")
    }

    func write(_ line: String) {
        let stamped = "[\(Self.clock())] \(line)"
        if let data = (stamped + "\n").data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
        print(stamped)
        fflush(stdout)
    }

    static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}