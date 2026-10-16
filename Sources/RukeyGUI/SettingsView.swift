import AppKit
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

/// The «Приложения» tab's model: the excluded-bundle list, the terminal
/// checkbox and the picker sheet's state.
///
/// A live change goes to the `SecureInputMonitor` first — that is what makes an
/// exclusion apply to the very next keystroke, without a relaunch — and the
/// writer then persists the full new set through the app's one `exclude.json`
/// path (re-read, merge, write), mirroring it into `SettingsState` exactly like
/// the words tab's writer does. The search field's text and the sheet's
/// presented flag live here rather than in `@State`, which is a macro whose
/// implementation plugin ships only with Xcode; the Command-Line-Tools
/// toolchain cannot expand it, so the sheet binds through the model.
@MainActor
public final class AppListModel: ObservableObject {
    /// The live exclusions, sorted for display.
    @Published public private(set) var excludedBundleIDs: [String]
    /// Mirrors `SecureInputMonitor.excludeTerminals`.
    @Published public var excludeTerminals: Bool
    /// Whether the «Добавить приложение» sheet is up.
    @Published public var isPickerPresented = false
    /// The text of the sheet's search field, for the same reason as the words
    /// model's input fields.
    @Published public var searchText = ""
    /// The freshly enumerated applications; `results` filters these.
    @Published public private(set) var allApps: [InstalledApp] = []
    /// True while `loadApps()` is enumerating the disk.
    @Published public private(set) var isLoadingApps = true

    private let monitor: SecureInputMonitor
    private let picker: AppPicker
    private let writer: @MainActor (Set<String>) -> Void
    private let terminalsWriter: @MainActor (Bool) -> Void

    public init(
        monitor: SecureInputMonitor,
        picker: AppPicker = AppPicker(),
        excludeTerminals: Bool,
        writer: @escaping @MainActor (Set<String>) -> Void,
        terminalsWriter: @escaping @MainActor (Bool) -> Void
    ) {
        self.monitor = monitor
        self.picker = picker
        self.excludeTerminals = excludeTerminals
        self.excludedBundleIDs = monitor.customExcludedBundleIDs.sorted()
        self.writer = writer
        self.terminalsWriter = terminalsWriter
    }

    /// The sheet's rows: `allApps` matched against `searchText`. Pure and
    /// cheap, so it is recomputed on every render — no change observer needed;
    /// a `@Published` write on `searchText` already rebuilds the body.
    public var results: [InstalledApp] {
        AppPicker.search(searchText, in: allApps)
    }

    /// Re-reads the exclusions from the live monitor. The tab calls this when
    /// it appears, so a change made elsewhere shows up without reopening the
    /// window — same contract as the words tab's `refresh()`. The terminal
    /// flag is re-grounded too: the general tab toggles the same live monitor,
    /// and this keeps the applications checkbox from showing a stale value.
    public func refresh() {
        excludedBundleIDs = monitor.customExcludedBundleIDs.sorted()
        excludeTerminals = monitor.excludeTerminals
    }

    /// Enumerates the installed applications off the main actor. Called when
    /// the sheet appears, so a newly installed app is offered without
    /// relaunching; safe to call repeatedly.
    public func loadApps() async {
        isLoadingApps = true
        allApps = await picker.reload()
        isLoadingApps = false
    }

    /// Opens the picker sheet with a clean query; the sheet's `onAppear` then
    /// loads the application list.
    public func presentPicker() {
        searchText = ""
        isPickerPresented = true
    }

    /// Excludes `bundleID`: trimmed, blanks ignored, and an identifier already
    /// present is left alone. On a real change the monitor is updated first,
    /// then the writer gets the full new set — never a delta — so nothing a
    /// second editor wrote can be dropped.
    public func add(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var ids = monitor.customExcludedBundleIDs
        guard ids.insert(trimmed).inserted else { return }
        monitor.customExcludedBundleIDs = ids
        excludedBundleIDs = ids.sorted()
        writer(ids)
    }

