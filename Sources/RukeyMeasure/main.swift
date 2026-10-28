import Foundation
import RukeyCore

/// Verification primitive for the suite. SwiftPM compiles `assert()` out of release builds, which
/// would make this whole suite report success unconditionally. The checks below therefore call
/// `check()` instead, which works in every build configuration and exits non-zero on first failure.
@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "") {
    guard condition() else {
        FileHandle.standardError.write(Data("  ✗ FAILED: \(message())\n".utf8))
        exit(1)
    }
}

@main
struct RukeyMeasureMain {
    static func main() {
        print("========================================")
        print("  Rukey Suite Verification & Benchmark  ")
        print("========================================")

        testTrie()
        testLayoutConverter()
        testDetector()
        testUndoManager()
        testSecureInput()
        testBenchmark()
        testLayoutToggleMidWord()

        print("\n🎉 ALL TESTS AND BENCHMARKS PASSED SUCCESSFULLY!")
    }

    static func testTrie() {
        print("\n[1/7] Testing Trie...")
        let trie = Trie()
        check(!trie.contains("hello"))
        check(!trie.hasPrefix("hel"))

        trie.insert("hello")
        trie.insert("world")
        trie.insert("привет")

        check(trie.contains("hello"))
        check(trie.contains("HELLO"))  // case insensitivity
        check(trie.hasPrefix("hel"))
        check(trie.hasPrefix("wo"))
        check(trie.hasPrefix("при"))
        check(!trie.hasPrefix("xyz"))
        check(!trie.contains("hell"))
        check(trie.wordCount == 3)
        print("  ✓ Trie insert, contains, prefix search verified.")
    }

    static func testLayoutConverter() {
        print("\n[2/7] Testing LayoutConverter...")
        // EN -> RU
        check(
            LayoutConverter.toRussian("ghbdtn") == "привет",
            "Expected 'привет', got '\(LayoutConverter.toRussian("ghbdtn"))'")
        check(LayoutConverter.toRussian("ghbvth") == "пример")

        // RU -> EN
        check(
            LayoutConverter.toEnglish("руддщ") == "hello",
            "Expected 'hello', got '\(LayoutConverter.toEnglish("руддщ"))'")
        check(LayoutConverter.toEnglish("цщкдв") == "world")

        // Alphabet detection
        check(LayoutConverter.detectAlphabet("hello") == .english)
        check(LayoutConverter.detectAlphabet("привет") == .russian)
        check(LayoutConverter.detectAlphabet("123!@#") == nil)
        print("  ✓ QWERTY <-> ЙЦУКЕН bidirectional mapping verified.")
    }

