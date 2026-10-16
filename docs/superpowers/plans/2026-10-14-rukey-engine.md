# Rukey Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a word exclusion filter, a learned custom dictionary, undo without a time limit, and undo-driven learning to the Rukey daemon, with a green test suite as the foundation.

**Architecture:** `RukeyCore` stays UI-free. New stores (`WordFilter`, `CustomDictionary`, `StrikeStore`, `LogBuffer`) are thread-safe classes holding their own state behind `NSLock`, and `Detector` receives them as injected dependencies so settings apply without a restart. `Detector` consults the exclusion filter at all three of its decision paths and the custom dictionary as an extra membership test. `RukeyUndoManager` drops its time gate entirely and instead accumulates a tail of characters typed after the correction.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftPM, XCTest via `swift test`, Foundation, AppKit/CoreGraphics only where the existing tap already uses them.

**Spec:** `docs/superpowers/specs/2026-10-14-rukey-gui-design.md` — sections 5, 6.1, 6.2, 6.3, 6.4, 7, 9.4, 10. The spec travels with this plan; read §6.1–6.3 before starting Task 5.

## Global Constraints

- Swift tools version 6.0, strict concurrency. Every new type crossing a concurrency boundary needs `Sendable` or `@unchecked Sendable` with a justifying comment.
- Deployment floor macOS 13.0.
- Dictionary cost stays at 1.2 µs per keystroke. Anything added to `Detector`'s decision path must be O(prefix length) or better — no linear scans over word lists.
- Every new store guards mutable state with `NSLock.withLock`, matching `Trie.swift:41` and `UndoManager.swift:45`. No new locking primitives.
- Never replace the Unicode string insert path in `FixEngine` with `Unikod`.
- Commits are English, imperative, one line of subject. Push to `origin/main` at the end of every task.
- Rollback point is `2b498f7`. Do not rewrite it.

## Review Focus

Five input classes the spec implies but does not spell out. Each is pinned by a test in the task that owns the code.

1. **Capitalized word at sentence start.** The user types `Ghbdtn` or `Hello`. Expectation: identical behaviour to lowercase, and a lowercase entry in the exclusion filter still blocks the capitalized form. Test in Task 1 (baseline) and Task 3 (filter).
2. **Hand-edited config with a syntax error.** Expectation: the daemon starts, runs on defaults, and the log names the file and the parse failure. Silent defaults alone would violate the spec's anti-goal 2. Test in Task 2.
3. **Cursor moved by a click inside the same window.** The user clicks into a different field of the same app — no app switch fires. Expectation: undo is unavailable, so `⌥` toggles the layout instead of erasing the wrong text. Test in Task 6.
4. **Two corrections inside one word.** An on-the-fly flip, then a boundary correction. Expectation: one `⌥` undoes only the latest, and the buffer matches what is on screen afterwards. Test in Task 5.
5. **Excluded word carrying punctuation.** The user types `ghbdtn!` or `,fu`. Expectation: blocked exactly like the bare word, because the run/core extraction strips edge punctuation before the exclusion check. Test in Task 3.

---

## File Structure

**Created in `Sources/RukeyCore/`:**

| File | Responsibility |
|---|---|
| `WordFilter.swift` | Exclusion set as a swappable `Trie`; prefix and exact membership questions |
| `CustomDictionary.swift` | User-taught words as a swappable `Trie`, persisted to `custom.json` |
| `StrikeStore.swift` | Undo counts per key, persisted to `learned.json` |
| `UndoLearningController.swift` | Turns undo counts into filter entries; owns the menu log lines |
| `TapPolicy.swift` | Pure decisions about the tap mask and undo resets, so they are testable |
| `LogBuffer.swift` | Ring buffer of timestamped log lines for the GUI's log pane |
| `AppEventHub.swift` | Single fan-out point translating engine callbacks into `AppEvent` values |

**Modified in `Sources/RukeyCore/`:**

| File | Change |
|---|---|
| `RukeyConfig.swift` | Widen the decoded schema; log parse failures instead of swallowing them |
| `Detector.swift` | Inject `WordFilter` and `CustomDictionary`; consult both at all three decision paths; lock-guarded `minPrefixLength` |
| `UndoManager.swift` | Remove the time gate and the injected clock; add `appendToTail` and the 64-character valve |
| `EventTapManager.swift` | Add `leftMouseDown` to the tap mask and clear undo on click; refuse `⌥` layout toggle under Secure Input; route typed characters into the undo tail |
| `SecureInputMonitor.swift` | Lock-guarded setters for `excludeTerminals` and `customExcludedBundleIDs`; expose `isSecureInputActive` |
| `KeyCodes.swift` | `RukeyLogger` gains `warn`/`error` and a buffer mirror |
| `DaemonBootstrap.swift` | Shared construction of the whole engine, used by both entry points |

**Created in `Tests/RukeyCoreTests/`:**

| File | Covers |
|---|---|
| `TestDictionaries.swift` | Shared inline word lists and `Trie` builders for tests |
| `TrieTests.swift` | Task 1 |
| `LayoutConverterTests.swift` | Task 1 |
| `DetectorTests.swift` | Task 2, re-extended in Tasks 3, 4, 5 |
| `UndoManagerTests.swift` | Task 2, rewritten in Task 5 |
| `RukeyConfigTests.swift` | Task 2 |
| `WordFilterTests.swift` | Task 3 |
| `EventTapPolicyTests.swift` | Task 6 |

**Modified:** `Package.swift` — add the `RukeyCoreTests` test target.

---

### Task 1: Green baseline for Trie and LayoutConverter

**Files:**
- Modify: `Package.swift` — add `.testTarget(name: "RukeyCoreTests", dependencies: ["RukeyCore"])`
- Create: `Tests/RukeyCoreTests/TestDictionaries.swift`
- Create: `Tests/RukeyCoreTests/TrieTests.swift`
- Create: `Tests/RukeyCoreTests/LayoutConverterTests.swift`

**Interfaces:**
- Consumes: nothing; this is the first task.
- Produces: `TestDictionaries.enTrie`, `TestDictionaries.ruTrie`, `TestDictionaries.makeTrie(_ words: [String]) -> Trie` — used by Tasks 2, 3, 4, 5. Small fixed English and Russian word lists (10–20 words each) covering both real conversions (`ghbdtn`→`привет`, `hello`→`руддщ`, `ntcn`→`тест`) and a junk-backed prefix that exercises `minTargetCompletions` (`beb` exists only behind `bebra`).

- [ ] **Step 1: Add the test target**

Add to `Package.swift` in the `targets:` array:

```swift
.testTarget(
    name: "RukeyCoreTests",
    dependencies: ["RukeyCore"]
),
```

- [ ] **Step 2: Create `Tests/RukeyCoreTests/TestDictionaries.swift`**

```swift
import Foundation
@testable import RukeyCore

enum TestDictionaries {
    static let englishWords = [
        "hello", "bebra", "bear", "beer", "beast", "best", "test", "text",
        "world", "work", "word", "привет", "ручка",
    ]
    static let russianWords = [
        "привет", "мир", "работа", "ручка", "текст", "тест", "мирный",
        "тестировать", "приветствие", "hello",
    ]
    static func makeTrie(_ words: [String]) -> Trie {
        let trie = Trie()
        trie.insert(contentsOf: words)
        return trie
    }
    static let enTrie = makeTrie(englishWords)
    static let ruTrie = makeTrie(russianWords)
}
```

- [ ] **Step 3: Write the failing Trie tests**

In `Tests/RukeyCoreTests/TrieTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class TrieTests: XCTestCase {
    func testInsertCountsWords() {
        let trie = TestDictionaries.makeTrie(["alpha", "beta", "alpha"])
        XCTAssertEqual(trie.wordCount, 2)
    }

    func testContainsExactWord() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.contains("ghbdtn"))
        XCTAssertFalse(trie.contains("ghbdt"))
    }

    func testContainsIsCaseInsensitive() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.contains("Ghbdtn"))
        XCTAssertTrue(trie.contains("GHBDTN"))
    }

    func testHasPrefixMatchesAnyPathInTheTrie() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.hasPrefix("ghb"))
        XCTAssertTrue(trie.hasPrefix("ghbdtn"))
        XCTAssertFalse(trie.hasPrefix("ghbdtx"))
    }

    func testHasPrefixIsCaseInsensitive() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertTrue(trie.hasPrefix("GHB"))
    }

    func testEmptyStringIsNeverAMember() {
        let trie = TestDictionaries.makeTrie(["ghbdtn"])
        XCTAssertFalse(trie.contains(""))
        XCTAssertFalse(trie.hasPrefix(""))
    }

    func testCountCompletionsStopsAtLimit() {
        let trie = TestDictionaries.makeTrie(["bear", "beast", "best", "beta"])
        XCTAssertEqual(trie.countCompletions(of: "be", limit: 3), 3)
        XCTAssertEqual(trie.countCompletions(of: "be", limit: 10), 4)
    }

    func testInsertOfEmptyStringIsIgnored() {
        let trie = Trie()
        trie.insert("")
        XCTAssertEqual(trie.wordCount, 0)
    }
}
```

- [ ] **Step 4: Write the failing LayoutConverter tests**

In `Tests/RukeyCoreTests/LayoutConverterTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class LayoutConverterTests: XCTestCase {
    func testMappingsAreInternallyConsistent() {
        XCTAssertTrue(LayoutConverter.validateMappings())
    }

    func testRoundTripProbes() {
        XCTAssertEqual(LayoutConverter.toRussian("ghbdtn"), "привет")
        XCTAssertEqual(LayoutConverter.toEnglish("привет"), "ghbdtn")
        XCTAssertEqual(LayoutConverter.toEnglish("руддщ"), "hello")
        XCTAssertEqual(LayoutConverter.toRussian("hello"), "руддщ")
    }

    func testConversionPreservesCapitalisation() {
        XCTAssertEqual(LayoutConverter.toRussian("Hello"), "Руддщ")
        XCTAssertEqual(LayoutConverter.toEnglish("Привет"), "Ghbdtn")
    }

    func testDetectAlphabetSeparatesScripts() {
        XCTAssertEqual(LayoutConverter.detectAlphabet("ghbdtn"), .english)
        XCTAssertEqual(LayoutConverter.detectAlphabet("привет"), .russian)
        XCTAssertNil(LayoutConverter.detectAlphabet("приветghbdtn"))
        XCTAssertNil(LayoutConverter.detectAlphabet("123"))
    }

    func testTrailingScriptRunDropsLeadingPunctuation() {
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: ",fu"), "fu")
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: "abc!def"), "def")
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: "123"), "")
    }

    func testTrailingScriptRunStopsAtAlphabetChange() {
        XCTAssertEqual(LayoutConverter.trailingScriptRun(of: "приветghb"), "ghb")
    }

    func testSplitEdgePunctuationSeparatesCore() {
        let parts = LayoutConverter.splitEdgePunctuation(",fu!")
        XCTAssertEqual(parts.leading, ",")
        XCTAssertEqual(parts.core, "fu")
        XCTAssertEqual(parts.trailing, "!")
    }
}
```

- [ ] **Step 5: Run the suite to see it fail**

Run: `swift test 2>&1 | tail -20`
Expected: FAIL — `RukeyCoreTests` target missing or errors on the missing file paths. The failure must be about the target, not about a hang.

- [ ] **Step 6: Make the tests pass**

No production code changes are needed; `Trie` and `LayoutConverter` already satisfy every assertion.

**Do not change the mapping tables to satisfy a test.** `LayoutConverter.validateMappings()` hard-codes the round-trip probes `ghbdtn`↔`привет` and `hello`↔`руддщ`, the console gate in `Sources/RukeyApp/main.swift` evaluates `руддщ`, and `Sources/RukeyMeasure` asserts the same pairs. The tables are the source of truth; if an assertion here disagrees with them, the assertion is what is wrong.

- [ ] **Step 7: Run the suite to see it pass**

