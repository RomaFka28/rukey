import Foundation

/// Reasons `RukeyEngine` refuses to build.
///
/// An empty shipped dictionary is the one failure the daemon cannot paper over:
/// a trie with no words silently converts nothing, so every keystroke would look
/// like a detector bug. `resource` carries the file name (`"words_en.txt"` /
/// `"words_ru.txt"`) so the entry point can print the same message it prints
/// today, in the same order.
public enum RukeyEngineError: Error, Equatable {
    case emptyDictionary(resource: String)
}

/// Builds every collaborator the daemon needs from one `RukeyConfig`, so the
/// CLI, the tests and (later) the GUI shell all construct the same wiring from
/// the same source of truth. This is the top of the dependency graph: nothing
/// here is reachable from the per-keystroke path except through the injected
/// instances, and every setting the user can change is read here exactly once
/// per build — a settings window updates the stored objects at runtime instead
/// of rebuilding tries.
///
/// Deliberately does **not** call `EventTapManager.start()`: the tap needs an
/// Accessibility grant and a run loop, and the entry point stays in charge of
/// when input starts being consumed.
///
/// `customDictionaryFileURL` and `strikeStoreFileURL` exist so tests never read
/// or write the real `~/.config/rukey`; production call sites omit both.
public struct RukeyEngine {
    public let detector: Detector
    public let wordFilter: WordFilter
    public let customDictionary: CustomDictionary
    public let undoManager: RukeyUndoManager
    public let strikeStore: StrikeStore
    public let secureMonitor: SecureInputMonitor
    public let tapManager: EventTapManager

    /// - Throws: `RukeyEngineError.emptyDictionary(resource:)` when a shipped
    ///   trie loads with zero words — English is checked first so the entry
    ///   point reports failures in the same order it always has.
    public init(
        config: RukeyConfig,
        verbose: Bool,
        customDictionaryFileURL: URL = CustomDictionary.defaultFileURL,
        strikeStoreFileURL: URL = StrikeStore.defaultFileURL
    ) throws {
        let wordFilter = WordFilter(words: Set(config.excludedWords))
        self.wordFilter = wordFilter

        // Reads `custom.json` itself; there is deliberately no `customWords` key
        // in `exclude.json`, so the taught words have exactly one home.
        let customDictionary = CustomDictionary(fileURL: customDictionaryFileURL)
        self.customDictionary = customDictionary

        let strikeStore = StrikeStore(fileURL: strikeStoreFileURL)
        self.strikeStore = strikeStore

        let loader = DictionaryLoader.shared
        let enTrie = loader.loadTrie(fromResource: "words_en")
        guard enTrie.wordCount > 0 else {
            throw RukeyEngineError.emptyDictionary(resource: "words_en.txt")
        }
        let ruTrie = loader.loadTrie(fromResource: "words_ru")
        guard ruTrie.wordCount > 0 else {
            throw RukeyEngineError.emptyDictionary(resource: "words_ru.txt")
        }

        // `minPrefixLength` comes from the config — a literal would pin the
        // short-word guard at 3 and make the setting inert. `minTargetCompletions`
        // keeps its default: it is not user-configurable.
        let detector = Detector(
            enTrie: enTrie,
            ruTrie: ruTrie,
            minPrefixLength: config.minPrefixLength,
            wordFilter: wordFilter,
            customDictionary: customDictionary
        )
        self.detector = detector

        let undoManager = RukeyUndoManager()
        self.undoManager = undoManager

        let secureMonitor = SecureInputMonitor(
            excludeTerminals: config.excludeTerminals,
            customExcludedBundleIDs: config.excludedBundleIDs
        )
        self.secureMonitor = secureMonitor

        let tapManager = EventTapManager(
            detector: detector,
            undoManager: undoManager,
            secureMonitor: secureMonitor
        )
        tapManager.logger = RukeyLogger(isVerbose: verbose)
        self.tapManager = tapManager
    }
}
