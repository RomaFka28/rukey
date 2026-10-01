// Pure decision logic: given the typed buffer and the current layout, decide whether the
// word is being typed in the wrong layout, and what it should become.
//
// No CGEvent, no TISInputSourceRef, no globals. This is the only part worth testing
// exhaustively, and it must stay testable without a running event tap.

import Foundation

/// What the detector decided about the current buffer.
public enum Intent: Equatable, Sendable {
    /// The buffer is fine in the current layout. Do nothing.
    case correct

    /// The buffer is not a word here, but the same physical keys spell a word in the
    /// other layout. Convert it.
    case convert(to: Language, text: String)

    /// Not enough evidence either way. Keep buffering.
    case undecided
}

/// How strictly the re-decoded prefix has to look like the other language.
///
/// Measured on the real corpora, top-1000 by frequency, replayed keystroke by keystroke
/// through the real `KeyboardEngine` (`swift run rukey-measure`):
///
///     wholeWord  L=2   FP ru 25.5%  FP en 3.4%  caught en→ru 92.8%  ru→en 58.4%  mid 93%
///     wholeWord  L=3   FP ru  3.3%  FP en 0.9%  caught en→ru 94.3%  ru→en 68.0%  mid 75%
///     wholeWord  L=4   FP ru  0.0%  FP en 0.2%  caught en→ru 83.1%  ru→en 64.2%  mid 37%
///     prefixTree L=3   FP ru  5.0%  FP en 3.3%  caught en→ru 94.4%  ru→en 68.7%  mid 87%
///     prefixTree L=4   FP ru  0.1%  FP en 0.3%  caught en→ru 83.2%  ru→en 64.2%  mid 67%
///
/// The rule is not a free choice on top of a threshold, it trades against it:
///
/// - At L=3 the prefix tree buys 0.1% detection and costs 1.7% more false positives on
///   Russian. At L=4 it costs a little detection and nearly eliminates them, but the floor
///   is not zero: it accepts prefixes, so `днее` slips through because `lytt` begins
///   `lytton`.
/// - Russian words mistyped on an English layout are caught far less often (68% vs 94%),
///   and no threshold fixes that - it is a property of the two word lists.
///
/// L=3 with `wholeWord` is the default: 94.3% detection, 3.3% false positives on Russian,
/// still firing before the last letter in 75% of cases. The residual is accepted because
/// Delete-to-undo exists for it. `prefixTree` at L=4 is the low-false-positive alternative.
public enum MatchRule: Sendable {
    /// Fire only if the re-decoded prefix is itself a dictionary word.
    case wholeWord

    /// Fire if the re-decoded prefix is a prefix of some dictionary word. Reacts sooner,
    /// but only pays off at L=4.
    case prefixTree

    func matches(_ candidate: String, words: DictionaryIndex) -> Bool {
        switch self {
        case .wholeWord: words.contains(candidate)
        case .prefixTree: words.contains(candidate) || words.containsPrefix(candidate)
        }
    }
}

public struct Detector: Sendable {
    /// Minimum characters before we are willing to act.
    public var minimumEvidence: Int

    /// How the re-decoded prefix is judged.
    public var rule: MatchRule

    /// Cap on how many characters we are willing to rewrite. Bounds the synthetic-event
    /// count and rejects runaway buffers.
    public var maximumRewritableLength: Int

    private let english: LanguageTable
    private let russian: LanguageTable
    private let languages: [Language]

    public init(
        english: LanguageTable,
        russian: LanguageTable,
        minimumEvidence: Int = 3,
        rule: MatchRule = .wholeWord,
        maximumRewritableLength: Int = 64
    ) {
        self.english = english
        self.russian = russian
        self.minimumEvidence = minimumEvidence
        self.rule = rule
        self.maximumRewritableLength = maximumRewritableLength
        self.languages = [.english, .russian]
    }

    public var languageTables: [Language: LanguageTable] {
        [.english: english, .russian: russian]
    }

    /// Decides what to do with `buffer`, typed while `current` was the active layout.
    public func intent(for buffer: String, current: Language) -> Intent {
        guard buffer.count >= minimumEvidence else { return .undecided }
        guard buffer.count <= maximumRewritableLength else { return .correct }

        guard let currentTable = languageTables[current] else { return .correct }

        // Correct in the current layout -> never touch it. This is the check that keeps
        // a user typing normally from being "corrected".
        if currentTable.contains(buffer) { return .correct }

        for other in languages where other != current {
            guard let otherTable = languageTables[other] else { continue }
            guard let converted = currentTable.reencode(buffer, into: otherTable) else { continue }
            if rule.matches(converted, words: otherTable.words) {
                return .convert(to: other, text: converted)
            }
        }
        return .undecided
    }
}

/// A language's layout table plus its word list, with the re-decode operation.
public struct LanguageTable: Sendable {
    public let language: Language
    public let layout: LayoutTable
    /// The word list, exposed so the match rule can test prefixes against it.
    public let words: DictionaryIndex
    private let keyCodes: [Character: UInt16]

    public init(language: Language, layout: LayoutTable, dictionary: DictionaryIndex) {
        self.language = language
        self.layout = layout
        self.keyCodes = layout.keyCodes
        self.words = dictionary
    }

    /// Is this a word in this language? Yo is normalized to е on both sides, because the
    //  user does not type ё and the dictionary may list it.
    public func contains(_ word: String) -> Bool {
        words.contains(word) || words.contains(Normalization.foldYo(word))
    }

    /// Re-decode: which characters in `other` would the same physical keys produce?
    ///
    /// Returns nil if any character of `word` has no key code here, meaning the text was
    /// not produced by this layout in the first place.
    ///
    /// A successful conversion is single-alphabet by construction: every output character
    /// comes from one table, so a mixed-alphabet result cannot be produced here. Mixed
    //  text can only arise from a non-atomic rewrite, which is prevented at the tap.
    public func reencode(_ word: String, into other: LanguageTable) -> String? {
        var out = ""
        out.reserveCapacity(word.count)
        for ch in word {
            guard let keyCode = keyCodes[ch], let produced = other.layout.character(forKeyCode: keyCode) else {
                return nil
            }
            out.append(produced)
        }
        return out
    }
}

public enum Normalization {
    /// Yo to ye. Applied to dictionary lookups, not to displayed text: the conversion must
    /// leave whatever the user typed alone.
    public static func foldYo(_ s: String) -> String {
        s.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
    }
}