import Combine
import RukeyCore
import SwiftUI

/// The «Слова» tab's model: the two word lists and every edit operation on them.
///
/// The SwiftUI layout is deliberately not tested; this model is, because the
/// add/remove flow is where Review Focus items 4 and 5 live: the writer always
/// receives the *full* new set (never a delta), so two words added in one
/// session end up as a union on disk, and removing a word clears its strikes,
/// so a removed learned word can be learned again from scratch. The writer is
/// the app's one `exclude.json` path — re-read, merge, write — which is what
/// makes a removal survive a restart.
///
/// `strikeStore` is required, never defaulted: a default `StrikeStore()` would
/// point every construction at the real `learned.json` instead of a per-test
/// temporary file.
@MainActor
public final class WordListModel: ObservableObject {
    public let filter: WordFilter
    public let dictionary: CustomDictionary
    public let strikeStore: StrikeStore

    /// The never-replace list, sorted for display.
    @Published public private(set) var excludedWords: [String]
    /// The taught words, sorted for display.
    @Published public private(set) var taughtWords: [String]

    /// The text of the «Не заменять» input field. It lives here rather than in
    /// `@State` because `State()` is a macro whose implementation plugin ships
    /// only with Xcode; the Command-Line-Tools toolchain cannot expand it, so
    /// the field binds through the model.
    @Published public var newExcludedText = ""
    /// The text of the «Мои слова» input field, for the same reason.
    @Published public var newTaughtText = ""

    private let writer: @MainActor (Set<String>) -> Void

    public init(
        filter: WordFilter,
        dictionary: CustomDictionary,
        strikeStore: StrikeStore,
        writer: @escaping @MainActor (Set<String>) -> Void
    ) {
        self.filter = filter
        self.dictionary = dictionary
        self.strikeStore = strikeStore
        self.writer = writer
        self.excludedWords = filter.words.sorted()
        self.taughtWords = dictionary.words.sorted()
    }

    /// Re-reads both lists from the live objects. The tab calls this when it
    /// appears, so a word learned by the engine while the window was already
    /// open shows up without reopening the window.
    public func refresh() {
        excludedWords = filter.words.sorted()
        taughtWords = dictionary.words.sorted()
    }

    /// Adds `word` to the never-replace list: trimmed, blanks ignored, and a
    /// word already present is left alone. On a real change the writer gets the
    /// full new set — never a delta — so nothing a second editor wrote can be
    /// dropped, and the file always holds the union.
    public func addExcluded(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var words = filter.words
        guard words.insert(trimmed).inserted else { return }
        filter.replaceAll(with: words)
        excludedWords = filter.words.sorted()
        writer(filter.words)
    }

    /// Removes `word` from the never-replace list. Its strike count is cleared
    /// too: the learning condition is an exact count match, so a count left at
    /// the old threshold would prevent the word from ever being learned again.
    /// The full remaining set is written, so the removal survives a restart.
    public func removeExcluded(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = filter.words
        guard words.remove(trimmed) != nil else { return }
        filter.replaceAll(with: words)
        strikeStore.removeAllKeys(for: trimmed)
        excludedWords = filter.words.sorted()
        writer(filter.words)
    }

    /// Clears the whole never-replace list, resetting each word's strikes for
    /// the same reason `removeExcluded` does.
    public func clearExcluded() {
        guard !filter.words.isEmpty else { return }
        for word in filter.words {
            strikeStore.removeAllKeys(for: word)
        }
        filter.replaceAll(with: [])
        excludedWords = []
        writer(filter.words)
    }

    /// Adds `word` to the custom dictionary: trimmed, blanks ignored, and a
    /// word already present is left alone. The dictionary persists itself — it
    /// owns `custom.json` — so no config writer is involved here. The word does
    /// *not* go to the filter, which is what keeps «never replace» and «know
    /// this word» two different lists.
    public func addTaught(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var words = dictionary.words
        guard words.insert(trimmed).inserted else { return }
        dictionary.replaceAll(with: words)
        taughtWords = dictionary.words.sorted()
    }

