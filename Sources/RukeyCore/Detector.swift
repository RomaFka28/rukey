import Foundation

public struct CorrectionDecision: Equatable, Sendable {
    public let originalText: String
    public let convertedText: String
    public let sourceLanguage: Language
    public let targetLanguage: Language
    public let triggerRule: String

    public init(
        originalText: String,
        convertedText: String,
        sourceLanguage: Language,
        targetLanguage: Language,
        triggerRule: String
    ) {
        self.originalText = originalText
        self.convertedText = convertedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.triggerRule = triggerRule
    }
}

public final class Detector: @unchecked Sendable {
    public let enTrie: Trie
    public let ruTrie: Trie
    public let minPrefixLength: Int
    /// Minimum dictionary completions behind a converted on-the-fly prefix.
    /// Filters junk-backed prefixes (`ghu` exists only via `ghul`): typos like
    /// `прг` no longer flip the layout mid-word. Boundary (full-word) path is
    /// unaffected — exact matches always convert.
    public let minTargetCompletions: Int
    /// Words the user never wants converted. Consulted by every path below, so an
    /// excluded word is blocked from its first keystroke rather than corrected.
    public let wordFilter: WordFilter

    public init(
        enTrie: Trie,
        ruTrie: Trie,
        minPrefixLength: Int = 3,
        minTargetCompletions: Int = 3,
        wordFilter: WordFilter = WordFilter()
    ) {
        self.enTrie = enTrie
        self.ruTrie = ruTrie
        self.minPrefixLength = minPrefixLength
        self.minTargetCompletions = minTargetCompletions
        self.wordFilter = wordFilter
    }

    /// Common pre-step: isolate the trailing homogeneous script run and
    /// classify its alphabet. Returns nil when there is nothing to evaluate.
    private func candidateWord(from buffer: String, minLength: Int) -> (word: String, lang: Language)? {
        let word = LayoutConverter.trailingScriptRun(of: buffer)
        guard word.count >= minLength else { return nil }
        guard let lang = LayoutConverter.detectAlphabet(word) else { return nil }
        return (word, lang)
    }

    private func decisionIfMistyped(word: String, bufferLang: Language, fullWord: Bool) -> CorrectionDecision? {
        // Excluded words never convert, in either mode. Checked first, before any
        // trie work, so a hit costs one prefix lookup and nothing else. This single
        // gate covers both callers (on-the-fly `evaluate` and boundary
        // `evaluateFullWord`), which pass the identical `word`.
        guard !wordFilter.isPrefixOfExcluded(word) else { return nil }
        if bufferLang == .russian {
            let converted = LayoutConverter.toEnglish(word)
            let isCurrentValid = fullWord ? ruTrie.contains(word) : ruTrie.hasPrefix(word)
            let isConvertedValid = fullWord ? enTrie.contains(converted) : enTrie.hasPrefix(converted)
            if !isCurrentValid && isConvertedValid {
                // On-the-fly only: demand a well-backed target prefix, otherwise a
                // typo + one junk dictionary entry flips the layout (see `ghul`).
                if !fullWord && enTrie.countCompletions(of: converted, limit: minTargetCompletions) < minTargetCompletions {
                    return nil
                }
                return CorrectionDecision(
                    originalText: word,
                    convertedText: converted,
                    sourceLanguage: .russian,
                    targetLanguage: .english,
                    triggerRule: fullWord ? "full_word_ru_to_en" : "ru_invalid_prefix_en_valid"
                )
            }
        } else {
            let converted = LayoutConverter.toRussian(word)
            let isCurrentValid = fullWord ? enTrie.contains(word) : enTrie.hasPrefix(word)
            let isConvertedValid = fullWord ? ruTrie.contains(converted) : ruTrie.hasPrefix(converted)
            if !isCurrentValid && isConvertedValid {
                if !fullWord && ruTrie.countCompletions(of: converted, limit: minTargetCompletions) < minTargetCompletions {
                    return nil
                }
                return CorrectionDecision(
                    originalText: word,
                    convertedText: converted,
                    sourceLanguage: .english,
                    targetLanguage: .russian,
                    triggerRule: fullWord ? "full_word_en_to_ru" : "en_invalid_prefix_ru_valid"
                )
            }
        }
        return nil
    }

