import Foundation

public enum Language: String, Sendable, CaseIterable {
    case english = "en"
    case russian = "ru"

    public var opposite: Language {
        switch self {
        case .english: return .russian
        case .russian: return .english
        }
    }
}

public struct LayoutConverter: Sendable {
    // English QWERTY to Russian ЙЦУКЕН (macOS standard Russian layout)
    private static let enToRuMap: [Character: Character] = {
        let enChars = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?"
        let ruChars = "ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,"
        var map: [Character: Character] = [:]
        for (e, r) in zip(enChars, ruChars) {
            map[e] = r
        }
        map["@"] = "\""
        map["#"] = "№"
        map["$"] = ";"
        map["^"] = ":"
        map["&"] = "?"
        return map
    }()

    private static let ruToEnMap: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (e, r) in enToRuMap {
            map[r] = e
        }
        return map
    }()

    public init() {}

    /// Validates internal mapping consistency.
    ///
    /// Checks `enToRuMap` / `ruToEnMap` have the same count as the zipped
    /// base strings plus extras, are exact inverses of each other, and
    /// round-trip the canonical probes `ghbdtn`<->`привет`, `руддщ`<->`hello`.
    public static func validateMappings() -> Bool {
        let enChars = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?"
        let ruChars = "ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,"
        guard enChars.count == ruChars.count else { return false }
        // 5 extra mappings (@, #, $, ^, &) on top of the zipped base.
        guard enToRuMap.count == enChars.count + 5 else { return false }
        guard ruToEnMap.count == enToRuMap.count else { return false }
        // Round-trip via raw maps (not via toRussian/toEnglish to avoid
        // re-entering `_validated` during its own lazy initialization).
        func convert(_ text: String, using map: [Character: Character]) -> String {
            String(text.map { map[$0] ?? $0 })
        }
        guard convert("ghbdtn", using: enToRuMap) == "привет" else { return false }
        guard convert("привет", using: ruToEnMap) == "ghbdtn" else { return false }
        guard convert("руддщ", using: ruToEnMap) == "hello" else { return false }
        guard convert("hello", using: enToRuMap) == "руддщ" else { return false }
        for (e, r) in enToRuMap {
            guard ruToEnMap[r] == e else { return false }
        }
        for (r, e) in ruToEnMap {
            guard enToRuMap[e] == r else { return false }
        }
        return true
    }

    private static let _validated: Bool = {
        assert(validateMappings())
        return true
    }()

    /// Converts a string typed in English QWERTY to Russian ЙЦУКЕН.
    public static func toRussian(_ text: String) -> String {
        _ = Self._validated
        return String(text.map { enToRuMap[$0] ?? $0 })
    }

    /// Converts a string typed in Russian ЙЦУКЕН to English QWERTY.
    public static func toEnglish(_ text: String) -> String {
        return String(text.map { ruToEnMap[$0] ?? $0 })
    }

    /// Converts text from source language to target language.
    public static func convert(_ text: String, from source: Language) -> String {
        switch source {
        case .english:
            return toRussian(text)
        case .russian:
            return toEnglish(text)
        }
    }

    /// Heuristic detection of the dominant alphabet in the string.
    /// Fast path over unicode scalars (no per-character `String` allocation,
    /// no range-`contains` on `Character`).
    public static func detectAlphabet(_ text: String) -> Language? {
        var enCount = 0
        var ruCount = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // A-Z / a-z
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) {
                enCount += 1
            } else if (v >= 0x410 && v <= 0x44F) || v == 0x401 || v == 0x451 {
                // А-Я, а-я, Ё, ё
                ruCount += 1
            }
            if enCount > 0 && ruCount > 0 { return nil } // mixed — early exit
        }
        if enCount > 0 && ruCount == 0 { return .english }
        if ruCount > 0 && enCount == 0 { return .russian }
        return nil
    }

    @inline(__always)
    public static func alphabet(of scalar: Unicode.Scalar) -> Language? {
        let v = scalar.value
        if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) { return .english }
        if (v >= 0x410 && v <= 0x44F) || v == 0x401 || v == 0x451 { return .russian }
        return nil
    }

    /// Returns the trailing run of characters that belong to a single alphabet.
    ///
    /// A buffer can legitimately become mixed: an auto-correction inserts Russian text
    /// while the physical layout has not switched yet, so the next keys still yield Latin
    /// characters. Evaluating the whole buffer then fails (detectAlphabet returns nil) and
    /// correction silently stops. Only the trailing homogeneous run is the current word.
    public static func trailingScriptRun(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        // Walk scalars backwards to find the run boundary without allocating
        // a `String` per character (previous version did `detectAlphabet(String(char))`).
        let scalars = text.unicodeScalars
        var runAlphabet: Language?
        var start = scalars.endIndex
        var i = scalars.index(before: scalars.endIndex)
        while true {
            guard let a = alphabet(of: scalars[i]) else { break }
            if let existing = runAlphabet, existing != a { break }
            runAlphabet = a
            start = i
            if i == scalars.startIndex { break }
            i = scalars.index(before: i)
        }
        guard start != scalars.endIndex else { return "" }
        return String(scalars[start..<scalars.endIndex])
    }

    /// Returns the trailing run of non-whitespace characters (letters + punctuation).
    ///
    /// Unlike `trailingScriptRun`, punctuation does not split the token: `",fu"` stays
    /// one token. Used by the full-word path so punctuation-attached words (`",fu"`,
    /// `"ghbdtn"`) can convert as a whole instead of being silently dropped.
    public static func trailingToken(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        var i = text.endIndex
        while i > text.startIndex {
            let prev = text.index(before: i)
            if text[prev].isWhitespace { break }
            i = prev
        }
        return String(text[i..<text.endIndex])
    }

    /// Strips leading/trailing characters that belong to neither alphabet.
    public static func stripSurroundingPunctuation(_ token: String) -> String {
        splitEdgePunctuation(token).core
    }

    /// Splits a token into verbatim edge punctuation and the letter core.
    public static func splitEdgePunctuation(_ token: String) -> (
        leading: String, core: String, trailing: String
    ) {
        var core = token
        while let first = core.first,
            first.unicodeScalars.allSatisfy({ alphabet(of: $0) == nil })
        {
            core.removeFirst()
        }
        while let last = core.last,
            last.unicodeScalars.allSatisfy({ alphabet(of: $0) == nil })
        {
            core.removeLast()
        }
        guard !core.isEmpty, let range = token.range(of: core) else {
            return ("", token, "")
        }
        return (
            String(token[..<range.lowerBound]), core, String(token[range.upperBound...])
        )
    }
}