Run: `swift test 2>&1 | tail -20`
Expected: PASS, every test green.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Tests/
git commit -m "Add test target and pin Trie and LayoutConverter behaviour"
git push
```

---

### Task 2: Baseline tests for Detector, UndoManager and config parsing

**Files:**
- Create: `Tests/RukeyCoreTests/DetectorTests.swift`
- Create: `Tests/RukeyCoreTests/UndoManagerTests.swift`
- Create: `Tests/RukeyCoreTests/RukeyConfigTests.swift`
- Modify: `Sources/RukeyCore/RukeyConfig.swift:16-58`

**Interfaces:**
- Consumes: `TestDictionaries.enTrie`, `TestDictionaries.ruTrie` from Task 1.
- Produces: `Detector(enTrie:ruTrie:minPrefixLength:minTargetCompletions:)` — unchanged in this task. Task 3 widens this initialiser.

- [ ] **Step 1: Write the failing Detector tests**

In `Tests/RukeyCoreTests/DetectorTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class DetectorTests: XCTestCase {
    private func makeDetector(
        minTargetCompletions: Int = 3,
        minPrefixLength: Int = 3
    ) -> Detector {
        Detector(
            enTrie: TestDictionaries.enTrie,
            ruTrie: TestDictionaries.ruTrie,
            minPrefixLength: minPrefixLength,
            minTargetCompletions: minTargetCompletions
        )
    }

    func testFullWordLatinTypingRussianLayoutConverts() {
        let decision = makeDetector().evaluateFullWord(
            buffer: "ghbdtn", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "привет")
        XCTAssertEqual(decision?.triggerRule, "full_word_en_to_ru")
    }

    func testFullWordRussianTypingLatinLayoutConverts() {
        let decision = makeDetector().evaluateFullWord(
            buffer: "руддщ", currentLanguage: .russian)
        XCTAssertEqual(decision?.convertedText, "hello")
        XCTAssertEqual(decision?.triggerRule, "full_word_ru_to_en")
    }

    func testValidWordIsLeftAlone() {
        XCTAssertNil(makeDetector().evaluateFullWord(buffer: "привет", currentLanguage: .russian))
    }

    func testCapitalisedWordBehavesLikeLowercase() {
        // Capitalisation is carried through the mapping table, not stripped:
        // "Ghbdtn" yields "Привет". Identical behaviour, capital P preserved.
        let decision = makeDetector().evaluateFullWord(
            buffer: "Ghbdtn", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "Привет")
        XCTAssertEqual(decision?.triggerRule, "full_word_en_to_ru")
    }

    func testJunkBackedPrefixDoesNotFlipOnTheFly() {
        // "bebra" sits alone behind the "beb" prefix, so with a high bar the
        // mid-word flip must not fire.
        XCTAssertNil(makeDetector(minTargetCompletions: 3).evaluate(
            buffer: "beb", currentLanguage: .english))
    }

    func testWellBackedPrefixFlipsOnTheFly() {
        // "ghb" -> "при": two dictionary entries sit behind "при"
        // (привет, приветствие), which clears the junk-backed-prefix bar.
        let decision = makeDetector(minTargetCompletions: 2).evaluate(
            buffer: "ghb", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "при")
        XCTAssertEqual(decision?.triggerRule, "en_invalid_prefix_ru_valid")
    }

    func testShortBufferIsIgnored() {
        XCTAssertNil(makeDetector().evaluate(buffer: "be", currentLanguage: .english))
    }

    func testPunctuatedTokenConvertsVerbatimEdges() {
        let decision = makeDetector().evaluateFullWord(
            buffer: "ghbdtn,", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "привет,")
    }

    func testTrailingPunctuationOnlyRunIsIgnored() {
        XCTAssertNil(makeDetector().evaluateFullWord(buffer: "hello!", currentLanguage: .english))
    }
}
```

- [ ] **Step 2: Write the failing UndoManager tests**

In `Tests/RukeyCoreTests/UndoManagerTests.swift`:

```swift
import Foundation
import XCTest
@testable import RukeyCore

final class UndoManagerTests: XCTestCase {
    private func decision(
        original: String = "ghb",
        converted: String = "при"
    ) -> CorrectionDecision {
        CorrectionDecision(
            originalText: original,
            convertedText: converted,
            sourceLanguage: .english,
            targetLanguage: .russian,
            triggerRule: "en_invalid_prefix_ru_valid"
        )
    }

    func testNothingToUndoBeforeAnyCorrection() {
        XCTAssertFalse(RukeyUndoManager().canUndo)
        XCTAssertNil(RukeyUndoManager().calculateUndo())
    }

