import AppKit
import Foundation
import RukeyCore

private nonisolated(unsafe) var sharedTapManager: EventTapManager?

@main
struct RukeyMain {
 static func main() {
  let args = CommandLine.arguments

  if args.contains("--help") || args.contains("-h") {
   printHelp()
   exit(0)
  }

  if args.contains("--check-permissions") {
   let trusted = EventTapManager.checkAccessibilityPermissions(prompt: false)
   print("Accessibility Trusted: \(trusted)")
   exit(trusted ? 0 : 1)
  }

  if args.contains("--test-conversion") {
   runSampleConversions()
   exit(0)
  }

  let verbose = args.contains("--verbose") || args.contains("-v")
  let excludeTerminalsFlag = args.contains("--exclude-terminals")

  var extraBundleIDs: [String] = []
  var i = 0
  while i < args.count {
    if args[i] == "--exclude-bundle", i + 1 < args.count {
      extraBundleIDs.append(args[i + 1])
      i += 2
    } else {
      i += 1
    }
  }

  let config = RukeyConfig.load(
    excludeTerminalsFlag: excludeTerminalsFlag,
    extraBundleIDs: extraBundleIDs,
    verbose: verbose
  )
  let excludeTerminals = config.excludeTerminals

  if !config.excludedBundleIDs.isEmpty {
    print("🛡️ Excluding \(config.excludedBundleIDs.count) bundle ID(s) from auto-switch.")
  }

  print("🚀 Starting Rukey Auto-Layout Daemon...")
  if excludeTerminals {
   print("🛡️ Terminal bypassing enabled.")
  } else {
   print("⌨️ Terminal auto-switch enabled (use --exclude-terminals to disable in terminals).")
  }

  // 1. Accessibility Check
  let isTrusted = EventTapManager.checkAccessibilityPermissions(prompt: true)
  if !isTrusted {
   print("⚠️ [Rukey] Accessibility permissions not granted.")
   print("👉 Please grant Accessibility permission in:")
   print("   System Settings -> Privacy & Security -> Accessibility")
   print("   Then restart Rukey.")
   exit(1)
  }

  // 2. Build the engine: dictionaries, detector, secure-input monitor and the
  // event tap. The tap is deliberately not started here.
  let engine: RukeyEngine
  do {
   engine = try RukeyEngine(config: config, verbose: verbose)
  } catch RukeyEngineError.emptyDictionary(let resource) {
   if resource == "words_en.txt" {
    print("❌ English dictionary is missing or empty (words_en: got 0 words). Check Resources/words_en.txt.")
   } else {
    print("❌ Russian dictionary is missing or empty (words_ru: got 0 words). Check Resources/words_ru.txt.")
   }
   exit(1)
  } catch {
   print("❌ Failed to initialize Rukey: \(error)")
   exit(1)
  }

  let tapManager = engine.tapManager
  let learningController = UndoLearningController(
   strikeStore: engine.strikeStore,
   wordFilter: engine.wordFilter,
   thresholdProvider: { config.autoLearnThreshold },
   notifyProvider: { config.notifyOnEveryUndo },
   configWriter: { words in
    var updated = config
    updated.excludedWords = words.sorted()
    RukeyConfig.write(updated, to: RukeyConfig.configFileURL, logBuffer: LogBuffer.shared)
   }
  )
  tapManager.onCorrection = { decision in
   print(
    "⚡ [Auto-Correct] '\(decision.originalText)' -> '\(decision.convertedText)' (\(decision.sourceLanguage.rawValue) -> \(decision.targetLanguage.rawValue), rule: \(decision.triggerRule))"
   )
   printLangState(tapManager.inputSourceManager)
  }
  tapManager.onOptionUndo = { from, restored in
   print("⌥ [Option] Undo: restored '\(restored)' with layout \(from.rawValue)")
   printLangState(tapManager.inputSourceManager)
   learningController.handleUndo(tapManager.undoManager.lastUndone)
  }

  tapManager.onOptionToggle = { from, to in
   print("⌥ [Option] Layout toggle: \(from.rawValue) -> \(to.rawValue)")
   printLangState(tapManager.inputSourceManager)
  }
  tapManager.onOptionIgnored = { reason in
   print("⌥ [Option] Ignored: \(reason)")
  }

  let started = tapManager.start()
  if !started {
   print("❌ Failed to start EventTap. Make sure Rukey has Accessibility permissions.")
   exit(1)
  }

  print("✨ Rukey is active and monitoring keyboard input.")
  print("💡 Examples: type 'руддщ' to get 'hello', or 'ghbdtn' to get 'привет'.")
  print("💡 Press Option (⌥) to toggle language or undo auto-correction.")
  print("💡 Delete (⌫) always deletes characters normally without rolling back.")
  print("Press Ctrl+C to stop.")

  // Handle clean termination: wake the main run loop so we can stop the tap cleanly.
  signal(SIGINT) { _ in
   CFRunLoopStop(CFRunLoopGetMain())
  }
  signal(SIGTERM) { _ in
   CFRunLoopStop(CFRunLoopGetMain())
  }

  sharedTapManager = tapManager

  // Run CFRunLoop
  CFRunLoopRun()

  sharedTapManager?.stop()
  sharedTapManager = nil
  print("\n👋 Rukey stopped. Goodbye!")
 }

 static func printHelp() {
  print(
   """
   Rukey - Automated On-The-Fly Keyboard Layout Switcher for macOS

   Usage:
     rukey                  Start background event tap listener
     rukey --exclude-terminals
                            Bypass auto-switch in Terminal, iTerm2, etc.
     rukey --exclude-bundle <id>
                            Bypass auto-switch in the given bundle ID (repeatable).
     rukey --verbose, -v     Enable verbose debug logging
     rukey --check-permissions
                            Check if accessibility privileges are granted
     rukey --test-conversion
                            Run offline conversion and detector sanity checks
     rukey --help, -h       Show this help message

   Config file:
     ~/.config/rukey/exclude.json
                            JSON with {"excludeBundleIDs": ["com.foo.app"]}
   """)
 }

 static func printLangState(_ manager: InputSourceManager) {
  let eff = manager.effectiveLanguage()
  let sys = manager.currentLanguage()
  print("    [Lang] effective=\(eff.rawValue) system=\(sys.rawValue)\(eff != sys ? " ⚠️MISMATCH" : "")")
 }

 static func runSampleConversions() {
  print("--- Testing Sample Conversions ---")
  let loader = DictionaryLoader.shared
  let enTrie = loader.loadTrie(fromResource: "words_en")
  let ruTrie = loader.loadTrie(fromResource: "words_ru")
  let detector = Detector(enTrie: enTrie, ruTrie: ruTrie, minPrefixLength: 3)

  let samples = [
   ("руддщ", Language.russian),
   ("ghbdtn", Language.english),
   ("ghbvth", Language.english),
   ("hello", Language.english),
   ("привет", Language.russian),
  ]

  for (word, lang) in samples {
   let decision = detector.evaluate(buffer: word, currentLanguage: lang)
   if let d = decision {
    print(
     "Input: '\(word)' [\(lang.rawValue)] -> Corrected to '\(d.convertedText)' [\(d.targetLanguage.rawValue)] (rule: \(d.triggerRule))"
    )
   } else {
    print("Input: '\(word)' [\(lang.rawValue)] -> Kept as is")
   }
  }
 }
}
