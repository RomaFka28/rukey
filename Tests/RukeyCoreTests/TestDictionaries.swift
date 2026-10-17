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
        // Words carrying punctuation-mapped letters strictly inside them
        // (`б`, `ю`, `х`, `ъ`, `ё` sit on punctuation keys, so `hf,jnftn`
        // spells `работает`). "орошо" is a truncated non-word that shipped in
        // `words_ru.txt`; it is kept here on purpose so the token/fragment
        // ordering is pinned against a dictionary that still contains it.
        "работает", "любит", "ухо", "объяснить", "объём",
        "белка", "елка", "беда", "еда", "хорошо", "орошо",
        "ясно", "ясность", "ясный",
    ]
    static func makeTrie(_ words: [String]) -> Trie {
        let trie = Trie()
        trie.insert(contentsOf: words)
        return trie
    }
    static let enTrie = makeTrie(englishWords)
    static let ruTrie = makeTrie(russianWords)
}