    func testRecordedCorrectionIsUndoable() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        XCTAssertTrue(manager.canUndo)
        let calculation = manager.calculateUndo()
        XCTAssertEqual(calculation?.textToRestore, "ghb")
        XCTAssertEqual(calculation?.backspacesNeeded, 3)
        XCTAssertEqual(calculation?.originalLanguage, .english)
    }

    func testUndoIsConsumedOnce() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        XCTAssertNotNil(manager.calculateUndo())
        XCTAssertFalse(manager.canUndo)
        XCTAssertNil(manager.calculateUndo())
    }

    func testAppendedTailIsErasedToo() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision(), appendedTail: " ")
        let calculation = manager.calculateUndo()
        // "при" plus a space, all erased before "ghb" goes back.
        XCTAssertEqual(calculation?.backspacesNeeded, 4)
    }

    func testClearRemovesTheUndo() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.clear()
        XCTAssertFalse(manager.canUndo)
    }
}
```

- [ ] **Step 3: Write the config parsing tests, including the corrupt-file case**

In `Tests/RukeyCoreTests/RukeyConfigTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class RukeyConfigTests: XCTestCase {
    private func withTempHome(_ body: (URL) throws -> Void) rethrows {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    func testMergesFlagsWithFileBundleIDs() {
        let config = RukeyConfig.load(
            excludeTerminalsFlag: true,
            extraBundleIDs: ["com.example.fromFlag"],
            verbose: false,
            configFileURL: URL(fileURLWithPath: "/nonexistent/exclude.json")
        )
        XCTAssertTrue(config.excludeTerminals)
        XCTAssertEqual(config.excludedBundleIDs, ["com.example.fromFlag"])
    }

    func testFileAddsToFlagBundleIDs() {
        withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? "{ \"excludeBundleIDs\": [\"com.example.fromFile\"] }".write(
                to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: ["com.example.fromFlag"],
                verbose: false,
                configFileURL: url
            )
            XCTAssertEqual(
                config.excludedBundleIDs,
                ["com.example.fromFlag", "com.example.fromFile"])
        }
    }

    func testNewKeysFallBackToDefaults() {
        let config = RukeyConfig.load(
            excludeTerminalsFlag: false,
            extraBundleIDs: [],
            verbose: false,
            configFileURL: URL(fileURLWithPath: "/nonexistent/exclude.json")
        )
        XCTAssertEqual(config.autoLearnThreshold, 3)
        XCTAssertEqual(config.minPrefixLength, 3)
        XCTAssertTrue(config.notifyOnEveryUndo)
        XCTAssertTrue(config.showCorrectionFlash)
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertEqual(config.excludeTerminals, false)
        XCTAssertEqual(config.excludedWords, [])
    }

    func testValuesAreReadFromFile() {
        withTempHome { home in
            let url = home.appendingPathComponent("exclude.json")
            try? """
            {
              "excludeBundleIDs": ["com.example.app"],
              "excludedWords": ["ghbdtn", "иуикф"],
              "excludeTerminals": true,
              "autoLearnThreshold": 5,
              "notifyOnEveryUndo": false,
              "minPrefixLength": 4
            }
            """.write(to: url, atomically: true, encoding: .utf8)
            let config = RukeyConfig.load(
                excludeTerminalsFlag: false,
                extraBundleIDs: [],
                verbose: false,
                configFileURL: url
            )
            XCTAssertEqual(Set(config.excludedWords), ["ghbdtn", "иуикф"])
            XCTAssertEqual(config.excludeTerminals, true)
            XCTAssertEqual(config.autoLearnThreshold, 5)
            XCTAssertEqual(config.notifyOnEveryUndo, false)
            XCTAssertEqual(config.minPrefixLength, 4)
        }
    }
}
```

The corrupt-file case must also assert that the failure is reported. Add a capture buffer before Task 2 Step 4 and assert on it:

```swift
func testCorruptFileFallsBackAndReportsReason() {
    let buffer = LogBuffer()
    withTempHome { home in
        let url = home.appendingPathComponent("exclude.json")
        try? "{ not json at all ".write(to: url, atomically: true, encoding: .utf8)
        let config = RukeyConfig.load(
            excludeTerminalsFlag: false,
            extraBundleIDs: ["com.example.flag"],
            verbose: false,
            configFileURL: url,
            logBuffer: buffer
        )
        XCTAssertEqual(config.excludedBundleIDs, ["com.example.flag"])
        XCTAssertTrue(
            buffer.lines().contains { $0.level == .warn && $0.text.contains("exclude.json") },
            "a corrupt config must be reported, not silently swallowed")
    }
}
```

This is Review Focus item 2.

- [ ] **Step 4: Widen `RukeyConfig` to satisfy the tests**

In `Sources/RukeyCore/RukeyConfig.swift`:

- Add stored properties with these exact names and defaults: `excludedWords: [String]`, `excludeTerminals: Bool`, `launchAtLogin: Bool`, `autoLearnThreshold: Int`, `notifyOnEveryUndo: Bool`, `showCorrectionFlash: Bool`, `minPrefixLength: Int`. Defaults: empty array, `false`, `false`, `3`, `true`, `true`, `3`. **All of them `public var`** — Task 8's tests mutate `excludedWords` and `excludedBundleIDs` on a loaded config, so `let` will not compile there. User-taught words are **not** in this file — they live in `custom.json`, owned by Task 4.
- Change the private decoder shape to make every new key optional so an older file still decodes.
- Change `load(excludeTerminalsFlag:extraBundleIDs:verbose:)` to `load(excludeTerminalsFlag:extraBundleIDs:verbose:configFileURL:logBuffer:)` with both new parameters defaulted to `RukeyConfig.configFileURL` and `LogBuffer.shared`. The existing call in `Sources/RukeyApp/main.swift:42` must keep compiling.
- When decoding fails or the file is absent, do not change behaviour — keep the flag-only result — but append a `.warn` line to `logBuffer` naming the file URL and the failure. Absent file: no warning.

- [ ] **Step 5: Run the suite to see it fail**

Run: `swift test 2>&1 | tail -30`
Expected: FAIL — compile errors naming the new `RukeyConfig` members, the new `load` parameters and `LogBuffer`.

- [ ] **Step 6: Add the `LogBuffer` that the tests need**

Create `Sources/RukeyCore/LogBuffer.swift`:

```swift
public struct LogLine: Identifiable, Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case debug, info, warn, error
    }
    public let id: UUID
    public let date: Date
    public let level: Level
    public let text: String
}
```

`LogBuffer` is a `final class`, `@unchecked Sendable`, with a fixed-capacity ring (`init(capacity: Int = 500)`), a `shared` static, `append(_ line: LogLine)`, `lines() -> [LogLine]` returning oldest-first, and `clear()`. Guard the storage with `NSLock`. Provide a convenience `func log(_ text: String, level: LogLine.Level = .info)`.

- [ ] **Step 7: Run the suite to see it pass**

Run: `swift test 2>&1 | tail -30`
Expected: PASS, every test green.

- [ ] **Step 8: Commit**

```bash
git add Sources/RukeyCore/RukeyConfig.swift Sources/RukeyCore/LogBuffer.swift Tests/
git commit -m "Widen config schema and report parse failures instead of swallowing them"
git push
```

---

### Task 3: Word exclusion filter

**Files:**
- Create: `Sources/RukeyCore/WordFilter.swift`
- Modify: `Sources/RukeyCore/Detector.swift:25-121`
- Create: `Tests/RukeyCoreTests/WordFilterTests.swift`
- Modify: `Tests/RukeyCoreTests/DetectorTests.swift`

**Interfaces:**
- Consumes: `TestDictionaries`, `Trie`.
- Produces:

```swift
public final class WordFilter: @unchecked Sendable {
    public init(words: Set<String> = [])
    public var words: Set<String> { get }
    public var isEmpty: Bool { get }
    public func replaceAll(with words: Set<String>)
    public func isExcluded(_ word: String) -> Bool
    public func isPrefixOfExcluded(_ candidate: String) -> Bool
}
```

- [ ] **Step 1: Write the failing WordFilter tests**

In `Tests/RukeyCoreTests/WordFilterTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class WordFilterTests: XCTestCase {
    func testEmptyFilterExcludesNothing() {
        let filter = WordFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertFalse(filter.isExcluded("ghbdtn"))
        XCTAssertFalse(filter.isPrefixOfExcluded("ghb"))
    }

    func testExactMembership() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isExcluded("ghbdtn"))
        XCTAssertFalse(filter.isExcluded("ghbdt"))
    }

    func testExactMembershipIgnoresCase() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isExcluded("Ghbdtn"))
        XCTAssertTrue(filter.isExcluded("GHBDTN"))
    }

    func testPrefixMembershipCoversEveryShorterRun() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isPrefixOfExcluded("g"))
        XCTAssertTrue(filter.isPrefixOfExcluded("ghb"))
        XCTAssertTrue(filter.isPrefixOfExcluded("ghbdt"))
        XCTAssertTrue(filter.isPrefixOfExcluded("ghbdtn"))
        XCTAssertFalse(filter.isPrefixOfExcluded("ghbdtx"))
    }

    func testPrefixMembershipIgnoresCase() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertTrue(filter.isPrefixOfExcluded("GHB"))
    }

    func testBlankWordsAreIgnored() {
        let filter = WordFilter(words: ["", "   "])
        XCTAssertTrue(filter.isEmpty)
        // `isEmpty` reads only the word set; this pins that the blanks never
        // reached the trie either, or " " would be a live prefix key.
        XCTAssertFalse(filter.isPrefixOfExcluded(" "))
        XCTAssertFalse(filter.isPrefixOfExcluded(""))
    }

    func testReplaceAllSwapsTheWholeSet() {
        let filter = WordFilter(words: ["ghbdtn"])
        filter.replaceAll(with: ["hello"])
        XCTAssertEqual(filter.words, ["hello"])
        XCTAssertFalse(filter.isExcluded("ghbdtn"))
        XCTAssertTrue(filter.isExcluded("hello"))
    }

    func testBlankWordIsNotAPrefixOfAnything() {
        let filter = WordFilter(words: ["ghbdtn"])
        XCTAssertFalse(filter.isPrefixOfExcluded(""))
    }
}
```

- [ ] **Step 2: Write the failing Detector tests for the filter**

Append to `Tests/RukeyCoreTests/DetectorTests.swift`:

```swift
    // MARK: - Word filter

    private func makeFilteredDetector(
        excluding words: Set<String>
    ) -> (Detector, WordFilter) {
        let filter = WordFilter(words: words)
        let detector = Detector(
            enTrie: TestDictionaries.enTrie,
            ruTrie: TestDictionaries.ruTrie,
            minPrefixLength: 3,
            minTargetCompletions: 2,
            wordFilter: filter
        )
        return (detector, filter)
    }

    func testExcludedFullWordIsNotConverted() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
    }

    func testExcludedWordStopsTheMidWordFlip() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluate(buffer: "ghb", currentLanguage: .english))
    }

    func testCapitalisedExcludedWordIsStillExcluded() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "Ghbdtn", currentLanguage: .english))
    }

    func testExclusionIsPerInputNotPerResult() {
        // "привет" is in the filter only as the Russian spelling, so the Latin
        // typing that produces it is unaffected.
        let (detector, _) = makeFilteredDetector(excluding: ["привет"])
        let decision = detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english)
        XCTAssertEqual(decision?.convertedText, "привет")
    }

    func testUnrelatedWordsKeepConverting() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
        // "ntcn" is the Latin typing of "тест"; excluding "ghbdtn" must not stop it.
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ntcn", currentLanguage: .english)?.convertedText,
            "тест")
    }

    func testPunctuatedExcludedWordIsBlockedLikeTheBareWord() {
        let (detector, _) = makeFilteredDetector(excluding: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn,", currentLanguage: .english))
        XCTAssertNil(detector.evaluateFullWord(buffer: ",ghbdtn", currentLanguage: .english))
    }

    func testExcludedPrefixIsBlockedOnThePunctuatedPathToo() {
        // "ntcnbhjdfnm" is the Latin typing of "тестировать" and "ntcn" is a prefix
        // of it — the Latin typing of "тест", which IS in the dictionary. Excluding
        // the longer word must not let its prefix convert on the punctuated path,
        // where the check has to be a prefix test, not an exact one.
        let (detector, _) = makeFilteredDetector(excluding: ["ntcnbhjdfnm"])
        XCTAssertNil(detector.evaluate(buffer: "ntcn", currentLanguage: .english))
        XCTAssertNil(detector.evaluateFullWord(buffer: "ntcn,", currentLanguage: .english))
        XCTAssertNil(detector.evaluateFullWord(buffer: ",ntcn", currentLanguage: .english))
    }

    func testEmptyFilterLeavesEveryBehaviourUnchanged() {
        let (detector, _) = makeFilteredDetector(excluding: [])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english)?.convertedText,
            "привет")
    }

    func testFilterSwappedAtRuntimeTakesEffectImmediately() {
        let (detector, filter) = makeFilteredDetector(excluding: [])
        XCTAssertNotNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
        filter.replaceAll(with: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
    }
```

`testExclusionIsPerInputNotPerResult`, `testPunctuatedExcludedWordIsBlockedLikeTheBareWord` and `testExcludedPrefixIsBlockedOnThePunctuatedPathToo` pin Review Focus items 5 and the input-side semantics from spec §6.1.

- [ ] **Step 3: Run the tests to see them fail**

Run: `swift test --filter 'WordFilterTests|DetectorTests' 2>&1 | tail -30`
Expected: FAIL — `cannot find 'WordFilter' in scope` and no `wordFilter:` argument on `Detector.init`.

- [ ] **Step 4: Implement `WordFilter`**

Create `Sources/RukeyCore/WordFilter.swift`. Hold `private var current: Trie` plus an `NSLock`. On every query, read the current `Trie` reference under the lock, then call `contains` / `hasPrefix` on it — those take their own lock, so do not nest. `replaceAll(with:)` builds a fresh `Trie` with `insert(contentsOf:)` and swaps the reference under the lock; readers never see a partially built trie. Normalise each incoming word with `trimmingCharacters(in: .whitespacesAndNewlines)` and drop the result when it is empty, so `testBlankWordsAreIgnored` passes.

- [ ] **Step 5: Wire the filter into all three Detector paths**

In `Sources/RukeyCore/Detector.swift`:

- Add a stored property `public let wordFilter: WordFilter` and a parameter `wordFilter: WordFilter = WordFilter()` on `init`, placed after `minTargetCompletions`.
- In `decisionIfMistyped(word:bufferLang:fullWord:)` (`Detector.swift:51`), return `nil` when `wordFilter.isPrefixOfExcluded(word)`. This covers both the on-the-fly and the boundary run paths in one place, and it is checked before any trie work so the filter costs nothing extra on a hit.
- In `decisionForPunctuatedToken(in:)` (`Detector.swift:131`), return `nil` when `wordFilter.isPrefixOfExcluded(core)` — the extracted core, not the raw token, so edge punctuation does not defeat the filter, and a **prefix** test rather than an exact one, so this path agrees with `decisionIfMistyped` on the same typing. `hasPrefix` is a superset of `contains`, so the tightening cannot block anything that converts today without a filter installed.

Do not add the check to `candidateWord(from:minLength:)`; `evaluate` and `evaluateFullWord` both pass the same `word` to `decisionIfMistyped` and must behave identically.

- [ ] **Step 6: Run the tests to see them pass**

Run: `swift test --filter 'WordFilterTests|DetectorTests' 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `swift test 2>&1 | tail -20`
Expected: PASS. No baseline test from Task 2 may regress.

- [ ] **Step 8: Commit**

```bash
git add Sources/RukeyCore/WordFilter.swift Sources/RukeyCore/Detector.swift Tests/
git commit -m "Block excluded words from the first keystroke in every detector path"
git push
```

---

### Task 4: Custom dictionary

**Files:**
- Create: `Sources/RukeyCore/CustomDictionary.swift`
- Modify: `Sources/RukeyCore/Detector.swift:35-88`
- Modify: `Tests/RukeyCoreTests/DetectorTests.swift`

**Interfaces:**
- Consumes: `Trie`, `TestDictionaries`.
- Produces:

```swift
public final class CustomDictionary: @unchecked Sendable {
    public static let defaultFileURL: URL   // ~/.config/rukey/custom.json
    public init(
        fileURL: URL = CustomDictionary.defaultFileURL,
        words: Set<String> = [],
        logBuffer: LogBuffer = .shared
    )
    public var words: Set<String> { get }
    public func replaceAll(with words: Set<String>)
    public func contains(_ word: String) -> Bool
    public func isPrefixOfKnown(_ candidate: String) -> Bool
}
```

`Detector` gains `public let customDictionary: CustomDictionary` — it is part of this task's produced surface, because Task 8's bootstrap and the GUI plan both construct the detector around it.

`replaceAll` persists to `custom.json` under the lock as `{"words": [...]}`, sorted so the file does not churn. A missing file starts empty and silent; a corrupt one logs a `.warn` and starts empty. `init` is the only reader.

- [ ] **Step 1: Write the failing Detector tests**

Append to `Tests/RukeyCoreTests/DetectorTests.swift`:

```swift
    // MARK: - Custom dictionary

    private func makeTaughtDetector(words: Set<String>) -> (Detector, CustomDictionary) {
        // A per-test temporary file: `replaceAll` writes to disk, and tests must
        // never touch the real ~/.config/rukey/custom.json.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString).json")
        let dictionary = CustomDictionary(fileURL: url, words: words)
        let detector = Detector(
            enTrie: TestDictionaries.enTrie,
            ruTrie: TestDictionaries.ruTrie,
            minPrefixLength: 3,
            minTargetCompletions: 2,
            customDictionary: dictionary
        )
        return (detector, dictionary)
    }

    func testTaughtWordConvertsAtWordBoundary() {
        // "заозкздзаоз" is exactly what "pfjprplpfjp" spells. The word must be
        // comma-free: `б` sits on the comma key, so a word containing it types
        // with an interior comma, which splits the script run and yields nil.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        let decision = detector.evaluateFullWord(
            buffer: "pfjprplpfjp", currentLanguage: .russian)
        XCTAssertEqual(decision?.convertedText, "заозкздзаоз")
    }

    func testTaughtWordAlsoEnablesTheMidWordFlip() {
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        // Flipping at "pfj" is better UX than waiting for the boundary: the
        // remaining keys then spell "зкздзаоз" in the target layout and the
        // whole word lands correctly either way.
        XCTAssertEqual(detector.evaluate(buffer: "pfj", currentLanguage: .russian)?.convertedText, "зао")
    }

    func testTaughtWordIsNotConvertedBack() {
        // A word the user taught in Russian must survive being read as English.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        XCTAssertNil(detector.evaluateFullWord(
            buffer: "заозкздзаоз", currentLanguage: .russian))
    }

    func testTaughtWordIsNotConvertedBackEvenWhenItsLatinFormIsReal() {
        // The discriminating fixture for the *current*-side widening: "руддщ"
        // spells "hello", a real English dictionary word, so without
        // `isCurrentValid` widening the classic flip fires and returns hello.
        // With it, the taught word wins. The заозкздзаоз pair cannot show this —
        // there the converted side is not a word at all, so the branch is
        // unreachable either way and the mutation survives.
        let (detector, _) = makeTaughtDetector(words: ["руддщ"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "руддщ", currentLanguage: .russian))
        // Positive control: without the taught word the very same pair converts,
        // so the nil above cannot be a dead path.
        let (control, _) = makeTaughtDetector(words: [])
        XCTAssertEqual(
            control.evaluateFullWord(buffer: "руддщ", currentLanguage: .russian)?.convertedText,
            "hello")
    }

    func testTaughtWordDoesNotLicenseReverseConversion() {
        // Teaching a word teaches what may be typed, not what it may become:
        // the taught Russian word is never itself flipped into Latin.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        XCTAssertFalse(
            detector.customDictionary.contains("pfjprplpfjp"),
            "the Latin form must not be taught implicitly")
        XCTAssertNil(detector.evaluateFullWord(
            buffer: "заозкздзаоз", currentLanguage: .russian))
    }

    func testCustomDictionarySwappedAtRuntimeTakesEffectImmediately() {
        let (detector, dictionary) = makeTaughtDetector(words: [])
        XCTAssertNil(detector.evaluateFullWord(
            buffer: "pfjprplpfjp", currentLanguage: .russian))
        dictionary.replaceAll(with: ["заозкздзаоз"])
        XCTAssertNotNil(detector.evaluateFullWord(
            buffer: "pfjprplpfjp", currentLanguage: .russian))
    }

    func testCustomDictionaryPersistsToCustomJSON() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString).json")
        let dictionary = CustomDictionary(fileURL: url)
        dictionary.replaceAll(with: ["заозкздзаоз"])
        let reloaded = CustomDictionary(fileURL: url)
        XCTAssertTrue(reloaded.contains("заозкздзаоз"))
    }

    func testCorruptCustomFileStartsEmptyAndReports() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-\(UUID().uuidString).json")
        try? "{ broken".write(to: url, atomically: true, encoding: .utf8)
        let buffer = LogBuffer()
        let dictionary = CustomDictionary(fileURL: url, logBuffer: buffer)
        XCTAssertFalse(dictionary.contains("заозкздзаоз"))
        XCTAssertTrue(buffer.lines().contains { $0.level == .warn })
    }

    func testEmptyCustomDictionaryPreservesBaselineDecision() {
        let baseline = makeDetector().evaluateFullWord(
            buffer: "ghbdtn", currentLanguage: .english)
        let (detector, _) = makeTaughtDetector(words: [])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english),
            baseline)
    }

    // MARK: - The custom dictionary on the punctuated path

    func testTaughtWordWithEdgePunctuationIsNotFlipped() {
        // The punctuated path is the third decision site and must consult the
        // custom dictionary exactly as the other two do. Without the widening this
        // exact case returned `привет!` while `ghbdtn` alone returned nil.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn!", currentLanguage: .english))
        // Control: with nothing taught the very same token really does convert, so
        // the nil above cannot be a dead path.
        let (control, _) = makeTaughtDetector(words: [])
        XCTAssertEqual(
            control.evaluateFullWord(buffer: "ghbdtn!", currentLanguage: .english)?.convertedText,
            "привет!")
    }

    func testTaughtWordConvertsWithEdgePunctuation() {
        // The converse direction: teaching `заозкздзаоз` lets its Latin typing
        // convert, and that must keep working when the token carries punctuation —
        // otherwise the taught word would land only sometimes.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз"])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "pfjprplpfjp,", currentLanguage: .english)?
                .convertedText,
            "заозкздзаоз,")
    }

    func testTaughtWordPrefixIsNotProtectedOnEitherPath() {
        // A longer taught word does not promote its own prefix to a word of its
        // own. The boundary path and the punctuated path must agree, exactly as
        // they do for the bare form; protecting a prefix on one path but not the
        // other is the shape of defect Review Focus #5 exists to prevent. This is
        // why the punctuated path takes `contains`, not `isPrefixOfKnown`.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtnabc"])
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english)?.convertedText,
            "привет")
        XCTAssertEqual(
            detector.evaluateFullWord(buffer: "ghbdtn!", currentLanguage: .english)?.convertedText,
            "привет!")
    }

    // MARK: - Pinning the widened arms

    func testTaughtRussianPrefixIsNotFlippedIntoLatinMidWord() {
        // Pins the Russian branch's `isCurrentValid` widening. The Latin form is
        // taught too, so the flip branch is reachable: only that widening stands
        // between the taught word's prefix and a mid-word flip into Latin.
        let (detector, _) = makeTaughtDetector(words: ["заозкздзаоз", "pfjhello"])
        XCTAssertNil(detector.evaluate(buffer: "зао", currentLanguage: .russian))
    }

    func testTaughtLatinWordConvertsFromItsCyrillicKeystrokesMidWord() {
        // Pins the Russian branch's `isConvertedValid` widening *and* its junk-gate
        // waiver at once: `чндщзр` spells `xyloph`, which starts no `enTrie` word
        // (`countCompletions == 0`), so the gate would block a flip the waiver must
        // let through.
        let (detector, _) = makeTaughtDetector(words: ["xylophone"])
        XCTAssertEqual(
            detector.evaluate(buffer: "чндщзр", currentLanguage: .russian)?.convertedText,
            "xyloph")
    }

    func testTaughtLatinWordIsNotFlippedBackMidWord() {
        // Pins the English branch's on-the-fly `isCurrentValid` widening. `привет`
        // clears the junk bar and `ghbdtn` starts no `enTrie` word, so nothing but
        // the widening can make the taught word valid here.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtnabc"])
        XCTAssertNil(detector.evaluate(buffer: "ghbdtn", currentLanguage: .english))
    }

    func testTaughtLatinWordSurvivesAtTheWordBoundary() {
        // Pins the English branch's `fullWord` `isCurrentValid` widening, the
        // mirror of the Russian `руддщ` boundary case: `ghbdtn` is not in
        // `enTrie`, so nothing but the widening makes the taught word valid at the
        // boundary — without it the flip fires and returns `привет`.
        let (detector, _) = makeTaughtDetector(words: ["ghbdtn"])
        XCTAssertNil(detector.evaluateFullWord(buffer: "ghbdtn", currentLanguage: .english))
    }

    // MARK: - Persistence behaviours worth a pin

    func testPersistCreatesTheConfigDirectory() {
        // A fresh install has no `~/.config/rukey` yet; the first taught word must
        // still reach the disk rather than fail inside the caught write error.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-\(UUID().uuidString)")  // does not exist
        let url = directory.appendingPathComponent("custom.json")
        let dictionary = CustomDictionary(fileURL: url)
        dictionary.replaceAll(with: ["заозкздзаоз"])
        XCTAssertTrue(CustomDictionary(fileURL: url).contains("заозкздзаоз"))
    }

    func testUnwritableSaveIsReportedNotSwallowed() {
        // A silently lost taught word is exactly what spec anti-goal 2 forbids. Put
        // a *file* where the directory must be created, so the save throws.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        // The blocker must exist, or the scenario silently changes: a failed write
        // would leave no file, `createDirectory` would then succeed and the save
        // would land, failing the test for the wrong reason.
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let buffer = LogBuffer()
        let dictionary = CustomDictionary(
            fileURL: blocker.appendingPathComponent("custom.json"), logBuffer: buffer)
        dictionary.replaceAll(with: ["заозкздзаоз"])
        XCTAssertTrue(buffer.lines().contains { $0.level == .warn })
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter DetectorTests 2>&1 | tail -30`
Expected: FAIL — `cannot find 'CustomDictionary' in scope`.

- [ ] **Step 3: Implement `CustomDictionary`**

Create `Sources/RukeyCore/CustomDictionary.swift` with the same swappable-`Trie` construction as `WordFilter` from Task 3 Step 4, trimmed and dropping empty words, plus persistence. Expose both `contains` (exact, via `Trie.contains`) and `isPrefixOfKnown` (via `Trie.hasPrefix`) — the detector needs prefix membership on the on-the-fly path, where it is asked whether `pfj` is the start of a taught word rather than whether it is one. End the file with a newline; it lacked one at `4ac46bc` (four files under `docs/` still do, and stay that way).

Like `WordFilter`, this is a `@unchecked Sendable` class and carries the attribute's justification in a comment, because the Global Constraints require one: the lock guards both stored properties, the pair is only ever swapped together, and the published trie is never mutated afterwards, so a reader cannot observe a trie that disagrees with its backing word set.

- [ ] **Step 4: Inject it into Detector**

In `Detector.init` add `customDictionary: CustomDictionary = CustomDictionary()` after `wordFilter`, and store it as `public let customDictionary: CustomDictionary`.

In `decisionIfMistyped(word:bufferLang:fullWord:)` (`Detector.swift:51`), widen **both sides** in both branches with the custom dictionary, and waive the junk-backed-prefix gate for custom-backed targets:

- Russian branch: `isCurrentValid` becomes
  `ruTrie.contains(word) || customDictionary.contains(word)` when `fullWord` is true, and
  `ruTrie.hasPrefix(word) || customDictionary.isPrefixOfKnown(word)` when it is false.
- English branch: the same with `enTrie`.
- `isConvertedValid` likewise becomes `enTrie.contains(converted) || customDictionary.contains(converted)`
  (or the matching `hasPrefix` / `isPrefixOfKnown` pair on the on-the-fly path).
- On the on-the-fly path only, skip the `countCompletions` junk gate when
  `customDictionary` backs the converted prefix — a word the user taught is by
  definition a real word, which is exactly what that gate is there to establish.

Why both sides: teaching `заозкздзаоз` has to make `pfjprplpfjp` convert (that is
the feature the spec asks for), and it also has to stop `заозкздзаоз` itself from
being flipped back. Widening `isConvertedValid` can only ever *enable* a
conversion — it cannot block one — so it carries none of the "teaching `привет`
would silently block `hello`" risk that widening `isCurrentValid` carries.

Leave `wordFilter` out of this method entirely; the exclusion filter is checked
before the trie work, per Task 3.

**The punctuated path is the third decision site.** `decisionForPunctuatedToken(in:)` decides tokens that end in punctuation, and it must consult the custom dictionary too. Widen its local `contains` helper, both arms:

```swift
        func contains(_ text: String, _ lang: Language) -> Bool {
            lang == .russian
                ? ruTrie.contains(text) || customDictionary.contains(text)
                : enTrie.contains(text) || customDictionary.contains(text)
        }
```

Take `contains`, not `isPrefixOfKnown`: this is a complete-token path, exactly like the run path's boundary arm, and those two must agree about the same typing. Adding an `isPrefixOfKnown` gate next to the filter gate would make the punctuated path *stricter* than the boundary path — with `ghbdtnabc` taught, `ghbdtn` converts but `ghbdtn!` would be blocked — which is a fresh instance of the cross-path disagreement Review Focus #5 forbids. Prefix protection belongs on the on-the-fly arm only, where the word is still being typed. The pair of tests above pins both holes: with `ghbdtn` taught, `ghbdtn!` must stay `ghbdtn!`; and a taught word's Latin typing must still convert once a comma follows it.

**One lookup, not two.** On the on-the-fly path `customDictionary.isPrefixOfKnown(converted)` is needed by both `isConvertedValid` and the junk-gate waiver, and computed separately the two sites can ask the same question twice in one decision. Hoist it in both branches so one answer serves both uses: the hoisted call is then paid once on every on-the-fly decision, including the ones the `||` would have short-circuited; the saving is the duplicate call plus one snapshot of the taught words shared by both uses. The comment above it must state exactly that and not claim a per-keystroke saving; the version at `d0907ad` did, which is the one thing the hoist does not do:

```swift
            // One lookup, reused by the on-the-fly arm of `isConvertedValid` and the
            // junk-gate waiver. Apart, the two uses could ask the same question twice
            // in one decision and could read different snapshots of the taught words;
            // together it is one lookup on every on-the-fly decision. The
            // `fullWord ? false` arm keeps the boundary path from gaining a lookup it
            // never had.
            let taughtTarget = fullWord ? false : customDictionary.isPrefixOfKnown(converted)
            let isConvertedValid = fullWord
                ? enTrie.contains(converted) || customDictionary.contains(converted)
                : enTrie.hasPrefix(converted) || taughtTarget
            if !isCurrentValid && isConvertedValid {
                if !fullWord,
                    !taughtTarget,
                    enTrie.countCompletions(of: converted, limit: minTargetCompletions) < minTargetCompletions
                { return nil }
```

(The `ruTrie`/`enTrie` roles swap in the other branch. The `fullWord ? false` arm keeps the boundary path from gaining a lookup it never had. This is the only place in the task where the code shape — not just the condition — may change; everything else stays as written above.)

**Hermeticity.** Defaulting `customDictionary` in `Detector.init` means every
existing `Detector(...)` construction that omits it now reads the developer's real
`~/.config/rukey/custom.json`. Two helpers in `DetectorTests` do exactly that —
`makeDetector()` and `makeFilteredDetector()` — so pass an explicit empty
`CustomDictionary` built on a per-test temporary URL in both, and in any other
construction you add. `makeDetector()`'s baseline means *empty* custom words. No
test in this suite may read or write the real config directory.

- [ ] **Step 5: Run the tests to see them pass**

Run: `swift test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RukeyCore/CustomDictionary.swift Sources/RukeyCore/Detector.swift Tests/
git commit -m "Teach the detector user-supplied words without rebuilding the tries"
git push
```

---

### Task 5: Undo with no time limit

**Files:**
- Modify: `Sources/RukeyCore/UndoManager.swift:31-109`
- Modify: `Tests/RukeyCoreTests/UndoManagerTests.swift`
- Modify: `Tests/RukeyCoreTests/DetectorTests.swift`

**Interfaces:**
- Consumes: `CorrectionDecision`.
- Produces:

```swift
public final class RukeyUndoManager: @unchecked Sendable {
    public static let maxTailLength = 64
    public init()
    public var canUndo: Bool { get }
    /// The most recently undone pair, needed by the learning logic in Task 7.
    /// `onOptionUndo` carries only the language and the restored text, so the
    /// converted side has to come from here.
    public var lastUndone: (original: String, converted: String)? { get }
    public func recordCorrection(_ decision: CorrectionDecision, appendedTail: String = "")
    public func appendToTail(_ text: String)
    public func calculateUndo() -> UndoCalculation?
    public func clear()
}
```

- [ ] **Step 1: Write the failing UndoManager tests**

Replace `Tests/RukeyCoreTests/UndoManagerTests.swift` with a version that has no clock at all and adds tail behaviour:

```swift
import Foundation
import XCTest
@testable import RukeyCore

final class UndoManagerTests: XCTestCase {
    private func decision(
        original: String = "ghb",
        converted: String = "при"
    ) -> CorrectionDecision {
        CorrectionDecision(
            originalText: original,
            convertedText: converted,
            sourceLanguage: .english,
            targetLanguage: .russian,
            triggerRule: "en_invalid_prefix_ru_valid"
        )
    }

    func testNothingToUndoBeforeAnyCorrection() {
        let manager = RukeyUndoManager()
        XCTAssertFalse(manager.canUndo)
        XCTAssertNil(manager.calculateUndo())
    }

    func testUndoSurvivesAnArbitrarilyLongPause() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        // The old implementation expired the undo after 1.2 s. Sleeping past that
        // window is the only way this assertion can fail: without the sleep the
        // test passes on the time-gated implementation too and pins nothing.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(manager.canUndo)
    }

    func testTailIsErasedAlongsideTheCorrection() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail("вет")
        let calculation = manager.calculateUndo()
        XCTAssertEqual(calculation?.backspacesNeeded, 6)
        XCTAssertEqual(calculation?.textToRestore, "ghb")
        // The undo must switch back the layout the text actually came from.
        XCTAssertEqual(calculation?.originalLanguage, .english)
        // A tail can also arrive at record time — the space-triggered correction
        // passes the space through — and it counts toward the erase too.
        let recorded = RukeyUndoManager()
        recorded.recordCorrection(decision(), appendedTail: " ")
        XCTAssertEqual(recorded.calculateUndo()?.backspacesNeeded, 4)
    }

    func testTailAccumulatesAcrossSeveralAppends() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail("в")
        manager.appendToTail("е")
        manager.appendToTail("т")
        XCTAssertEqual(manager.calculateUndo()?.backspacesNeeded, 6)
    }

    func testTailClearedByExplicitClear() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail("вет")
        manager.clear()
        XCTAssertFalse(manager.canUndo)
    }

    func testTailIsTruncatedAtTheValve() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        manager.appendToTail(String(repeating: "я", count: 200))
        // The valve drops the undo rather than letting an unbounded erase
        // reach into text the user has long since moved past.
        XCTAssertFalse(manager.canUndo)
        // Just below the valve the undo survives, so this is a valve and not an
        // off-by-one that swallows every tail: 3 ("при") + 61 = 64, the limit
        // itself, and only *exceeding* it resets.
        let kept = RukeyUndoManager()
        kept.recordCorrection(decision())
        kept.appendToTail(String(repeating: "я", count: 61))
        XCTAssertTrue(kept.canUndo)
        XCTAssertEqual(kept.calculateUndo()?.backspacesNeeded, 64)
        // The valve weighs the converted text too: 62 + 3 = 65 exceeds it even
        // though the tail alone does not, so a tail-only bound would keep this.
        let over = RukeyUndoManager()
        over.recordCorrection(decision())
        over.appendToTail(String(repeating: "я", count: 62))
        XCTAssertFalse(over.canUndo)
    }

    func testTailOnAnEmptyUndoIsIgnored() {
        let manager = RukeyUndoManager()
        manager.appendToTail("abc")
        XCTAssertFalse(manager.canUndo)
    }

    func testNewerCorrectionReplacesTheOlderUndo() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision(original: "ghb", converted: "при"))
        manager.recordCorrection(decision(original: "тест", converted: "ручка"))
        XCTAssertEqual(manager.calculateUndo()?.textToRestore, "тест")
        // Replacement starts a fresh tail: a tail from the old correction must
        // not widen the new correction's erase.
        let fresh = RukeyUndoManager()
        fresh.recordCorrection(decision())
        fresh.appendToTail("вет")
        fresh.recordCorrection(decision(original: "ntcn", converted: "тест"))
        XCTAssertEqual(fresh.calculateUndo()?.backspacesNeeded, 4)
    }

    func testUndoIsConsumedOnce() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision())
        XCTAssertNotNil(manager.calculateUndo())
        XCTAssertNil(manager.calculateUndo())
    }

    func testLastUndoneIsEmptyUntilAnUndoHappens() {
        let manager = RukeyUndoManager()
        XCTAssertNil(manager.lastUndone)
        manager.recordCorrection(decision())
        // Recording is not undoing: the learning logic must never see a pair
        // the user did not take back.
        XCTAssertNil(manager.lastUndone)
        _ = manager.calculateUndo()
        XCTAssertEqual(manager.lastUndone?.original, "ghb")
        XCTAssertEqual(manager.lastUndone?.converted, "при")
        // "The most recently undone pair": neither a later correction nor a
        // clear retracts it — Task 7's learning reads it through this API.
        manager.recordCorrection(decision(original: "руддщ", converted: "hello"))
        XCTAssertEqual(manager.lastUndone?.original, "ghb")
        manager.clear()
        XCTAssertEqual(manager.lastUndone?.original, "ghb")
    }

    func testBackspacesUseUTF16Length() {
        let manager = RukeyUndoManager()
        manager.recordCorrection(decision(original: "ghb", converted: "🙂"))
        manager.appendToTail("😀")
        // Each emoji is two UTF-16 units.
        XCTAssertEqual(manager.calculateUndo()?.backspacesNeeded, 4)
    }
}
```

`testTailIsTruncatedAtTheValve` and `testBackspacesUseUTF16Length` are the ones that matter; the rest pin existing behaviour.

- [ ] **Step 2: Add a Detector test for two corrections in one word**

Append to `Tests/RukeyCoreTests/DetectorTests.swift` — this pins Review Focus item 4:

```swift
    func testSecondCorrectionInOneWordSupersedesTheFirst() {
        // An on-the-fly flip, then a boundary correction: the manager keeps only
        // the latest, so one Option tap undoes "тест", never both.
        let detector = makeDetector(minTargetCompletions: 2)
        let first = detector.evaluate(buffer: "ghb", currentLanguage: .english)
        let second = detector.evaluateFullWord(buffer: "ntcn", currentLanguage: .english)
        XCTAssertEqual(first?.convertedText, "при")
        XCTAssertEqual(second?.convertedText, "тест")
        XCTAssertNotEqual(first?.originalText, second?.originalText)
        // The three assertions above only show the detector produces two
        // decisions with different originals. The review focus is about the
        // consequence: the manager ends up holding the second, so one Option tap
        // undoes "тест" and cannot also undo "при". If either decision were nil
        // the loop would record fewer and the assertion below would fail too.
        let manager = RukeyUndoManager()
        for decision in [first, second].compactMap({ $0 }) {
            manager.recordCorrection(decision)
        }
        XCTAssertEqual(manager.calculateUndo()?.textToRestore, "ntcn")
    }
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `swift test --filter UndoManagerTests 2>&1 | tail -30`
Expected: FAIL to compile — `appendToTail` does not exist. (`RukeyUndoManager()` itself still compiles today because its clock parameter has a default; Step 4 deletes that parameter.)

- [ ] **Step 4: Rewrite `RukeyUndoManager`**

In `Sources/RukeyCore/UndoManager.swift`:

- Delete `maxUndoWindowSeconds`, the injected `now` closure, `LastCorrectionState.timestamp` and `.timestampUptime`, and `isFresh(_:at:)`. `canUndo` becomes a plain `lastState != nil` under the existing lock.
- Add `public func appendToTail(_ text: String)` guarded by the same `NSLock.withLock`. When there is no state, return without recording. Accumulate into `appendedTail`; when `convertedText.utf16EraseLength + appendedTail.utf16EraseLength` exceeds `maxTailLength`, clear the state instead.
- Keep `calculateUndo()` atomic and consuming exactly as it is today — the existing comment at `UndoManager.swift:82-85` about the TOCTOU fix must survive the edit.
- Keep erase arithmetic on `utf16EraseLength`, never `.count`.
- `recordCorrection` keeps replacing the whole state, tail included. That is what stops a tail typed after an earlier correction from outliving it — the check is not "add a reset", it is "do not lose the one you already have".
- `calculateUndo()` publishes `lastUndone` — the pair it is about to consume — under the same lock, before `lastState = nil`. Neither `clear()` nor `recordCorrection` resets it: it answers "what did the user last take back?", which stays true until the next undo.

- [ ] **Step 5: Route EventTapManager's typing path into the tail instead of clearing**

In `Sources/RukeyCore/EventTapManager.swift:342-346`, the current code clears the undo whenever a character is typed after a correction. Replace that block so it appends instead:

```swift
if undoManager.canUndo {
    undoManager.appendToTail(typedString)
}
```

Leave every other `undoManager.clear()` in that file alone — arrows, word boundaries other than space, ⌘/⌃, backspace, app switch and secure-input bypass are all still correct reset points and are handled in Task 6.

- [ ] **Step 6: Run the tests to see them pass**

Run: `swift test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/RukeyCore/UndoManager.swift Sources/RukeyCore/EventTapManager.swift Tests/
git commit -m "Drop the undo time gate and accumulate typed characters as a tail"
git push
```

---

### Task 6: Click resets undo, and Secure Input blocks the layout toggle

**Files:**
- Modify: `Sources/RukeyCore/EventTapManager.swift:74-108` (tap mask), `:281-284` (flagsChanged branch), `:122-124` (pass helper)
- Create: `Sources/RukeyCore/TapPolicy.swift`
- Create: `Tests/RukeyCoreTests/EventTapPolicyTests.swift`
- Create: `Tests/RukeyCoreTests/SecureInputMonitorTests.swift`
- Modify: `Sources/RukeyCore/SecureInputMonitor.swift`
- Modify: `Sources/RukeyCore/Detector.swift:28-56` (the lock-guarded `minPrefixLength`)
- Modify: `Tests/RukeyCoreTests/DetectorTests.swift`

**Interfaces:**
- Consumes: `RukeyUndoManager`, `SecureInputMonitor`.
- Produces:

```swift
public enum TapPolicy {
    public static let eventMask: CGEventMask
    public static func isUndoResettingEvent(_ type: CGEventType) -> Bool
    public static func shouldToggleLayoutOnOptionTap(isSecureInputActive: Bool) -> Bool
}
```

Putting the decisions in a pure value type is what makes them testable; `EventTapManager` keeps only the wiring. The existing tap callback is not reachable from XCTest, and this task must not be left without tests.

- [ ] **Step 1: Write the failing TapPolicy tests**

Create `Tests/RukeyCoreTests/EventTapPolicyTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import RukeyCore

final class EventTapPolicyTests: XCTestCase {
    func testEventMaskIncludesMouseDown() {
        XCTAssertNotEqual(
            TapPolicy.eventMask & CGEventMask(1 << CGEventType.leftMouseDown.rawValue), 0)
    }

    func testEventMaskStillIncludesKeyDownAndFlagsChanged() {
        XCTAssertNotEqual(
            TapPolicy.eventMask & CGEventMask(1 << CGEventType.keyDown.rawValue), 0)
        XCTAssertNotEqual(
            TapPolicy.eventMask & CGEventMask(1 << CGEventType.flagsChanged.rawValue), 0)
    }

    func testLeftMouseDownResetsUndo() {
        XCTAssertTrue(TapPolicy.isUndoResettingEvent(.leftMouseDown))
        XCTAssertTrue(TapPolicy.isUndoResettingEvent(.rightMouseDown))
    }

    func testTypingDoesNotResetUndo() {
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.keyDown))
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.flagsChanged))
    }

    func testOtherMouseButtonsDoNotResetUndo() {
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.mouseMoved))
        XCTAssertFalse(TapPolicy.isUndoResettingEvent(.scrollWheel))
    }

    func testLayoutToggleIsRefusedUnderSecureInput() {
        XCTAssertFalse(TapPolicy.shouldToggleLayoutOnOptionTap(isSecureInputActive: true))
    }

    func testLayoutToggleIsAllowedNormally() {
        XCTAssertTrue(TapPolicy.shouldToggleLayoutOnOptionTap(isSecureInputActive: false))
    }
}
```

Then create `Tests/RukeyCoreTests/SecureInputMonitorTests.swift`. `shouldBypass(bundleID:secureInput:)` is the pure decision function every keystroke goes through, and it has never had a test; the setters Step 5 adds are only worth anything if the read path honours them. Inject both closures explicitly so these tests never reach NSWorkspace, the real Secure Input state, or the TTL cache:

```swift
import XCTest
@testable import RukeyCore