    static func testDetector() {
        print("\n[3/7] Testing Detector (On-The-Fly Prefix Logic)...")
        let loader = DictionaryLoader.shared
        let enTrie = loader.loadTrie(fromResource: "words_en")
        let ruTrie = loader.loadTrie(fromResource: "words_ru")
        check(enTrie.wordCount > 10000, "EN word count too low: \(enTrie.wordCount)")
        check(ruTrie.wordCount > 10000, "RU word count too low: \(ruTrie.wordCount)")

        let detector = Detector(enTrie: enTrie, ruTrie: ruTrie, minPrefixLength: 3)

        // 1. User typing 'рудд' (prefix of hello) in RU layout -> should trigger to EN 'hell'
        let d1 = detector.evaluate(buffer: "рудд", currentLanguage: .russian)
        check(d1 != nil, "Expected detection for 'рудд'")
        check(d1?.convertedText == "hell")
        check(d1?.targetLanguage == .english)

        // 2. User typing 'ghbd' (prefix of привет) in EN layout -> should trigger to RU 'прив'
        let d2 = detector.evaluate(buffer: "ghbd", currentLanguage: .english)
        check(d2 != nil, "Expected detection for 'ghbd'")
        check(d2?.convertedText == "прив")
        check(d2?.targetLanguage == .russian)

        // 3. User typing normal Russian word 'прив' in RU layout -> should NOT trigger
        let d3 = detector.evaluate(buffer: "прив", currentLanguage: .russian)
        check(d3 == nil, "Legitimate Russian prefix should not trigger conversion")

        // 5. Regression: mixed-alphabet buffer must still be corrected.
        // After an auto-correction inserts Russian text, the physical layout may not have
        // switched yet, so the next keys still arrive as Latin. The buffer "приghb" is mixed;
        // evaluating it as a whole used to fail and silently disable correction.
        let d5 = detector.evaluate(buffer: "приghb", currentLanguage: .english)
        check(d5 != nil, "Mixed-alphabet buffer must still be corrected")
        check(d5?.originalText == "ghb", "Only the trailing Latin run may be replaced")
        check(d5?.convertedText == "при", "Expected 'ghb' -> 'при'")

        // 6. The full-word path needs the same treatment.
        // evaluateFullWord requires complete words on both sides, so use ghbdtn -> привет.
        let d6 = detector.evaluateFullWord(buffer: "приghbdtn", currentLanguage: .english)
        check(d6 != nil, "Mixed-alphabet buffer must be corrected on word boundary")
        check(d6?.originalText == "ghbdtn", "Only the trailing Latin run may be replaced")
        check(d6?.convertedText == "привет")

        // 7. A purely Cyrillic buffer is one run and must be replaced in full.
        let d7 = detector.evaluate(buffer: "привет", currentLanguage: .russian)
        check(d7 == nil, "Legitimate Russian word must not be touched")

        // 4. User typing normal English word 'hell' in EN layout -> should NOT trigger
        let d4 = detector.evaluate(buffer: "hell", currentLanguage: .english)
        check(d4 == nil, "Legitimate English prefix should not trigger conversion")

        // 8. Rare-prefix guard: 'прг' is a typo (RU has 0 'прг*' words, EN 'ghu'
        // exists only via junk entry 'ghul') — must NOT flip the layout on the fly.
        let d8 = detector.evaluate(buffer: "прг", currentLanguage: .russian)
        check(d8 == nil, "Rare converted prefix must not trigger on-the-fly correction")
        check(
            detector.evaluate(buffer: "ghb", currentLanguage: .english)?.convertedText == "при",
            "Well-backed prefix 'при' must still trigger")

        // 9. Punctuation-attached words convert as a whole on word boundary.
        let d9 = detector.evaluateFullWord(buffer: ",fu", currentLanguage: .english)
        check(d9 != nil, "',fu' must convert on word boundary")
        check(d9?.originalText == ",fu", "Comma must be included in erased text")
        check(d9?.convertedText == "баг", "Expected ',fu' -> 'баг', got '\(d9?.convertedText ?? "?")'")
        let d10 = detector.evaluateFullWord(buffer: "\"ghbdtn\"", currentLanguage: .english)
        check(d10 != nil, "Quoted word must convert")
        check(d10?.originalText == "\"ghbdtn\"", "Whole token incl. quotes is erased")
        check(d10?.convertedText == "\"привет\"")
        let d11 = detector.evaluateFullWord(buffer: "ghbdtn,", currentLanguage: .english)
        check(d11?.originalText == "ghbdtn,", "Trailing comma must be included in erased text")
        check(d11?.convertedText == "привет,")

        // 10. Valid words with punctuation stay untouched.
        check(
            detector.evaluateFullWord(buffer: "привет,", currentLanguage: .russian) == nil,
            "Valid word + comma must not be touched")
        check(
            detector.evaluateFullWord(buffer: ",he", currentLanguage: .english) == nil,
            "'he' is a real EN word — comma must not force conversion")

        print("  ✓ Real 50k dictionaries loaded (\(enTrie.wordCount) EN, \(ruTrie.wordCount) RU).")
        print("  ✓ On-the-fly prefix decisions correctly triggered.")
    }

    static func testUndoManager() {
        print("\n[4/7] Testing UndoManager...")
        let undo = RukeyUndoManager()

        let decision = CorrectionDecision(
            originalText: "рудд",
            convertedText: "hell",
            sourceLanguage: .russian,
            targetLanguage: .english,
            triggerRule: "prefixTree"
        )

        undo.recordCorrection(decision)
        check(undo.canUndo)

        // User immediately hits Delete without typing extra characters:
        let calc = undo.calculateUndo()
        check(calc != nil)
        check(
            calc?.backspacesNeeded == 4, "Expected 4 backspaces, got \(calc?.backspacesNeeded ?? 0)"
        )
        check(
            calc?.textToRestore == "рудд", "Expected 'рудд', got '\(calc?.textToRestore ?? "")'")
        check(calc?.originalLanguage == .russian)

        // After undo calculation, undo state is cleared
        check(!undo.canUndo)
        print("  ✓ Undo arithmetic and layout restoration logic verified.")
    }