    /// Removes `word` from the custom dictionary.
    public func removeTaught(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = dictionary.words
        guard words.remove(trimmed) != nil else { return }
        dictionary.replaceAll(with: words)
        taughtWords = dictionary.words.sorted()
    }

    /// Clears the whole custom dictionary.
    public func clearTaught() {
        guard !dictionary.words.isEmpty else { return }
        dictionary.replaceAll(with: [])
        taughtWords = []
    }
}

/// The settings window's SwiftUI root: the four tabs, in the spec's order.
///
/// The `Слова` tab carries the words UI; «Приложения», «Общее» and «Журнал» are
/// placeholders whose content arrives in later tasks. Keeping their tabs present
/// now means the window's shape does not change under the user later.
struct SettingsView: View {
    @ObservedObject var words: WordListModel

    var body: some View {
        TabView {
            WordsTab(words: words)
                .tabItem { Text("Слова") }
            PlaceholderTab(text: "Раздел «Приложения» появится позже.")
                .tabItem { Text("Приложения") }
            PlaceholderTab(text: "Раздел «Общее» появится позже.")
                .tabItem { Text("Общее") }
            PlaceholderTab(text: "Раздел «Журнал» появится позже.")
                .tabItem { Text("Журнал") }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}

/// The `Слова` tab: two sections of the same shape — `Не заменять` over the
/// filter and `Мои слова` over the custom dictionary.
private struct WordsTab: View {
    @ObservedObject var words: WordListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WordSection(
                model: words, kind: .excluded,
                title: "Не заменять",
                hint: "Эти слова Rukey не заменяет никогда. Enter добавляет слово.")
            Divider()
            WordSection(
                model: words, kind: .taught,
                title: "Мои слова",
                hint: "Эти слова Rukey считает правильными, даже если их нет в словаре.")
        }
        .padding(16)
        // A word can be learned by the engine while the window is already open;
        // re-reading on appear is enough to show it without extra plumbing.
        .onAppear { words.refresh() }
    }
}

/// One word list: an Enter-submitting text field, the rows with per-row delete
/// buttons, and `Очистить всё`. Each row shows the stored form and, when the
/// letters map cleanly to the other layout, its conversion — `ghb → при`.
private struct WordSection: View {
    enum Kind {
        case excluded
        case taught
    }

    @ObservedObject var model: WordListModel
    let kind: Kind
    let title: String
    let hint: String

    private var entries: [String] {
        switch kind {
        case .excluded: return model.excludedWords
        case .taught: return model.taughtWords
        }
    }

    /// The text field's binding: the field for this section's list.
    private var input: Binding<String> {
        switch kind {
        case .excluded: return $model.newExcludedText
        case .taught: return $model.newTaughtText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Слово", text: input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Очистить всё") { clear() }
                    .disabled(entries.isEmpty)
            }
            List(entries, id: \.self) { word in
                HStack(spacing: 8) {
                    Text(Self.rowTitle(for: word))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        remove(word)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Удалить «\(word)»")
                }
            }
            .frame(minHeight: 110)
        }
    }

    private func add() {
        switch kind {
        case .excluded:
            model.addExcluded(model.newExcludedText)
            model.newExcludedText = ""
        case .taught:
            model.addTaught(model.newTaughtText)
            model.newTaughtText = ""
        }
    }

    private func remove(_ word: String) {
        switch kind {
        case .excluded: model.removeExcluded(word)
        case .taught: model.removeTaught(word)
        }
    }

    private func clear() {
        switch kind {
        case .excluded: model.clearExcluded()
        case .taught: model.clearTaught()
        }
    }

    /// The row text: the stored form alone, or `ghb → при` when a conversion is
    /// known.
    static func rowTitle(for word: String) -> String {
        guard let converted = convertedWord(word), converted != word else { return word }
        return "\(word) → \(converted)"
    }

    /// The other-layout spelling of `word`, when there is one to show: mixed
    /// words and words with no letters have none.
    static func convertedWord(_ word: String) -> String? {
        guard let language = LayoutConverter.detectAlphabet(word) else { return nil }
        return LayoutConverter.convert(word, from: language)
    }
}

/// A tab whose content arrives in a later task.
private struct PlaceholderTab: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 440)
    }
}