final class SecureInputMonitorTests: XCTestCase {
    private func makeMonitor(
        excludeTerminals: Bool = false,
        customExcludedBundleIDs: Set<String> = []
    ) -> SecureInputMonitor {
        SecureInputMonitor(
            excludeTerminals: excludeTerminals,
            customExcludedBundleIDs: customExcludedBundleIDs,
            secureInputCheck: { false },
            frontmostBundleID: { nil }
        )
    }

    func testSecureInputAlwaysBypasses() {
        XCTAssertTrue(makeMonitor().shouldBypass(bundleID: nil, secureInput: true))
    }

    func testSecuritySensitiveBundlesAreAlwaysExcluded() {
        let monitor = makeMonitor()
        for bundleID in SecureInputMonitor.securitySensitiveBundleIDs {
            XCTAssertTrue(
                monitor.shouldBypass(bundleID: bundleID, secureInput: false),
                "\(bundleID) must be excluded whatever the settings say")
        }
    }

    func testExcludeTerminalsSettingIsHonouredWhenChanged() {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.apple.Terminal", secureInput: false))
        monitor.excludeTerminals = true
        XCTAssertTrue(monitor.excludeTerminals)
        XCTAssertTrue(monitor.shouldBypass(bundleID: "com.apple.Terminal", secureInput: false))
        monitor.excludeTerminals = false
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.apple.Terminal", secureInput: false))
    }