    /// Evaluates the current buffer against dictionaries and layout conversions.
    ///
    /// - Parameters:
    ///   - buffer: The word buffer accumulated so far.
    ///   - currentLanguage: Reserved for future use (system language hint).
    ///     Currently ignored: during synthetic switches the buffer may hold letters
    ///     from the previous layout, so the buffer alphabet is authoritative.
    /// - Returns: A CorrectionDecision if correction should be triggered, nil otherwise.
    public func evaluate(buffer: String, currentLanguage _: Language) -> CorrectionDecision? {
        // A buffer can become mixed when an auto-correction inserts text while the physical
        // layout has not switched yet. Evaluating the whole buffer would then fail on the
        // mixed alphabet and stop correction entirely, so evaluate only the trailing run.
        guard let (word, bufferLang) = candidateWord(from: buffer, minLength: minPrefixLength) else {
            return nil
        }
        return decisionIfMistyped(word: word, bufferLang: bufferLang, fullWord: false)
    }

    /// Evaluates if the current buffer is a completed word and needs conversion.
    public func evaluateFullWord(buffer: String, currentLanguage _: Language) -> CorrectionDecision? {
        // Same mixed-alphabet guard as evaluate(): only the trailing run is the real word.
        // `minPrefixLength` (not a hardcoded 3) guards short words like "he"/"my".
        if let (word, bufferLang) = candidateWord(from: buffer, minLength: minPrefixLength),
           let decision = decisionIfMistyped(word: word, bufferLang: bufferLang, fullWord: true)
        {
            return decision
        }
        // Punctuation-attached words: `",fu"` or `"ghbdtn"` never reach the run path
        // intact (the run splits on punctuation), so convert the whole token while
        // checking dictionary membership on the stripped core.
        return decisionForPunctuatedToken(in: buffer)
    }

    /// Token-aware full-word check for words wrapped in punctuation.
    ///
    /// Two hypotheses, first match wins:
    /// - H1 (faithful): the edges are mislaid letters (`",fu"` → `"баг"`, since
    ///   `,` is `б` in RU). Converts the whole token, checks the stripped result.
    /// - H2 (verbatim): the edges are real punctuation (`"ghbdtn,"` → `"привет,"`).
    ///   Converts only the core, re-attaches the edges untouched.
    /// Pure-letter tokens are skipped — the run path above already handled them.
    private func decisionForPunctuatedToken(in buffer: String) -> CorrectionDecision? {
        let token = LayoutConverter.trailingToken(of: buffer)
        guard !token.isEmpty else { return nil }
        let (leading, core, trailing) = LayoutConverter.splitEdgePunctuation(token)
        // Shorter floor than the run path: dictionary membership on both sides is
        // the real guard here (EN words like `he` self-protect via `contains`).
        guard core.count >= 2 else { return nil }
        guard !leading.isEmpty || !trailing.isEmpty else { return nil }
        // Same exclusion gate as the run path — same predicate, not a weaker one —
        // and on the extracted core rather than the raw token, so `"ghbdtn,"` is
        // blocked by excluding `"ghbdtn"` rather than the comma-attached token.
        // Prefix, not exact: the *token* is complete but the *word* need not be.
        // `"ntcn"` is complete, yet excluding `"ntcnbhjdfnm"` must stop it here too,
        // or the same typing converts on this path and is blocked on the run path.
        guard !wordFilter.isPrefixOfExcluded(core) else { return nil }
        guard let bufferLang = LayoutConverter.detectAlphabet(core) else { return nil }

        func convert(_ text: String, _ lang: Language) -> String {
            lang == .russian ? LayoutConverter.toEnglish(text) : LayoutConverter.toRussian(text)
        }
        func contains(_ text: String, _ lang: Language) -> Bool {
            lang == .russian ? ruTrie.contains(text) : enTrie.contains(text)
        }

        // H1 must fail for H2 to be considered; valid words never reach here
        // (callers check `contains(core)` first via the run path contract).
        guard !contains(core, bufferLang) else { return nil }

        // H1: faithful conversion of the entire token.
        let faithful = convert(token, bufferLang)
        let faithfulCore = LayoutConverter.stripSurroundingPunctuation(faithful)
        if contains(faithfulCore, bufferLang.opposite) {
            return CorrectionDecision(
                originalText: token,
                convertedText: faithful,
                sourceLanguage: bufferLang,
                targetLanguage: bufferLang.opposite,
                triggerRule: "full_word_punct_faithful"
            )
        }

        // H2: core conversion with verbatim edges.
        let coreConverted = LayoutConverter.stripSurroundingPunctuation(
            convert(core, bufferLang))
        if contains(coreConverted, bufferLang.opposite) {
            return CorrectionDecision(
                originalText: token,
                convertedText: leading + convert(core, bufferLang) + trailing,
                sourceLanguage: bufferLang,
                targetLanguage: bufferLang.opposite,
                triggerRule: "full_word_punct_verbatim"
            )
        }
        return nil
    }
}