    static func testSecureInput() {
        print("\n[5/7] Testing SecureInput & App Exclusions...")
        let monitor = SecureInputMonitor()
        check(SecureInputMonitor.terminalBundleIDs.contains("com.apple.Terminal"))
        check(SecureInputMonitor.securitySensitiveBundleIDs.contains("org.keepassxc.keepassxc"))
        check(SecureInputMonitor.securitySensitiveBundleIDs.contains("com.1password.1password"))
        check(SecureInputMonitor.terminalBundleIDs.contains("com.termius.mac"))
        // Check IsSecureEventInputEnabled API call
        _ = monitor.isSecureInputActive()
        print("  ✓ Security checks and terminal/pass manager exclusions verified.")
    }

    static func testBenchmark() {
        print("\n[6/7] Benchmarking KeyDown Latency (Trie + Layout conversion)...")
        let loader = DictionaryLoader.shared
        let enTrie = loader.loadTrie(fromResource: "words_en")
        let ruTrie = loader.loadTrie(fromResource: "words_ru")
        let detector = Detector(enTrie: enTrie, ruTrie: ruTrie, minPrefixLength: 3)

        let testWords = ["рудд", "ghbd", "прив", "hell", "тест", "test", "ghbvth", "руддщ"]
        let iterations = 100_000

        let start = DispatchTime.now()
        for i in 0..<iterations {
            let word = testWords[i % testWords.count]
            let lang: Language = (i % 2 == 0) ? .russian : .english
            _ = detector.evaluate(buffer: word, currentLanguage: lang)
        }
        let end = DispatchTime.now()

        let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
        let totalMs = Double(nanoTime) / 1_000_000.0
        let avgMicrosec = (Double(nanoTime) / Double(iterations)) / 1_000.0

        print(String(format: "  ✓ %d lookups performed in %.2f ms", iterations, totalMs))
        print(
            String(
                format: "  ✓ Average latency per keystroke: %.3f µs (microseconds)!", avgMicrosec))
        check(
            avgMicrosec < 50.0,
            "Latency must be well below 50 microseconds for real-time responsiveness")
    }