    func testCustomExcludedBundleIDsSettingIsHonouredWhenChanged() {
        let monitor = makeMonitor()
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.example.app", secureInput: false))
        monitor.customExcludedBundleIDs = ["com.example.app"]
        XCTAssertEqual(monitor.customExcludedBundleIDs, ["com.example.app"])
        XCTAssertTrue(monitor.shouldBypass(bundleID: "com.example.app", secureInput: false))
        monitor.customExcludedBundleIDs = []
        XCTAssertFalse(monitor.shouldBypass(bundleID: "com.example.app", secureInput: false))
    }

    func testUnrelatedBundleIsNotExcluded() {
        XCTAssertFalse(
            makeMonitor(excludeTerminals: true).shouldBypass(
                bundleID: "com.apple.Safari", secureInput: false))
    }
}
```

Finally append to `Tests/RukeyCoreTests/DetectorTests.swift`. `Detector.minPrefixLength` is the third setter spec §5 names — plan 2's Task 6 consumes the `Detector.minPrefixLength` setter and asserts the change reaches the live detector — and no other task in either plan provides it, which is why it is here:

```swift
    func testMinPrefixLengthIsSettableAndTakesEffectImmediately() {
        // Spec §5: the settings window changes this without rebuilding the
        // detector, because a rebuild means re-arming the tap and dropping input
        // while it is down. "gh" -> "пр" is a real prefix of привет/приветствие,
        // so at a bar of 2 the only thing keeping it from flipping is its length.
        let detector = makeDetector(minTargetCompletions: 2, minPrefixLength: 3)
        XCTAssertNil(detector.evaluate(buffer: "gh", currentLanguage: .english))
        detector.minPrefixLength = 2
        XCTAssertEqual(
            detector.evaluate(buffer: "gh", currentLanguage: .english)?.convertedText, "пр")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter EventTapPolicyTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TapPolicy' in scope`.

- [ ] **Step 3: Implement `TapPolicy`**

Create `Sources/RukeyCore/TapPolicy.swift`:

- `eventMask` is the OR of `keyDown`, `flagsChanged`, `leftMouseDown` and `rightMouseDown`, each as `CGEventMask(1 << type.rawValue)`.
- `isUndoResettingEvent(_:)` returns true for `leftMouseDown` and `rightMouseDown`.
- `shouldToggleLayoutOnOptionTap(isSecureInputActive:)` returns `!isSecureInputActive`.

- [ ] **Step 4: Wire `TapPolicy` into the tap**

In `Sources/RukeyCore/EventTapManager.swift`:

- Replace the inline `eventMask` computation at `:74-76` with `TapPolicy.eventMask`.
- At the top of `handleEvent`, after the `tapDisabledByTimeout` branch and before any other work, add: if `TapPolicy.isUndoResettingEvent(type) { undoManager.clear(); return pass(event) }`.
- In `handleOptionTap()` (`:162`), guard the else branch — the layout toggle — with `TapPolicy.shouldToggleLayoutOnOptionTap(isSecureInputActive: secureMonitor.isSecureInputActive())`. When it returns false, emit `onOptionIgnored?("secure_input_active")` and clear the buffer instead of toggling.

`SecureInputMonitor.isSecureInputActive()` already exists (`SecureInputMonitor.swift:56`) and answers exactly this question; no new accessor is needed. It must stay distinct from `shouldBypassForActiveApplication()`, which also consults the app exclusion list — Secure Input and app exclusions are different questions.

- [ ] **Step 5: Make the hot-reload settings mutable**

In `Sources/RukeyCore/SecureInputMonitor.swift`, make the app-exclusion settings mutable so the settings window can change them without rebuilding the tap.

- `excludeTerminals` is currently a stored `public let` (`:29`), read in `shouldBypass` (`:90`). Convert it to `public var excludeTerminals: Bool { get set }` with a private backing store, guarded by an `NSLock`.
- `customExcludedBundleIDs` is currently a stored **`private`** `let` (`:30`), read in `shouldBypass` (`:86`). It must become **`public var customExcludedBundleIDs: Set<String> { get set }`** — public, not merely private under the same name. The GUI plan consumes its setter in so many words: "Consumes: `SecureInputMonitor.customExcludedBundleIDs` and `.excludeTerminals` setters from the engine plan."
- One private `NSLock` for both settings. A second `NSLock` *instance* is fine; introducing a different locking primitive is not. Do **not** reuse `cacheLock` — that guards the frontmost-app TTL cache and there is no reason to serialize the two. Make sure no path holds one lock while acquiring the other: `shouldBypassForActiveApplication` (`:97-102`) must not read the settings while `cacheLock` is held.
- Reads inside `shouldBypass` (`:86,90`) must go through the same lock. Note `shouldBypassForActiveApplication()` runs on the per-keystroke path (`EventTapManager.swift:268`); one uncontended `NSLock` acquisition is negligible there next to the `IsSecureEventInputEnabled()` syscall that path already makes.
- Keep the initialiser signature unchanged so `EventTapManager.init` and every existing call site keep compiling.
- `isSecureInputActive()` and `shouldBypassForActiveApplication()` must stay distinct: Secure Input and app exclusions are different questions, and the layout toggle in Step 4 consults only the former.
- The class's pre-existing `@unchecked Sendable` gains the justification comment the plan's Global Constraints require. It has never been more necessary: this task adds mutable state to a class read on the keystroke path. The honest statement is that the frontmost-app cache is guarded by `cacheLock`, the two settings by their own `NSLock`, and `secureInputCheck`/`frontmostBundleID` are immutable `@Sendable` closures.

Spec §5 names **three** settings that are `let` today and must gain hot-reload setters: `SecureInputMonitor.excludeTerminals`, `.customExcludedBundleIDs`, and `Detector.minPrefixLength`. The first two are above; the third belongs here, in `Sources/RukeyCore/Detector.swift`:

- Convert `minPrefixLength` from `public let` (`:28`) into `public var minPrefixLength: Int { get set }` — a computed property over a private stored property, guarded by a private `NSLock`. Every existing read (`candidateWord(from:minLength:)` at `:145` and `:155`) then goes through the lock automatically: one uncontended acquisition per decision, the same cost the exclusion filter already pays.
- Keep `init`'s `minPrefixLength` parameter, so `RukeyEngine` (Task 8) and every existing call site keep compiling. Do not clamp here: `RukeyConfig` already validates 2...5 and the settings window clamps; the detector takes what it is given.
- Do not rebuild the detector and do not re-arm the tap. Spec §5 forbids it — that window is one in which input is not intercepted — and it is the whole reason this setter exists.
- `Detector`'s `@unchecked Sendable` (`Detector.swift:25`) has no justification comment at all — it never had one, and this task is what makes it necessary. Give it one in the same spirit as the `SecureInputMonitor` comment above and `CustomDictionary`'s own: `enTrie`/`ruTrie`/`minTargetCompletions` are immutable after `init`, `minPrefixLength` is guarded by its own `NSLock`, and `wordFilter`/`customDictionary` are independent `@unchecked Sendable` types that guard their own state. It ships in the second commit with `Detector.swift`.

- [ ] **Step 6: Run the tests to see them pass**

Run: `swift test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Verify the app still builds and the CLI still runs**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 8: Commit**

```bash
# Each commit must build on its own, so tests are staged with the code they
# exercise: the SecureInputMonitor and Detector setter tests do not compile
# until Step 5 exists.
git add Sources/RukeyCore/TapPolicy.swift Sources/RukeyCore/EventTapManager.swift Tests/RukeyCoreTests/EventTapPolicyTests.swift
git commit -m "Reset undo on click and refuse Option layout toggle under Secure Input"

git add Sources/RukeyCore/SecureInputMonitor.swift Sources/RukeyCore/Detector.swift Tests/RukeyCoreTests/SecureInputMonitorTests.swift Tests/RukeyCoreTests/DetectorTests.swift
git commit -m "Add the hot-reload setters for the settings the spec lists as let"

git push
```

---

### Task 7: Learning turns repeated undos into exclusions

**Files:**
- Create: `Sources/RukeyCore/StrikeStore.swift`
- Create: `Sources/RukeyCore/UndoLearningController.swift`
- Create: `Tests/RukeyCoreTests/StrikeStoreTests.swift`

**Interfaces:**
- Consumes: `RukeyUndoManager`, `WordFilter`, `RukeyConfig`.
- Produces:

```swift
public final class StrikeStore: @unchecked Sendable {
    public static let defaultFileURL: URL   // ~/.config/rukey/learned.json
    public init(fileURL: URL = StrikeStore.defaultFileURL, logBuffer: LogBuffer = .shared)
    public var fileURL: URL { get }
    public func strikes(for key: String) -> Int
    @discardableResult
    public func registerUndo(key: String) -> Int
    public func removeAll()
    public func removeAllKeys(for prefix: String)
}
```

`registerUndo` returns the new count and persists to disk under the lock. It is
the only writer. The threshold lives in the caller — `StrikeStore` only counts.

```swift
public enum LearningNotice: Equatable, Sendable {
    case undo(prefix: String, converted: String, count: Int, threshold: Int)
    case learned(prefix: String, converted: String)
}

public final class UndoLearningController: @unchecked Sendable {
    public init(
        strikeStore: StrikeStore,
        wordFilter: WordFilter,
        thresholdProvider: @escaping @Sendable () -> Int,
        notifyProvider: @escaping @Sendable () -> Bool,
        configWriter: @escaping @Sendable (Set<String>) -> Void,
        logBuffer: LogBuffer = .shared
    )
    /// The two lines this controller writes, as data: `.undo` mirrors the
    /// `Отменено:` line, `.learned` mirrors the `.warn` `Запомнено:` line, both
    /// emitted at the same point under the same condition. The hub at the end of
    /// this plan (Task 9) subscribes to this instead of parsing the log.
    public var onNotice: ((LearningNotice) -> Void)?
    public func handleUndo(_ pair: (original: String, converted: String)?)
}
```

`handleUndo(nil)` does nothing. Otherwise it registers a strike; when the
threshold is non-zero and the new count reaches it **exactly**, it adds the prefix
to the filter, calls `configWriter`, and logs the learned rule. Reaching exactly
rather than at-or-above keeps a fourth undo from rewriting the config again.
Every log emission has a data twin on `onNotice`, emitted at the same point under
the same condition — a consumer reads exactly what the console prints, never a
re-derivation of it.

- [ ] **Step 1: Write the failing StrikeStore tests**

Create `Tests/RukeyCoreTests/StrikeStoreTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class StrikeStoreTests: XCTestCase {
    private func makeStore() -> (StrikeStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json")
        return (StrikeStore(fileURL: url), url)
    }

    func testFreshStoreHasNoStrikes() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.strikes(for: "ghb"), 0)
    }

    func testRegisteringIncrementsAndReturnsTheCount() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.registerUndo(key: "ghb"), 1)
        XCTAssertEqual(store.registerUndo(key: "ghb"), 2)
        XCTAssertEqual(store.strikes(for: "ghb"), 2)
    }

    func testKeysAreIndependent() {
        let (store, _) = makeStore()
        store.registerUndo(key: "ghb")
        store.registerUndo(key: "hello")
        XCTAssertEqual(store.strikes(for: "ghb"), 1)
        XCTAssertEqual(store.strikes(for: "hello"), 1)
    }

    func testCountsSurviveReopen() {
        let (store, url) = makeStore()
        store.registerUndo(key: "ghb")
        store.registerUndo(key: "ghb")
        let reopened = StrikeStore(fileURL: url)
        XCTAssertEqual(reopened.strikes(for: "ghb"), 2)
    }

    func testCorruptFileStartsEmptyAndReports() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json")
        try? "{ broken".write(to: url, atomically: true, encoding: .utf8)
        let buffer = LogBuffer()
        let store = StrikeStore(fileURL: url, logBuffer: buffer)
        XCTAssertEqual(store.strikes(for: "ghb"), 0)
        XCTAssertTrue(buffer.lines().contains { $0.level == .warn })
    }

    func testRemoveAllClearsEveryKey() {
        let (store, _) = makeStore()
        store.registerUndo(key: "ghb")
        store.removeAll()
        XCTAssertEqual(store.strikes(for: "ghb"), 0)
    }

    func testRemoveAllKeysForPrefixClearsOnlyThatBranchAndPersists() {
        let (store, url) = makeStore()
        store.registerUndo(key: "ghbdtn")
        store.registerUndo(key: "ntcn")
        store.removeAllKeys(for: "ghb")
        XCTAssertEqual(store.strikes(for: "ghbdtn"), 0)
        XCTAssertEqual(store.strikes(for: "ntcn"), 1)
        // Clearing has to reach the file: a restart must not resurrect what the
        // user removed, or the word can never be learned again.
        let reopened = StrikeStore(fileURL: url)
        XCTAssertEqual(reopened.strikes(for: "ghbdtn"), 0)
        XCTAssertEqual(reopened.strikes(for: "ntcn"), 1)
    }
}
```

- [ ] **Step 2: Write the failing learning tests**

Append to `Tests/RukeyCoreTests/StrikeStoreTests.swift`:

```swift
final class UndoLearningTests: XCTestCase {
    /// Records config writes. A reference box, because `configWriter` is
    /// `@escaping @Sendable` and Swift 6 forbids capturing a mutable local in it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Set<String>] = []
        func record(_ words: Set<String>) { lock.withLock { stored.append(words) } }
        var writes: [Set<String>] { lock.withLock { stored } }
    }

    private struct Harness {
        let controller: UndoLearningController
        let filter: WordFilter
        let recorder: Recorder
        var persisted: [Set<String>] { recorder.writes }
    }

    private func makeHarness(words: Set<String> = []) -> Harness {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter(words: words)
        let recorder = Recorder()
        return Harness(
            controller: UndoLearningController(
                strikeStore: store,
                wordFilter: filter,
                thresholdProvider: { 3 },
                notifyProvider: { true },
                configWriter: { recorder.record($0) }
            ),
            filter: filter,
            recorder: recorder
        )
    }

    func testNilUndoIsIgnored() {
        let h = makeHarness()
        h.controller.handleUndo(nil)
        XCTAssertTrue(h.filter.isEmpty)
    }

    func testStrikeBelowThresholdDoesNotExclude() {
        let h = makeHarness()
        h.controller.handleUndo((original: "ghb", converted: "при"))
        h.controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertTrue(h.filter.isEmpty)
    }

    func testThirdUndoExcludesThePrefix() {
        let h = makeHarness()
        for _ in 0..<3 {
            h.controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertTrue(h.filter.isExcluded("ghb"))
        XCTAssertTrue(h.filter.isPrefixOfExcluded("ghbdtn"))
    }

    func testLearningPersistsToConfigExactlyOnce() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter()
        let recorder = Recorder()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: filter,
            thresholdProvider: { 3 },
            notifyProvider: { true },
            configWriter: { recorder.record($0) }
        )
        for _ in 0..<5 {
            controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertEqual(recorder.writes.count, 1)
        XCTAssertEqual(recorder.writes.first, ["ghb"])
    }

    func testThresholdZeroNeverLearns() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: filter,
            thresholdProvider: { 0 },
            notifyProvider: { false },
            configWriter: { _ in }
        )
        for _ in 0..<10 {
            controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertTrue(filter.isEmpty)
    }

    func testLogsThePairInMenuForm() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let buffer = LogBuffer()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 3 },
            notifyProvider: { true },
            configWriter: { _ in },
            logBuffer: buffer
        )
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertTrue(buffer.lines().contains {
            $0.text == "Отменено: ghb → при (1/3)"
        })
    }

    func testLogsTheLearnedRuleWhenItLands() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let buffer = LogBuffer()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 1 },
            notifyProvider: { false },
            configWriter: { _ in },
            logBuffer: buffer
        )
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertTrue(buffer.lines().contains {
            $0.level == .warn && $0.text == "Запомнено: ghb больше не станет при"
        })
    }

    func testNotificationSuppressedWhenDisabled() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let buffer = LogBuffer()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 3 },
            notifyProvider: { false },
            configWriter: { _ in },
            logBuffer: buffer
        )
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertFalse(buffer.lines().contains { $0.text.contains("Отменено") })
    }

    private final class NoticeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [LearningNotice] = []
        func record(_ notice: LearningNotice) { lock.withLock { stored.append(notice) } }
        var notices: [LearningNotice] { lock.withLock { stored } }
    }

    func testNoticesMirrorTheTwoLines() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter()
        let recorder = NoticeRecorder()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: filter,
            thresholdProvider: { 3 },
            notifyProvider: { true },
            configWriter: { _ in }
        )
        controller.onNotice = { recorder.record($0) }
        for _ in 0..<3 {
            controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertEqual(recorder.notices, [
            .undo(prefix: "ghb", converted: "при", count: 1, threshold: 3),
            .undo(prefix: "ghb", converted: "при", count: 2, threshold: 3),
            .learned(prefix: "ghb", converted: "при"),
        ])
        XCTAssertTrue(filter.isExcluded("ghb"))
    }

    func testLearnedNoticeSurvivesNotificationsBeingOff() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let recorder = NoticeRecorder()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 2 },
            notifyProvider: { false },
            configWriter: { _ in }
        )
        controller.onNotice = { recorder.record($0) }
        controller.handleUndo((original: "ghb", converted: "при"))
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertEqual(recorder.notices, [.learned(prefix: "ghb", converted: "при")])
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `swift test --filter StrikeStoreTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'StrikeStore' in scope`.