    /// Removes `bundleID` from the exclusions; the full remaining set is
    /// written, so the removal survives a restart.
    public func remove(bundleID: String) {
        var ids = monitor.customExcludedBundleIDs
        guard ids.remove(bundleID) != nil else { return }
        monitor.customExcludedBundleIDs = ids
        excludedBundleIDs = ids.sorted()
        writer(ids)
    }

    /// Mirrors the terminal checkbox: the live monitor first, then the same
    /// persist path, so terminals are excluded from the next keystroke on.
    public func setExcludeTerminals(_ enabled: Bool) {
        guard enabled != excludeTerminals else { return }
        monitor.excludeTerminals = enabled
        excludeTerminals = enabled
        terminalsWriter(enabled)
    }
}

/// The settings window's SwiftUI root: the four tabs, in the spec's order.
///
/// `Слова` and `Приложения` carry their models; `Общее` and `Журнал` bind
/// through the `SettingsStore`, which is also the menu checkbox's writer, so
/// the window and the menu share one source of truth. No control uses `@State`
/// — that is a macro whose implementation plugin ships only with Xcode; the
/// Command-Line-Tools toolchain cannot expand it, so every control binds
/// through the store.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var words: WordListModel
    @ObservedObject var apps: AppListModel

    var body: some View {
        TabView {
            WordsTab(words: words)
                .tabItem { Text("Слова") }
            ApplicationsTab(apps: apps)
                .tabItem { Text("Приложения") }
            GeneralTab(store: store)
                .tabItem { Text("Общее") }
            LogTab(store: store)
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

/// The `Приложения` tab: the excluded-app list with its picker sheet, and the
/// terminal checkbox.
private struct ApplicationsTab: View {
    @ObservedObject var apps: AppListModel

    /// The checkbox binds through the model rather than directly to the
    /// published flag, so a toggle reaches the live monitor and the config
    /// file, not just the view.
    private var terminalsBinding: Binding<Bool> {
        Binding(
            get: { apps.excludeTerminals },
            set: { apps.setExcludeTerminals($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("В этих приложениях Rukey не исправляет раскладку.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Добавить приложение") { apps.presentPicker() }
                Spacer()
            }
            List(apps.excludedBundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    Text(bundleID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        apps.remove(bundleID: bundleID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Убрать «\(bundleID)»")
                }
            }
            .frame(minHeight: 150)
            Toggle("Не трогать терминалы", isOn: terminalsBinding)
                .help(
                    "Terminal, iTerm2 и другие терминалы из встроенного списка тоже пропускаются")
        }
        .padding(16)
        .onAppear { apps.refresh() }
        .sheet(isPresented: $apps.isPickerPresented) {
            AppPickerSheet(apps: apps)
        }
    }
}

/// The `Добавить приложение` sheet: a search field over every installed
/// application, one click adds the row and closes.
private struct AppPickerSheet: View {
    @ObservedObject var apps: AppListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Выберите приложение").font(.headline)
            TextField("Поиск по названию или идентификатору", text: $apps.searchText)
                .textFieldStyle(.roundedBorder)
            Group {
                if apps.isLoadingApps {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if apps.results.isEmpty {
                    Text("Ничего не найдено")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(apps.results) { app in
                        Button {
                            apps.add(bundleID: app.id)
                            apps.isPickerPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).lineLimit(1)
                                Text(app.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Добавить «\(app.name)»")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Закрыть") { apps.isPickerPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 380)
        // Enumerating the disk runs off the main actor; the sheet stays
        // responsive and fills in when `reload()` returns.
        .onAppear { Task { await apps.loadApps() } }
    }
}

/// The `Общее` tab: the scalar settings, each control bound through the store,
/// so a change reaches the live objects and the config file in one call — and
/// a failed launch-at-login registration visibly snaps the checkbox back.
private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Общие настройки").font(.headline)

            Stepper(
                value: Binding(
                    get: { store.minPrefixLength },
                    set: { store.minPrefixLength = $0 }),
                in: RukeyConfig.minPrefixLengthRange
            ) {
                Text("Минимальная длина префикса: \(store.minPrefixLength)")
            }
            .help("Слова короче этого числа не проверяются. Допустимо от 2 до 5.")

            // A plain `Stepper(value:in:)` cannot skip 1 and 4, so the two
            // arrows walk `autoLearnThresholds` one entry at a time.
            Stepper(
                onIncrement: { stepThreshold(up: true) },
                onDecrement: { stepThreshold(up: false) }
            ) {
                Text("Порог автообучения: \(store.autoLearnThreshold)")
            }
            .help(
                "Сколько отмен одной замены нужно, чтобы слово попало в «Не заменять». 0 выключает автообучение."
            )

            Toggle(
                "Уведомлять о каждой отмене",
                isOn: Binding(
                    get: { store.notifyOnEveryUndo },
                    set: { store.notifyOnEveryUndo = $0 }))
            Toggle(
                "Показывать всплывашку после автозамены",
                isOn: Binding(
                    get: { store.showCorrectionFlash },
                    set: { store.showCorrectionFlash = $0 }))
            Toggle(
                "Не трогать терминалы",
                isOn: Binding(
                    get: { store.excludeTerminals },
                    set: { store.excludeTerminals = $0 }))
                .help(
                    "Terminal, iTerm2 и другие терминалы из встроенного списка тоже пропускаются")
            Toggle(
                "Автозапуск при входе",
                isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.launchAtLogin = $0 }))
                .help("Регистрирует LaunchAgent в ~/Library/LaunchAgents")

            HStack {
                Button("Открыть настройки Accessibility") {
                    // The same pane URL the red status row sends the user to.
                    PermissionGate().openSystemSettings()
                }
                Spacer()
            }

            // A failed LaunchAgent write rolled the toggle back; without this
            // line the snap-back would be silent here (the menu logs it).
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(16)
    }

    /// Moves to the next/previous admissible threshold; a current value that is
    /// somehow outside the list falls back to the first entry.
    private func stepThreshold(up: Bool) {
        let values = RukeyConfig.autoLearnThresholds
        let index = values.firstIndex(of: store.autoLearnThreshold) ?? 0
        let next = up ? min(index + 1, values.count - 1) : max(index - 1, 0)
        store.autoLearnThreshold = values[next]
    }
}

/// The `Журнал` tab: the same lines the console printed, newest last, with a
/// level filter and a copy button.
///
/// `LogBuffer` has no notification API — that is a deliberate Core decision —
/// so the tab polls through the store while it is visible: the store
/// republishes only when the buffer's tail changed, so an idle log costs one
/// snapshot read per second and no view update.
private struct LogTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(
                    "",
                    selection: Binding(
                        get: { store.showOnlyErrors },
                        set: { store.showOnlyErrors = $0 })
                ) {
                    Text("Все уровни").tag(false)
                    Text("Только ошибки").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
                Button("Копировать") { copyVisibleLines() }
                    .disabled(store.logLines.isEmpty)
                    .help("Скопировать видимые строки в буфер обмена")
            }
            List(store.logLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.timeText(line.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(line.level.rawValue.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(Self.levelColor(line.level))
                        .frame(width: 56, alignment: .leading)
                    Text(line.text)
                        .font(.callout)
                        .lineLimit(3)
                }
            }
        }
        .padding(16)
        .onAppear { store.beginLogRefresh() }
        .onDisappear { store.endLogRefresh() }
    }

    private func copyVisibleLines() {
        let text = store.logLines
            .map { Self.copyText(for: $0) }
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// One copied line: `[14:05:33] WARN …` — the level included, so a pasted
    /// excerpt keeps the severity the tab shows.
    static func copyText(for line: LogLine) -> String {
        "[\(timeText(line.date))] \(line.level.rawValue.uppercased()) \(line.text)"
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func levelColor(_ level: LogLine.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
