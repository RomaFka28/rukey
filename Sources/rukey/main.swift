// rukey - corrects a word typed in the wrong keyboard layout, mid-word.
//
// Requires Accessibility ("Input Monitoring") permission: an event tap cannot be installed
// without it. Without permission the program exits with instructions rather than starting a
// tap that would silently never fire.

import ApplicationServices
import Carbon.HIToolbox
import Foundation
import RukeyCore

/// Arguments: an explicit dictionaries directory, or nothing to default to ./Resources/dict.
/// Flags such as --check are ignored here rather than mistaken for a path.
let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("-") }
let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }

let dictionariesDirectory = URL(fileURLWithPath: positional.first
    ?? FileManager.default.currentDirectoryPath + "/Resources/dict")
    .standardizedFileURL

func loadWords(_ language: String) throws -> DictionaryIndex {
    let url = dictionariesDirectory.appendingPathComponent("\(language).txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    return DictionaryIndex(words: text.split(separator: "\n").map(String.init))
}

// MARK: - Permission

/// Ask for Accessibility permission, showing the system prompt once.
///
/// The prompt option makes the OS offer to add the app in System Settings. This has to
/// happen before installing the tap, because tap creation fails silently - it returns nil -
/// when the process is untrusted.
///
/// The option key is spelled out rather than read from `kAXTrustedCheckOptionPrompt`:
/// that is an imported mutable global, and Swift 6 rejects reading it from any actor-isolated
/// context, including under `nonisolated(unsafe)`. `"AXTrustedCheckOptionPrompt"` is exactly
/// what the constant is defined as in ApplicationServices.
func ensureTrusted() -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) { return true }

    FileHandle.standardError.write(Data("""
        rukey needs Accessibility permission to watch the keyboard.

        Add it in System Settings → Privacy & Security → Input Monitoring, then run it
        again. If rukey is not in the list, choose "+" and point it at this binary:

          \(binaryPath)

        """.utf8))
    return false
}

/// The absolute path of this executable.
///
/// `Bundle.main.bundlePath` is wrong for a plain SwiftPM binary: it reports the containing
/// directory, and adding that directory to the Input Monitoring list grants nothing.
let binaryPath: String = {
    let argv0 = CommandLine.arguments.first ?? "rukey"
    if argv0.contains("/") {
        return URL(fileURLWithPath: argv0).resolvingSymlinksInPath().path
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(argv0).path
}()

// MARK: - Startup

@MainActor
func run() {
    guard ensureTrusted() else { exit(1) }

    let english: LanguageTable
    let russian: LanguageTable
    do {
        english = LanguageTable(
            language: .english,
            layout: try LayoutLoader.load(language: .english),
            dictionary: try loadWords("en")
        )
        russian = LanguageTable(
            language: .russian,
            layout: try LayoutLoader.load(language: .russian),
            dictionary: try loadWords("ru")
        )
    } catch {
        FileHandle.standardError.write(Data("rukey: \(error)\n".utf8))
        exit(1)
    }

    let switcher = InputSourceSwitcher()
    let detector = Detector(english: english, russian: russian)
    let corrector = LiveCorrector(detector: detector, switcher: switcher)

    guard corrector.start() else {
        FileHandle.standardError.write(Data("""
            rukey: could not install the event tap. This usually means permission was
            granted to a different build of the app. Check System Settings →
            Privacy & Security → Input Monitoring.

            """.utf8))
        exit(1)
    }

    print("rukey is running.")
    print("  dictionaries:  \(dictionariesDirectory.path)")
    print("  words:         en \(english.words.wordCount), ru \(russian.words.wordCount)")
    print("  threshold:     L=\(detector.minimumEvidence), rule: \(detector.rule)")
    print("  layout now:    \(switcher.currentID ?? "unknown")")
    print("")
    print("Type an English word while on the Russian layout (h e l l shows as рудд).")
    print("Press plain Delete right after a correction to take it back.")
    print("Ctrl-C to quit.")
    print("")

    if flags.contains("--check") {
        print("layout tables and dictionaries loaded; stopping before the tap.")
        corrector.stop()
        return
    }

    // Service the run loop: the event tap's run loop source delivers keys here.
    RunLoop.main.run()
}

run()