- [ ] **Step 4: Implement `StrikeStore`**

Create `Sources/RukeyCore/StrikeStore.swift`. On-disk shape is `{"strikes": {"ghb": 2}}`. Initialiser signature is `init(fileURL: URL, logBuffer: LogBuffer = .shared)`. Load under the lock in `init`; a missing file is silent, a corrupt file logs a `.warn` and starts empty. `registerUndo` increments, writes atomically (`Data.write(to:options:.atomic)`), and returns the new count. Guard all state with `NSLock.withLock`. `removeAll` and `removeAllKeys(for:)` mutate the same table and must persist it the same way — a restart must not resurrect what the user cleared. `StrikeStore` is `@unchecked Sendable`, and the plan's Global Constraints require a comment justifying the attribute: here the justification is real, because every mutation of the table happens inside `lock.withLock`.

- [ ] **Step 5: Implement `UndoLearningController`**

Create `Sources/RukeyCore/UndoLearningController.swift`. It owns no state beyond its dependencies. Like every new `@unchecked Sendable` type it carries a comment justifying the attribute; the honest statement here is that every stored property is immutable and itself `Sendable` **except `onNotice`** — a set-once-before-the-tap-starts, then read-on-the-tap-thread hook following the same pattern (and the same lack of a `@Sendable` annotation on the property) as `EventTapManager`'s four callbacks — so `@unchecked` stays conservative rather than load-bearing. `handleUndo` does, in order:

