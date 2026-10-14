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