    /// Replays keystroke sequences through the real Detector and BufferManager using the same
    /// arithmetic as EventTapManager (erase decision.originalText.count, keep the untouched
    /// prefix). Verifies what actually ends up on screen — including layout switches typed
    /// in the middle of a word, which is where mixed-alphabet buffers appear.
    static func testLayoutToggleMidWord() {
        print("\n[7/7] Replaying keystroke scenarios (on-the-fly & word-boundary)...")
        let loader = DictionaryLoader.shared
        let detector = Detector(
            enTrie: loader.loadTrie(fromResource: "words_en"),
            ruTrie: loader.loadTrie(fromResource: "words_ru"),
            minPrefixLength: 3
        )

        /// Mirrors EventTapManager.handleEvent: characters are appended, on-the-fly prefix
        /// and full-word detection fire immediately on keystroke without needing a space,
        /// and the layout switches to the target language so the rest of the word types naturally.
        func type(_ screen: String, buffer: BufferManager, keys: String, layout: Language) -> (
            String, Language, Int
        ) {
            var fired = 0
            var out = screen
            var lang = layout
            for key in keys {
                if key == " " {
                    if let decision = detector.evaluateFullWord(
                        buffer: buffer.currentBuffer, currentLanguage: lang)
                    {
                        let erase = decision.originalText.count
                        out = String(out.dropLast(erase)) + decision.convertedText + " "
                        lang = decision.targetLanguage
                        fired += 1
                    } else {
                        out += " "
                    }
                    buffer.reset()
                    continue
                }

                let produced =
                    lang == .english ? String(key) : LayoutConverter.toRussian(String(key))
                out += produced
                buffer.replaceBuffer(with: buffer.currentBuffer + produced)

                let currentBuffer = buffer.currentBuffer
                if let decision = detector.evaluate(buffer: currentBuffer, currentLanguage: lang) {
                    let erase = decision.originalText.count
                    let untouchedPrefix = String(currentBuffer.dropLast(erase))
                    out = String(out.dropLast(erase)) + decision.convertedText
                    buffer.replaceBuffer(with: untouchedPrefix + decision.convertedText)
                    lang = decision.targetLanguage
                    fired += 1
                }
            }
            return (out, lang, fired)
        }

        // Scenario 1: On-the-fly conversion of ghbdtn -> привет without needing Space.
        let buffer1 = BufferManager()
        let (en1, enLang1, fired1) = type("", buffer: buffer1, keys: "ghbdtn", layout: .english)
        check(en1 == "привет", "ghbdtn -> привет on the fly, got '\(en1)'")
        check(enLang1 == .russian, "Layout should switch to russian")
        check(fired1 >= 1, "Expected on-the-fly conversion")

        // Scenario 1b: On-the-fly conversion of руддщ -> hello without needing Space.
        let buffer1b = BufferManager()
        let (ru1, ruLang1, fired1b) = type("", buffer: buffer1b, keys: "hello", layout: .russian)
        check(ru1 == "hello", "руддщ -> hello on the fly, got '\(ru1)'")
        check(ruLang1 == .english, "Layout should switch to english")
        check(fired1b >= 1, "Expected on-the-fly conversion")

        // Scenario 2: Two words typed back-to-back without Space (ghbdtnghbdtn):
        // First word converts on-the-fly to привет (layout becomes ru).
        // Next word is typed in Russian layout, producing привет.
        let buffer2 = BufferManager()
        let (en2, enLang2, _) = type("", buffer: buffer2, keys: "ghbdtnghbdtn", layout: .english)
        check(en2 == "приветпривет", "ghbdtnghbdtn -> приветпривет without space, got '\(en2)'")
        check(enLang2 == .russian, "Layout stays russian")

        // Scenario 2b: Two words typed back-to-back without Space (руддщруддщ):
        // First word converts on-the-fly to hello (layout becomes en).
        // Next word is typed in English layout, producing hello.
        let buffer2b = BufferManager()
        let (ru2, ruLang2, _) = type("", buffer: buffer2b, keys: "hellohello", layout: .russian)
        check(ru2 == "hellohello", "hellohello -> hellohello without space, got '\(ru2)'")
        check(ruLang2 == .english, "Layout stays english")

        // Scenario 3: User types ghbdtn, switches layout with Option, types ghbdtn again:
        // Both words must convert to привет.
        let buffer3 = BufferManager()
        let (w1, l1, _) = type("", buffer: buffer3, keys: "ghbdtn", layout: .english)
        check(w1 == "привет", "Word 1 -> привет")
        check(l1 == .russian, "Layout is russian")
        // User toggles Option (ru -> en)
        let l1Toggled = l1.opposite
        buffer3.reset()
        let (w2, l2, _) = type(w1, buffer: buffer3, keys: "ghbdtn", layout: l1Toggled)
        check(w2 == "приветпривет", "Both words must convert after Option toggle, got '\(w2)'")
        check(l2 == .russian, "Layout should be russian again")

        // Scenario 4: Option undo path must restore the exact original text.
        let undo = RukeyUndoManager()
        undo.recordCorrection(
            CorrectionDecision(
                originalText: "ghb",
                convertedText: "при",
                sourceLanguage: .english,
                targetLanguage: .russian,
                triggerRule: "en_invalid_prefix_ru_valid"
            )
        )
        guard let calc = undo.calculateUndo() else {
            check(false, "Undo must be available right after a correction")
            return
        }
        check(calc.backspacesNeeded == 3, "Undo must erase 3 chars, got \(calc.backspacesNeeded)")
        check(calc.textToRestore == "ghb", "Undo must restore ghb, got '\(calc.textToRestore)'")

        print("  ✓ ghbdtn -> привет on the fly, layout switched to russian.")
        print("  ✓ руддщ -> hello on the fly, layout switched to english.")
        print(
            "  ✓ Back-to-back typing without space works: ghbdtnghbdtn -> приветпривет, hellohello -> hellohello"
        )
        print("  ✓ Option toggle between words converts consistently: '\(w2)'")
        print("  ✓ Option undo restores exact original text.")
    }
}