1. `guard let pair else { return }`.
2. `let count = strikeStore.registerUndo(key: pair.original)`.
3. `let threshold = thresholdProvider()`. When `threshold > 0 && count == threshold`: `wordFilter.replaceAll(with: wordFilter.words.union([pair.original]))`, `configWriter(wordFilter.words)`, append a `.warn` line reading exactly `Запомнено: \(pair.original) больше не станет \(pair.converted)`, and call `onNotice?(.learned(prefix: pair.original, converted: pair.converted))`.
4. Otherwise, when `notifyProvider()` is true, append an `.info` line reading exactly `Отменено: \(pair.original) → \(pair.converted) (\(count)/\(threshold))` and call `onNotice?(.undo(prefix: pair.original, converted: pair.converted, count: count, threshold: threshold))`.

The exact strings are load-bearing: the GUI renders these lines in the menu, and `testLogsThePairInMenuForm` pins them character for character.

- [ ] **Step 6: Run the tests to see them pass**

Run: `swift test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Verify the CLI still builds**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` — nothing in `Sources/RukeyApp/` changed in this task, so the CLI behaviour is untouched.

- [ ] **Step 8: Commit**

```bash
git add Sources/RukeyCore/StrikeStore.swift Sources/RukeyCore/UndoLearningController.swift Tests/
git commit -m "Turn repeated undos into exclusion rules at a configurable threshold"
git push
```

---

### Task 8: Shared bootstrap and logger buffering

