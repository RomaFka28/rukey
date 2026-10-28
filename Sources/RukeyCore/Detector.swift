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
    // `@unchecked Sendable` is sound because `enTrie`/`ruTrie`/
    // `minTargetCompletions` are immutable after `init`, `minPrefixLength` is
    // guarded by its own `NSLock`, and `wordFilter`/`customDictionary` are
    // independent `@unchecked Sendable` types that guard their own state.
    let enTrie: Trie
    let ruTrie: Trie

    // Mutable at runtime so the settings window can change it without
    // rebuilding the detector: a rebuild means re-arming the tap and dropping
    // input while it is down. Every read goes through the lock — one
    // uncontended acquisition per decision, the same cost the exclusion filter
    // already pays.
    private let prefixLengthLock = NSLock()
    private var storedMinPrefixLength: Int
    public var minPrefixLength: Int {
        get { prefixLengthLock.withLock { storedMinPrefixLength } }
        set { prefixLengthLock.withLock { storedMinPrefixLength = newValue } }
    }
    /// Minimum dictionary completions behind a converted on-the-fly prefix.
    /// Filters junk-backed prefixes (`ghu` exists only via `ghul`): typos like
    /// `прг` no longer flip the layout mid-word. Boundary (full-word) path is
    /// unaffected — exact matches always convert.
    let minTargetCompletions: Int
    /// Words the user never wants converted. Consulted by every path below, so an
    /// excluded word is blocked from its first keystroke rather than corrected.
    let wordFilter: WordFilter
    /// Words the user taught the daemon, which count as real even though neither
    /// shipped trie knows them. Consulted as an extra membership test on both
    /// sides of every conversion: it lets `pfjprplpfjp` become the taught
    /// `заозкздзаоз`, and it keeps that taught word from being flipped back.
    let customDictionary: CustomDictionary

    public init(
        enTrie: Trie,
        ruTrie: Trie,
        minPrefixLength: Int = 3,
        minTargetCompletions: Int = 3,
        wordFilter: WordFilter = WordFilter(),
        customDictionary: CustomDictionary = CustomDictionary()
    ) {
        self.enTrie = enTrie
        self.ruTrie = ruTrie
        self.storedMinPrefixLength = minPrefixLength
        self.minTargetCompletions = minTargetCompletions
        self.wordFilter = wordFilter
        self.customDictionary = customDictionary
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
        let sourceTrie = bufferLang == .russian ? ruTrie : enTrie
        let targetTrie = bufferLang == .russian ? enTrie : ruTrie
        let converted = bufferLang == .russian
            ? LayoutConverter.toEnglish(word)
            : LayoutConverter.toRussian(word)
        let isCurrentValid = fullWord
            ? sourceTrie.contains(word) || customDictionary.contains(word)
            : sourceTrie.hasPrefix(word) || customDictionary.isPrefixOfKnown(word)
        let taughtTarget = fullWord ? false : customDictionary.isPrefixOfKnown(converted)
        let isConvertedValid = fullWord
            ? targetTrie.contains(converted) || customDictionary.contains(converted)
            : targetTrie.hasPrefix(converted) || taughtTarget
        if !isCurrentValid && isConvertedValid {
            if !fullWord,
                !taughtTarget,
                targetTrie.countCompletions(of: converted, limit: minTargetCompletions) < minTargetCompletions
            {
                return nil
            }
            let sourceName = bufferLang == .russian ? "ru" : "en"
            let targetName = bufferLang == .russian ? "en" : "ru"
            return CorrectionDecision(
                originalText: word,
                convertedText: converted,
                sourceLanguage: bufferLang,
                targetLanguage: bufferLang.opposite,
                triggerRule: fullWord
                    ? "full_word_\(sourceName)_to_\(targetName)"
                    : "\(sourceName)_invalid_prefix_\(targetName)_valid"
            )
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
        // A run starting right after a punctuation key that types a letter (`,` types
        // `б`, `[` types `х`, …) is a fragment of a longer token: the characters
        // before it are still unconverted layout output, so flipping the fragment
        // strands them (`[jhji` grew into `[оро…`, `,tkr` into `,елк…`). Such tokens
        // are judged as a whole at the next word boundary instead — `evaluateFullWord`
        // gives the punctuated path the first say.
        if isFragmentOfPunctuatedToken(buffer: buffer, runLength: word.count, runLanguage: bufferLang) {
            return nil
        }
        return decisionIfMistyped(word: word, bufferLang: bufferLang, fullWord: false)
    }

    /// True when the trailing run starts right after a punctuation key that types
    /// a letter of the run's target alphabet (`[` → `х`, `,` → `б`, …). Flipping
    /// such a fragment would strand the unconverted characters before it, so the
    /// on-the-fly conversion is refused and the whole token is judged at the
    /// boundary. A run at the very start of the buffer, or one preceded by a
    /// letter or by key-unmapped punctuation (`(`, `!`, …), is not affected.
    private func isFragmentOfPunctuatedToken(
        buffer: String, runLength: Int, runLanguage: Language
    ) -> Bool {
        let prefix = buffer.dropLast(runLength)
        guard let preceding = prefix.last,
              preceding.unicodeScalars.count == 1,
              let scalar = preceding.unicodeScalars.first
        else { return false }
        guard LayoutConverter.alphabet(of: scalar) == nil else { return false }
        let mapped = LayoutConverter.convert(String(preceding), from: runLanguage)
        return LayoutConverter.detectAlphabet(mapped) == runLanguage.opposite
    }

    /// Evaluates if the current buffer is a completed word and needs conversion.
    public func evaluateFullWord(buffer: String, currentLanguage _: Language) -> CorrectionDecision? {
        // Tokens carrying punctuation are judged as a whole first: the run path
        // splits on the punctuation, so it would convert only a fragment of
        // `[jhjij` or `,tkrf` instead of the word the user actually typed (the
        // shipped `[jhjij` → `[орошо` corruption). Pure-letter tokens fall
        // straight through — the punctuated path admits nothing else.
        if let decision = decisionForPunctuatedToken(in: buffer) {
            return decision
        }
        // Same mixed-alphabet guard as evaluate(): only the trailing run is the real word.
        // `minPrefixLength` (not a hardcoded 3) guards short words like "he"/"my".
        // Still needed as the fallback: `hello,ghbdtn` has no faithful whole-token
        // reading, and only the trailing run may convert there.
        if let (word, bufferLang) = candidateWord(from: buffer, minLength: minPrefixLength),
           let decision = decisionIfMistyped(word: word, bufferLang: bufferLang, fullWord: true)
        {
            return decision
        }
        return nil
    }

    /// Token-aware full-word check for words wrapped in punctuation.
    ///
    /// Two hypotheses, first match wins:
    /// - H1 (faithful): the edges are mislaid letters (`",fu"` → `"баг"`, since
    ///   `,` is `б` in RU). Converts the whole token, checks the stripped result.
    /// - H2 (verbatim): the edges are real punctuation (`"ghbdtn,"` → `"привет,"`).
    ///   Converts only the core, re-attaches the edges untouched.
    /// Pure-letter tokens are skipped — the run path below handles them.
    private func decisionForPunctuatedToken(in buffer: String) -> CorrectionDecision? {
        let token = LayoutConverter.trailingToken(of: buffer)
        guard !token.isEmpty else { return nil }
        let (leading, core, trailing) = LayoutConverter.splitEdgePunctuation(token)
        // Shorter floor than the run path: dictionary membership on both sides is
        // the real guard here (EN words like `he` self-protect via `contains`).
        guard core.count >= 2 else { return nil }
        // Interior punctuation admits a token too: `б`, `ю`, `х`, `ъ`, `ё` sit on
        // punctuation keys, so whole words like `работает` type with punctuation
        // strictly inside the token (`hf,jnftn`). The run path can never see such
        // a token whole — it splits there — so they must be judged on this path.
        let hasInteriorPunctuation = core.unicodeScalars.contains {
            LayoutConverter.alphabet(of: $0) == nil
        }
        guard !leading.isEmpty || !trailing.isEmpty || hasInteriorPunctuation else { return nil }
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
        // Exact membership, both arms, widened with the taught words. This is the
        // punctuated path's third decision site and it must agree with the run
        // path's boundary arm about the same typing — so it takes `contains`, not
        // `isPrefixOfKnown`: prefix protection belongs on the on-the-fly arm only,
        // where the word is still being typed. Adding it here instead would make
        // this path *stricter* than the boundary path (with `ghbdtnabc` taught,
        // `ghbdtn` converts but `ghbdtn!` would not), which is the cross-path
        // disagreement review focus #5 forbids.
        func contains(_ text: String, _ lang: Language) -> Bool {
            lang == .russian
                ? ruTrie.contains(text) || customDictionary.contains(text)
                : enTrie.contains(text) || customDictionary.contains(text)
        }

        // H1 must fail for H2 to be considered. Valid words do reach this path
        // (`evaluateFullWord` falls through to it whenever `decisionIfMistyped`
        // returns nil); this guard, not the caller, is what stops them.
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
