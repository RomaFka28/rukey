import AppKit
import CoreGraphics
import Foundation

public final class EventTapManager: @unchecked Sendable {
  let detector: Detector
  let fixEngine: FixEngine
  public let undoManager: RukeyUndoManager
  let secureMonitor: SecureInputMonitor
  public let inputSourceManager: InputSourceManager
  let bufferManager: BufferManager
  public var logger = RukeyLogger(isVerbose: false)

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var isRunning: Bool = false
  private var workspaceObserver: NSObjectProtocol?
  private var optionPressPending: Bool = false
  private var optionUsedInCombination: Bool = false
  public var onCorrection: ((CorrectionDecision) -> Void)?
  public var onOptionToggle: ((_ from: Language, _ to: Language) -> Void)?
  public var onOptionUndo: ((_ from: Language, _ restored: String) -> Void)?
  public var onOptionIgnored: ((_ reason: String) -> Void)?

  public init(
    detector: Detector,
    fixEngine: FixEngine = FixEngine(),
    undoManager: RukeyUndoManager = RukeyUndoManager(),
    secureMonitor: SecureInputMonitor = SecureInputMonitor.shared,
    inputSourceManager: InputSourceManager = InputSourceManager.shared
  ) {
    self.detector = detector
    self.fixEngine = fixEngine
    self.undoManager = undoManager
    self.secureMonitor = secureMonitor
    self.inputSourceManager = inputSourceManager
    self.bufferManager = BufferManager()
    self.workspaceObserver = NotificationCenter.default.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard let self else { return }
      var bundleID: String?
      if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        bundleID = app.bundleIdentifier
      } else if let app = notification.object as? NSRunningApplication {
        bundleID = app.bundleIdentifier
      } else {
        bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      }
      self.secureMonitor.noteFrontmostBundleID(bundleID)
      self.bufferManager.reset()
      self.undoManager.clear()
    }
  }

  deinit {
    if let observer = workspaceObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Verifies if accessibility permissions are granted.
  public static func checkAccessibilityPermissions(prompt: Bool = true) -> Bool {
    let promptKey = "AXTrustedCheckOptionPrompt" as CFString
    let options = [promptKey: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Starts the global event tap.
  public func start() -> Bool {
    guard !isRunning else { return true }

    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: TapPolicy.eventMask,
        callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
          guard let refcon = refcon else {
            return Unmanaged.passRetained(event)
          }
          let manager = Unmanaged<EventTapManager>.fromOpaque(refcon)
            .takeUnretainedValue()
          return manager.handleEvent(proxy: proxy, type: type, event: event)
        },
        userInfo: selfPtr
      )
    else {
      return false
    }

    self.eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    self.runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.isRunning = true

    return true
  }

  /// Stops the event tap and cleans up run loop sources.
  public func stop() {
    guard isRunning, let tap = eventTap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    self.eventTap = nil
    self.runLoopSource = nil
    self.isRunning = false
  }

  private func pass(_ event: CGEvent) -> Unmanaged<CGEvent>? {
    Unmanaged.passRetained(event)
  }

  // MARK: - Option (Alt) handling

  /// Returns non-nil only when the event was fully consumed (never for flagsChanged —
  /// swallowing Option keyDown desyncs the system modifier state and leaves Option stuck).
  private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) -> Unmanaged<CGEvent>? {
    guard keyCode == KeyCode.leftOption || keyCode == KeyCode.rightOption else {
      if optionPressPending {
        // A different modifier (Shift/Cmd/Ctrl/other Option) while Option is held
        // means an Option+modifier combination, not a tap.
        optionUsedInCombination = true
      }
      return nil // not consumed — caller passes through
    }
    if flags.contains(.maskAlternate) {
      // Option went down: remember it, act on keyUp so Option+key combos still type.
      if optionPressPending
        || flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift)
      {
        optionPressPending = true
        optionUsedInCombination = true
      } else {
        optionPressPending = true
        optionUsedInCombination = false
      }
    } else if optionPressPending, !optionUsedInCombination {
      handleOptionTap()
      optionPressPending = false
      optionUsedInCombination = false
    } else {
      onOptionIgnored?(optionUsedInCombination ? "option_used_in_combination" : "no_pending_press")
      optionPressPending = false
      optionUsedInCombination = false
    }
    return nil
  }

  private func handleOptionTap() {
    if undoManager.canUndo, let calculation = undoManager.calculateUndo() {
      fixEngine.executeUndo(
        currentReplacedCount: calculation.backspacesNeeded,
        originalText: calculation.textToRestore,
        originalLanguage: calculation.originalLanguage
      )
      // Screen now shows restored text; buffer must match or next detection
      // runs against a wrong buffer and corrections silently stop.
      bufferManager.replaceBuffer(with: calculation.textToRestore)
      onOptionUndo?(calculation.originalLanguage, calculation.textToRestore)
    } else if
      TapPolicy.shouldToggleLayoutOnOptionTap(
        isSecureInputActive: secureMonitor.isSecureInputActive())
    {
      let from = LayoutConverter.detectAlphabet(bufferManager.currentBuffer) ?? inputSourceManager.effectiveLanguage()
      let to = from.opposite
      guard inputSourceManager.apply(language: to) else {
        logger.error(
          "Не удалось переключить раскладку \(from.rawValue) -> \(to.rawValue).")
        onOptionIgnored?("input_source_switch_failed")
        bufferManager.reset()
        undoManager.clear()
        return
      }
      logger.info("Переключена раскладка \(from.rawValue) -> \(to.rawValue)")
      bufferManager.reset()
      undoManager.clear()
      onOptionToggle?(from, to)
    } else {
      // Secure Input is active: the toggle is refused, but the press is still
      // consumed as a deliberate Option tap and the half-typed buffer is not
      // worth keeping across the refusal.
      onOptionIgnored?("secure_input_active")
      bufferManager.reset()
    }
  }

  // MARK: - Word-boundary handling (shared by keycode + unicode-whitespace paths)

  /// Evaluates the buffer as a completed word and applies a correction if needed.
  /// - Returns: `true` when the triggering whitespace was already inserted as part
  ///   of `convertedText` (caller must swallow the event by returning nil).
  @discardableResult
  private func handleWordBoundary(typedWhitespace: String?) -> Bool {
    let currentBuffer = bufferManager.currentBuffer
    let currentLang = LayoutConverter.detectAlphabet(currentBuffer) ?? inputSourceManager.effectiveLanguage()
    guard let decision = detector.evaluateFullWord(buffer: currentBuffer, currentLanguage: currentLang) else {
      // No correction still invalidates pending undo — cursor sits past the word.
      undoManager.clear()
      bufferManager.reset()
      return false
    }
    if let ws = typedWhitespace {
      fixEngine.executeCorrection(
        backspacesToErase: decision.originalText.utf16EraseLength,
        convertedText: decision.convertedText + ws,
        targetLanguage: decision.targetLanguage
      )
      if ws == " " {
        undoManager.recordCorrection(decision, appendedTail: " ")
      } else {
        // Tab/newline move the cursor — undo across them corrupts text.
        undoManager.clear()
      }
      logger.info(
        "[Auto-Correct] '\(decision.originalText)' -> '\(decision.convertedText)' "
          + "(\(decision.sourceLanguage.rawValue) -> \(decision.targetLanguage.rawValue), "
          + "rule: \(decision.triggerRule))")
      onCorrection?(decision)
      bufferManager.reset()
      return ws == " "
    }
    // Triggered by Enter/Tab/Escape/arrows keycode (no text produced).
    fixEngine.executeCorrection(
      backspacesToErase: decision.originalText.utf16EraseLength,
      convertedText: decision.convertedText,
      targetLanguage: decision.targetLanguage
    )
    // Cursor moved — no undo across these keys.
    undoManager.clear()
    logger.info(
      "[Auto-Correct] '\(decision.originalText)' -> '\(decision.convertedText)' "
        + "(\(decision.sourceLanguage.rawValue) -> \(decision.targetLanguage.rawValue), "
        + "rule: \(decision.triggerRule))")
    onCorrection?(decision)
    bufferManager.reset()
    return false
  }

  private func handleWordBoundaryWithSpaceKeycode() -> Bool {
    handleWordBoundary(typedWhitespace: " ")
  }

  // MARK: - Unicode extraction

  private func extractTypedString(from event: CGEvent) -> String? {
    var length = 0
    event.keyboardGetUnicodeString(
      maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
    guard length > 0 else { return nil }
    var chars = [UniChar](repeating: 0, count: length)
    event.keyboardGetUnicodeString(
      maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return nil }
    return String(utf16CodeUnits: chars, count: length)
  }

  // MARK: - Core event handling

  /// Core event handling logic for intercepted keystrokes.
  func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<
    CGEvent
  >? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return pass(event)
    }
    // A click moves the caret, so a pending undo would restore text at the
    // wrong place: the click must disarm it. Same boundary as Escape/Enter.
    if TapPolicy.isUndoResettingEvent(type) {
      undoManager.clear()
      return pass(event)
    }
    // Filter out our own synthetic events (Backspace, Unicode strings)
    if event.getIntegerValueField(.eventSourceUserData) == DefaultSyntheticEventSender.magicEventUserData {
      return pass(event)
    }

    // If currently in the middle of executing a synthetic correction/undo, pass through
    if fixEngine.isFixing {
      return pass(event)
    }

    // Check Secure Input & app exclusions
    if secureMonitor.shouldBypassForActiveApplication() {
      bufferManager.reset()
      undoManager.clear()
      return pass(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    // Handle Option (Alt) key: toggle layout or undo last auto-correction.
    // NOTE: the event must NEVER be swallowed — returning nil for flagsChanged keyDown
    // while still delivering keyUp desynchronizes the system modifier state and
    // leaves Option stuck down for the rest of the session.
    if type == .flagsChanged {
      _ = handleFlagsChanged(keyCode: keyCode, flags: flags)
      return pass(event)
    }

    // Any real key pressed while Option is held makes this an Option+key combination
    // (e.g. ⌥e → é), not a deliberate Option tap.
    if optionPressPending && type == .keyDown && keyCode != KeyCode.leftOption && keyCode != KeyCode.rightOption {
      optionUsedInCombination = true
    }

    // Backspace/Delete (keycode 51): pure delete, never reverses auto-corrections.
    if keyCode == KeyCode.backspace {
      logger.debug("  [Del] buffer='\(bufferManager.currentBuffer)'")
      bufferManager.dropLast()
      undoManager.clear() // user is manually editing text
      return pass(event)
    }

    // Special modifiers: Cmd, Ctrl -> reset buffer
    if flags.contains(.maskCommand) || flags.contains(.maskControl) {
      bufferManager.reset()
      undoManager.clear()
      return pass(event)
    }

    // Boundary keys: Enter, Tab, Space, Escape, Arrows
    if KeyCode.wordBoundaries.contains(keyCode) {
      if keyCode == KeyCode.space {
        if handleWordBoundaryWithSpaceKeycode() { return nil }
        return pass(event)
      }
      _ = handleWordBoundary(typedWhitespace: nil)
      bufferManager.reset()
      return pass(event)
    }

    // Extract unicode characters from event
    guard let typedString = extractTypedString(from: event) else {
      return pass(event)
    }

    // Whitespace boundary delivered as text (Space, newline, tab via IME etc.)
    if typedString.contains(where: { $0.isWhitespace }) {
      // Only the first whitespace char splits the word; the rest is edge-case paste.
      if let ws = typedString.first(where: { $0.isWhitespace }).map(String.init) {
        let swallowed = handleWordBoundary(typedWhitespace: ws)
        // `handleWordBoundary` already inserted `convertedText + ws` when corrected;
        // otherwise the buffer was reset and the event passes through untouched.
        if swallowed { return nil }
        // Multi-char paste with whitespace: keep remainder out of scope — reset.
        bufferManager.reset()
        undoManager.clear()
        return pass(event)
      }
    }

    // Append every produced character to the buffer; multi-codepoint input
    // (IME, dead keys) must stay in sync with what reaches the screen.
    bufferManager.append(contentsOf: typedString)

    // Typing new characters after a correction extends the undo's erase tail.
    if undoManager.canUndo {
      undoManager.appendToTail(typedString)
    }
    // On-the-fly detection on current buffer
    let currentBuffer = bufferManager.currentBuffer
    let currentLang = LayoutConverter.detectAlphabet(currentBuffer) ?? inputSourceManager.effectiveLanguage()
    logger.debug("  [ETM] buffer='\(currentBuffer)' eff=\(currentLang.rawValue)")

    if let decision = detector.evaluate(buffer: currentBuffer, currentLanguage: currentLang) {
      // The whole typedString event is swallowed below, so those characters never
      // reached the screen. Only the run's earlier chars are currently on screen.
      let charsOnScreenToErase = max(0, decision.originalText.utf16EraseLength - typedString.utf16EraseLength)
      let untouchedPrefix = String(currentBuffer.dropLast(decision.originalText.count))
      fixEngine.executeCorrection(
        backspacesToErase: charsOnScreenToErase,
        convertedText: decision.convertedText,
        targetLanguage: decision.targetLanguage
      )

      undoManager.recordCorrection(decision)
      bufferManager.replaceBuffer(with: untouchedPrefix + decision.convertedText)
      logger.info(
        "[Auto-Correct] '\(decision.originalText)' -> '\(decision.convertedText)' "
          + "(\(decision.sourceLanguage.rawValue) -> \(decision.targetLanguage.rawValue), "
          + "rule: \(decision.triggerRule))")
      onCorrection?(decision)

      // Swallow the triggering key event because convertedText already includes it
      return nil
    }
    return pass(event)
  }
}