**Files:**
- Create: `Sources/RukeyCore/DaemonBootstrap.swift`
- Modify: `Sources/RukeyCore/KeyCodes.swift:19-35`
- Modify: `Sources/RukeyCore/RukeyConfig.swift`
- Modify: `Sources/RukeyApp/main.swift:42-148`
- Create: `Tests/RukeyCoreTests/DaemonBootstrapTests.swift`
- Create: `Tests/RukeyCoreTests/RukeyLoggerTests.swift`
- Modify: `Tests/RukeyCoreTests/RukeyConfigTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces:

```swift
public struct RukeyEngine {
    public let detector: Detector
    public let wordFilter: WordFilter
    public let customDictionary: CustomDictionary
    public let undoManager: RukeyUndoManager
    public let strikeStore: StrikeStore
    public let secureMonitor: SecureInputMonitor
    public let tapManager: EventTapManager
    public let config: RukeyConfig
    public init(
        config: RukeyConfig,
        verbose: Bool,
        customDictionaryFileURL: URL = CustomDictionary.defaultFileURL,
        strikeStoreFileURL: URL = StrikeStore.defaultFileURL
    ) throws
}
```

The two URL parameters exist so tests never read or write the real
`~/.config`. Production call sites omit them.

- [ ] **Step 1: Write the failing bootstrap tests**

Create `Tests/RukeyCoreTests/DaemonBootstrapTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class DaemonBootstrapTests: XCTestCase {
    private func makeConfig() -> RukeyConfig {
        RukeyConfig.load(
            excludeTerminalsFlag: false,
            extraBundleIDs: [],
            verbose: false,
            configFileURL: URL(fileURLWithPath: "/nonexistent/exclude.json")
        )
    }

    /// Both stores default to files under the real `~/.config/rukey`, so every
    /// engine in this suite is built on per-test temporary paths: no test may
    /// read or write the developer's own configuration.
    private func makeTempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    func testEngineBuildsEveryStoreFromOneConfig() throws {
        let engine = try RukeyEngine(
            config: makeConfig(),
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertTrue(engine.wordFilter.isEmpty)
        XCTAssertEqual(engine.undoManager.canUndo, false)
        XCTAssertEqual(engine.strikeStore.strikes(for: "anything"), 0)
    }

    func testExcludedWordsFromConfigReachTheFilter() throws {
        var config = makeConfig()
        config.excludedWords = ["ghbdtn"]
        let engine = try RukeyEngine(
            config: config,
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertTrue(engine.wordFilter.isExcluded("ghbdtn"))
    }

    func testCustomWordsReachTheDetector() throws {
        let url = makeTempURL("custom")
        CustomDictionary(fileURL: url).replaceAll(with: ["заозкздзаоз"])
        let engine = try RukeyEngine(
            config: makeConfig(),
            verbose: false,
            customDictionaryFileURL: url,
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertTrue(engine.customDictionary.contains("заозкздзаоз"))
    }

    func testBundleIDExclusionsReachTheSecureMonitor() throws {
        var config = makeConfig()
        config.excludedBundleIDs = ["com.example.app"]
        let engine = try RukeyEngine(
            config: config,
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        XCTAssertEqual(engine.secureMonitor.customExcludedBundleIDs, ["com.example.app"])
    }
}
```

Then create `Tests/RukeyCoreTests/RukeyLoggerTests.swift` — the logger is the other half of this task, and its levels are the contract the GUI's log pane reads:

```swift
import XCTest
@testable import RukeyCore

final class RukeyLoggerTests: XCTestCase {
    func testLogLevelsReachTheBuffer() {
        let buffer = LogBuffer()
        let logger = RukeyLogger(
            isVerbose: false, mirrorToStandardOutput: false, logBuffer: buffer)
        logger.debug("quiet")
        logger.info("plain")
        logger.warn("careful")
        logger.error("broken")
        XCTAssertEqual(buffer.lines().map(\.level), [.info, .warn, .error])
    }

    func testVerboseGatesDebugAndKeepsItsText() {
        let buffer = LogBuffer()
        let logger = RukeyLogger(
            isVerbose: true, mirrorToStandardOutput: false, logBuffer: buffer)
        logger.debug("loud")
        XCTAssertEqual(buffer.lines().last?.level, .debug)
        XCTAssertEqual(buffer.lines().last?.text, "loud")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter DaemonBootstrapTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'RukeyEngine' in scope`.

- [ ] **Step 3: Implement `RukeyEngine`**

Create `Sources/RukeyCore/DaemonBootstrap.swift`. `init` performs, in order: load config → build `WordFilter` from `config.excludedWords` → build `CustomDictionary(fileURL: customDictionaryFileURL)` (it reads `custom.json` itself in `init`; there is deliberately **no** `customWords` key in `exclude.json`) → build `StrikeStore` at `strikeStoreFileURL` → build the dictionaries via `DictionaryLoader.shared` and throw when either trie has `wordCount == 0` → build `Detector` with all injected dependencies → build `SecureInputMonitor` → build `EventTapManager`. It must not start the tap; `EventTapManager.start()` stays a separate call the entry point makes.

An empty dictionary must not be a silent success. Throw `RukeyEngineError.emptyDictionary(resource:)`, defined in the same file, with `resource` equal to `"words_en.txt"` or `"words_ru.txt"`, checking English first so the entry point can print the same messages in the same order it does today.

`Detector` receives `minPrefixLength: config.minPrefixLength` — not a literal `3`, or the settings would not take effect — and `minTargetCompletions` keeps its default. `init` also sets `tapManager.logger = RukeyLogger(isVerbose: verbose)`; that is what the `verbose` parameter is for. `SecureInputMonitor` gets `config.excludeTerminals` and `config.excludedBundleIDs`.

- [ ] **Step 4: Buffer logger output**

In `Sources/RukeyCore/KeyCodes.swift`, extend `RukeyLogger` to `warn(_:)` and `error(_:)` alongside the existing `debug` and `info`. All four append to the log buffer with the matching level; `debug` appends only when `isVerbose`; `info`, `warn` and `error` also keep writing to standard output when `mirrorToStandardOutput` is true, which must stay the default so `swift run rukey` keeps behaving as it does today. The initialiser becomes `public init(isVerbose: Bool = false, mirrorToStandardOutput: Bool = true, logBuffer: LogBuffer = .shared)` — `mirrorToStandardOutput` is a settable `public var`, and the buffer is injectable so `RukeyLoggerTests` can watch it without writing into the daemon's own buffer. Existing call sites that pass only `isVerbose:` must keep compiling unchanged.

- [ ] **Step 5: Add the one config writer**

In `Sources/RukeyCore/RukeyConfig.swift`, add the single writer for the config schema. The GUI plan's settings window has two tabs that save settings, and each one growing its own encoder is how the two-writers defect starts (one writes `{"excludedWords": …}` and silently drops `excludedBundleIDs`). One whole-struct writer owns the schema:

```swift
/// Writes the whole config atomically to `url`, creating the `~/.config/rukey`
/// directory when it does not exist. The one writer for this schema: callers
/// mutate their own copy and hand it over whole, so no two writers can drop
/// each other's fields. Keys outside the schema are not preserved — the file
/// belongs to the app — and `verbose` is CLI-only and stays out of it.
/// - Returns: `false`, and one `.warn` line, when the write fails.
@discardableResult
public static func write(
    _ config: RukeyConfig,
    to url: URL = RukeyConfig.configFileURL,
    logBuffer: LogBuffer = LogBuffer.shared
) -> Bool
```

It encodes exactly the eight keys `FileShape` reads, with `excludedBundleIDs` sorted so the output is stable, and writes with `Data.write(to:options: .atomic)`. The failure line follows `readFile`'s shape — the URL and the underlying error's description at `.warn`, the same level the custom dictionary's failed save uses.

Append three tests to `Tests/RukeyCoreTests/RukeyConfigTests.swift`:

```swift
    func testWriteRoundTripsEveryField() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exclude-\(UUID().uuidString).json")
        let config = RukeyConfig(
            excludedWords: ["ghbdtn"],
            excludeTerminals: true,
            excludedBundleIDs: ["com.example.app"],
            launchAtLogin: true,
            autoLearnThreshold: 2,
            notifyOnEveryUndo: false,
            showCorrectionFlash: false,
            minPrefixLength: 5,
            verbose: true
        )
        XCTAssertTrue(RukeyConfig.write(config, to: url))
        let reloaded = RukeyConfig.load(
            excludeTerminalsFlag: false,
            extraBundleIDs: [],
            verbose: false,
            configFileURL: url
        )
        XCTAssertEqual(reloaded.excludedWords, ["ghbdtn"])
        XCTAssertEqual(reloaded.excludedBundleIDs, ["com.example.app"])
        XCTAssertTrue(reloaded.excludeTerminals)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertEqual(reloaded.autoLearnThreshold, 2)
        XCTAssertFalse(reloaded.notifyOnEveryUndo)
        XCTAssertFalse(reloaded.showCorrectionFlash)
        XCTAssertEqual(reloaded.minPrefixLength, 5)
        // `verbose` is CLI-only: the file never carries it.
        XCTAssertFalse(reloaded.verbose)
    }

    func testWriteCreatesTheConfigDirectory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-\(UUID().uuidString)/nested/exclude.json")
        XCTAssertTrue(RukeyConfig.write(RukeyConfig(), to: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteFailureIsReported() {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let buffer = LogBuffer()
        XCTAssertFalse(RukeyConfig.write(
            RukeyConfig(), to: blocker.appendingPathComponent("exclude.json"),
            logBuffer: buffer))
        XCTAssertTrue(buffer.lines().contains {
            $0.level == .warn && $0.text.contains(blocker.path)
        })
    }
```

- [ ] **Step 6: Collapse `main.swift` onto the bootstrap**

In `Sources/RukeyApp/main.swift`, replace lines `:70`–`:118` — the dictionary loading, the detector/monitor/tap construction, and the four `tapManager.on…` callback assignments — with one `RukeyEngine` construction followed by the same four callbacks re-created (they close over `tapManager` and `printLangState`, so they cannot move inside the engine). `RukeyEngine.init` throws: wrap the construction in `do`/`catch` and, in `catch`, print the same two dictionary-failure lines the code prints today — `❌ English dictionary is missing or empty (words_en: got 0 words). Check Resources/words_en.txt.` when `resource == "words_en.txt"` and the Russian equivalent otherwise — then `exit(1)`, exactly as the current `:79-87` block does. Inside `onOptionUndo`, keep the existing print and add one line calling `learningController.handleUndo(tapManager.undoManager.lastUndone)`, constructing `learningController` from the engine's `strikeStore` and `wordFilter` plus closures reading the live config: `thresholdProvider: { config.autoLearnThreshold }`, `notifyProvider: { config.notifyOnEveryUndo }`, and `configWriter: { words in var updated = config; updated.excludedWords = words.sorted(); RukeyConfig.write(updated, to: RukeyConfig.configFileURL, logBuffer: LogBuffer.shared) }` — the writer from Step 5 is what makes learned words survive a restart, and its whole-struct form keeps every other field of the file untouched. Keep every CLI flag, the `--help` text, the `--check-permissions` behaviour and the `--test-conversion` samples byte-identical; the flag parsing at `:10-51`, the `printHelp` body and `runSampleConversions` at `:180-205` must not change.

- [ ] **Step 7: Run the tests and the CLI**

Run: `swift test 2>&1 | tail -20`
Expected: PASS.

Run: `swift run rukey --test-conversion 2>&1 | tail -8`
Expected: the same five sample lines the README documents, unchanged.

- [ ] **Step 8: Commit**

```bash
git add Sources/RukeyCore/ Sources/RukeyApp/ Tests/
git commit -m "Collapse daemon construction into a shared engine and buffer logger output"
git push
```

---

### Task 9: `AppEventHub`, the single fan-out point the GUI plan consumes

**Files:**
- Create: `Sources/RukeyCore/AppEventHub.swift`
- Create: `Tests/RukeyCoreTests/AppEventHubTests.swift`

**Interfaces:**
- Consumes: `RukeyEngine` (Task 8), `UndoLearningController.onNotice` (Task 7).
- Produces:

```swift
public struct UndoNotice: Equatable, Sendable {
    public let prefix: String
    public let converted: String
    public let count: Int
    public let threshold: Int
}

public struct LearnedNotice: Equatable, Sendable {
    public let prefix: String
    public let converted: String
}

public struct LayoutToggleNotice: Equatable, Sendable {
    public let from: Language
    public let to: Language
}

public final class AppEventHub: ObservableObject {
    public init(tapManager: EventTapManager, learningController: UndoLearningController)
    @Published public private(set) var lastCorrection: CorrectionDecision?
    @Published public private(set) var lastUndo: UndoNotice?
    @Published public private(set) var lastLearned: LearnedNotice?
    @Published public private(set) var lastLayoutToggle: LayoutToggleNotice?
    @Published public private(set) var lastIgnoredReason: String?
}
```

This is the file the File Structure table already promises as "Single fan-out point translating engine callbacks into `AppEvent` values". The design spec's §5 puts `AppEventHub` in `RukeyCore` — the daemon and the UI are one process — and says it is subscribed to the four `EventTapManager` callbacks and fans them out to SwiftUI. Every property holds the latest value of its kind, so a consumer that attaches late still sees the last correction; construction is the only wiring, so in one process either the hub or hand-written callbacks own the tap, never both. The console (`main.swift`) deliberately does not construct one: it prints through `printLangState` and needs no SwiftUI.

**Construction, in `init`:**

- `tapManager.onCorrection = { [weak self] in self?.lastCorrection = $0 }`
- `tapManager.onOptionToggle = { [weak self] in self?.lastLayoutToggle = LayoutToggleNotice(from: $0, to: $1) }`
- `tapManager.onOptionIgnored = { [weak self] in self?.lastIgnoredReason = $0 }`
- `tapManager.onOptionUndo = { [weak self] _, _ in
      guard let self else { return }
      self.learningController.handleUndo(self.tapManager.undoManager.lastUndone) }` — the undo notice itself arrives through the notice hook, count and threshold included, so the raw `(from, restored)` payload is not published separately. This is the same call Task 8's `main.swift` makes; both feed the same controller.
- `learningController.onNotice = { [weak self] in self?.handle($0) }` with a private `handle(_ notice: LearningNotice)` that maps `.undo` → `UndoNotice` and `.learned` → `LearnedNotice`.

The hub holds strong references to the tap manager and the learning controller; the closures capture the hub weakly. No `@MainActor` and no `@unchecked Sendable`: the tap lives on the main run loop — Task 8's bootstrap inherits today's `CFRunLoopRun`, and the GUI's `NSApplication.run()` delivers to the same tap — so the callbacks arrive on the main thread, and the four callback properties take plain closures, the same shape as `EventTapManager`'s. Say all of this in the file's header comment.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RukeyCoreTests/AppEventHubTests.swift`:

```swift
import XCTest
@testable import RukeyCore

final class AppEventHubTests: XCTestCase {
    private func makeTempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    private func makeRig(
        threshold: Int = 3,
        notify: Bool = true
    ) throws -> (engine: RukeyEngine, controller: UndoLearningController, hub: AppEventHub) {
        let engine = try RukeyEngine(
            config: RukeyConfig(),
            verbose: false,
            customDictionaryFileURL: makeTempURL("custom"),
            strikeStoreFileURL: makeTempURL("learned")
        )
        let controller = UndoLearningController(
            strikeStore: engine.strikeStore,
            wordFilter: engine.wordFilter,
            thresholdProvider: { threshold },
            notifyProvider: { notify },
            configWriter: { _ in }
        )
        let hub = AppEventHub(tapManager: engine.tapManager, learningController: controller)
        return (engine, controller, hub)
    }

    private func decision() -> CorrectionDecision {
        CorrectionDecision(
            originalText: "ghb", convertedText: "при",
            sourceLanguage: .english, targetLanguage: .russian,
            triggerRule: "en_invalid_prefix_ru_valid")
    }

    /// Puts a correction into the undo manager and performs the undo — exactly
    /// the pair of calls the tap makes before it fires `onOptionUndo`.
    private func undoCandidate(_ engine: RukeyEngine) {
        engine.undoManager.recordCorrection(decision())
        _ = engine.undoManager.calculateUndo()
    }

    func testCorrectionCallbackReachesTheHub() throws {
        let (engine, _, hub) = try makeRig()
        engine.tapManager.onCorrection?(decision())
        XCTAssertEqual(hub.lastCorrection, decision())
    }

    func testOptionToggleReachesTheHub() throws {
        let (engine, _, hub) = try makeRig()
        engine.tapManager.onOptionToggle?(.english, .russian)
        XCTAssertEqual(hub.lastLayoutToggle, LayoutToggleNotice(from: .english, to: .russian))
    }

    func testIgnoredReasonReachesTheHub() throws {
        let (engine, _, hub) = try makeRig()
        engine.tapManager.onOptionIgnored?("no_pending_press")
        XCTAssertEqual(hub.lastIgnoredReason, "no_pending_press")
    }

    func testUndoCallbackFeedsLearningAndPublishesTheNotice() throws {
        let (engine, _, hub) = try makeRig(threshold: 3)
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        // The hub's wiring is what drove the strike: nothing else called handleUndo.
        XCTAssertEqual(engine.strikeStore.strikes(for: "ghb"), 1)
        XCTAssertEqual(hub.lastUndo, UndoNotice(
            prefix: "ghb", converted: "при", count: 1, threshold: 3))
        XCTAssertNil(hub.lastLearned)
    }

    func testLearningReachesTheHubAndTheFilter() throws {
        let (engine, _, hub) = try makeRig(threshold: 1)
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        XCTAssertEqual(hub.lastLearned, LearnedNotice(prefix: "ghb", converted: "при"))
        XCTAssertTrue(engine.wordFilter.isExcluded("ghb"))
    }

    func testUndoNoticeIsSuppressedWhenNotificationsAreOff() throws {
        let (engine, _, hub) = try makeRig(threshold: 3, notify: false)
        undoCandidate(engine)
        engine.tapManager.onOptionUndo?(.english, "ghb")
        XCTAssertNil(hub.lastUndo)
        // Suppression is about the notice, not about counting: the strike still lands.
        XCTAssertEqual(engine.strikeStore.strikes(for: "ghb"), 1)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter AppEventHubTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'AppEventHub' in scope`.

- [ ] **Step 3: Implement `AppEventHub`**

Create `Sources/RukeyCore/AppEventHub.swift` per the construction above. `@Published` needs `import Combine`; the three notice structs live in the same file. The private `handle(_ notice: LearningNotice)` is the only writer of `lastUndo`/`lastLearned`; nothing but the wiring closures writes `lastCorrection`, `lastLayoutToggle` and `lastIgnoredReason`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Verify the CLI still builds and behaves**

Run: `swift build 2>&1 | tail -5` → `Build complete!`; `swift run rukey --test-conversion 2>&1 | tail -8` → the same five sample lines. Nothing in `Sources/RukeyApp/` changes in this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/RukeyCore/AppEventHub.swift Tests/
git commit -m "Add AppEventHub, the single fan-out point for GUI events"
git push
```

---

## Out of Scope for This Plan

The GUI shell — `.app` packaging, self-signed certificate, menu bar, settings window, application picker, notifications, correction flash, launch-at-login — is planned separately in `docs/superpowers/plans/2026-10-14-rukey-gui-shell.md`. It consumes `RukeyEngine` from Task 8.

Manual verification of the tap itself (typing, undo, learning) is not automatable in this plan: `EventTapManager` needs a real Accessibility grant and a live keyboard. Do it by hand after Task 7 using `swift run rukey --verbose`, and report anything that contradicts the spec's §6.1–6.3 before starting the GUI plan.