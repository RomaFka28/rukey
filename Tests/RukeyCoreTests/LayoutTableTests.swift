import Testing
@testable import RukeyCore

/// Layout tables are read from the running system, not hardcoded. These tests assert the
/// specific key codes keycode_probe confirmed on this machine, so a regression in the
/// loader (wrong modifier flags, wrong keyboard type, a shifted lookup) fails here.
///
/// Note: this project uses swift-testing, not XCTest. XCTest needs a full Xcode install;
/// Command Line Tools alone cannot resolve the module. See PLAN.md.
@Suite("Layout tables read from the system")
struct LayoutTableTests {

    @Test("Russian layout exposes the full 33-letter alphabet")
    func russianLayoutIsComplete() throws {
        let table = try LayoutLoader.load(language: .russian)
        #expect(table.chars.count == 33, "expected the full 33-letter Russian alphabet")

        // Cyrillic letters on keys US uses for punctuation. These break first if the
        // candidate key-code list is too narrow.
        let expected: [UInt16: Character] = [
            30: "ъ", 33: "х", 39: "э", 41: "ж", 42: "ё", 43: "б", 47: "ю",
        ]
        for (keyCode, character) in expected {
            #expect(
                table.character(forKeyCode: keyCode) == character,
                "key code \(keyCode) should produce \(character)"
            )
        }
    }

    @Test("English layout carries letters and nothing else")
    func englishLayoutIsLettersOnly() throws {
        let table = try LayoutLoader.load(language: .english)
        // 26 letters. Punctuation must not leak in, or "-" would look like a letter and
        // the inverse map used for re-decoding would be wrong.
        #expect(table.chars.count == 26)
        #expect(table.character(forKeyCode: 27) == nil, "key code 27 is '-', not a letter")
        #expect(table.character(forKeyCode: 44) == nil, "key code 44 is '/', not a letter")
        #expect(table.character(forKeyCode: 0) == "a")
        #expect(table.character(forKeyCode: 45) == "n")
    }

    @Test("inverse map is complete and reversible", arguments: zip(Language.allCases, ["en", "ru"]))
    func inverseMapRoundTrips(language: Language, _ name: String) throws {
        let table = try LayoutLoader.load(language: language)
        for (keyCode, character) in table.chars {
            #expect(
                table.keyCodes[character] == keyCode,
                "\(name): \(character) must map back to \(keyCode)"
            )
        }
    }

    @Test("keys identical in both layouts are never letters", arguments: [27, 44])
    func sharedPunctuationIsExcluded(keyCode: UInt16) throws {
        for language in Language.allCases {
            let table = try LayoutLoader.load(language: language)
            #expect(
                table.character(forKeyCode: UInt16(keyCode)) == nil,
                "\(language.rawValue): key code \(keyCode) is identical in both layouts"
            )
        }
    }

    @Test("ё normalizes to е in dictionary lookups")
    func yoFoldsToYe() {
        let index = DictionaryIndex(words: ["ёлка", "привет"])
        #expect(index.contains("елка"), "ё must match е")
        #expect(index.contains("ёлка"), "the folded form of ёлка must be found")
        #expect(index.contains("привет"))
        #expect(!index.contains("ёлка и медведь"), "unrelated text must not match")
    }
}