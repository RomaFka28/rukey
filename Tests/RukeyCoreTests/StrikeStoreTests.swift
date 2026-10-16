import XCTest
@testable import RukeyCore

final class StrikeStoreTests: XCTestCase {
    private func makeStore() -> (StrikeStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json")
        return (StrikeStore(fileURL: url), url)
    }

    func testFreshStoreHasNoStrikes() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.strikes(for: "ghb"), 0)
    }

    func testRegisteringIncrementsAndReturnsTheCount() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.registerUndo(key: "ghb"), 1)
        XCTAssertEqual(store.registerUndo(key: "ghb"), 2)
        XCTAssertEqual(store.strikes(for: "ghb"), 2)
    }

    func testKeysAreIndependent() {
        let (store, _) = makeStore()
        store.registerUndo(key: "ghb")
        store.registerUndo(key: "hello")
        XCTAssertEqual(store.strikes(for: "ghb"), 1)
        XCTAssertEqual(store.strikes(for: "hello"), 1)
    }

    func testCountsSurviveReopen() {
        let (store, url) = makeStore()
        store.registerUndo(key: "ghb")
        store.registerUndo(key: "ghb")
        let reopened = StrikeStore(fileURL: url)
        XCTAssertEqual(reopened.strikes(for: "ghb"), 2)
    }

    func testCorruptFileStartsEmptyAndReports() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json")
        try? "{ broken".write(to: url, atomically: true, encoding: .utf8)
        let buffer = LogBuffer()
        let store = StrikeStore(fileURL: url, logBuffer: buffer)
        XCTAssertEqual(store.strikes(for: "ghb"), 0)
        XCTAssertTrue(buffer.lines().contains { $0.level == .warn })
    }

    func testRemoveAllClearsEveryKey() {
        let (store, url) = makeStore()
        store.registerUndo(key: "ghb")
        store.removeAll()
        XCTAssertEqual(store.strikes(for: "ghb"), 0)
        // Clearing has to reach the file here too: a restart must not resurrect
        // what the user removed, or the word can never be learned again.
        let reopened = StrikeStore(fileURL: url)
        XCTAssertEqual(reopened.strikes(for: "ghb"), 0)
    }

    func testRemoveAllKeysForPrefixClearsOnlyThatBranchAndPersists() {
        let (store, url) = makeStore()
        store.registerUndo(key: "ghbdtn")
        store.registerUndo(key: "ntcn")
        store.removeAllKeys(for: "ghb")
        XCTAssertEqual(store.strikes(for: "ghbdtn"), 0)
        XCTAssertEqual(store.strikes(for: "ntcn"), 1)
        // Clearing has to reach the file: a restart must not resurrect what the
        // user removed, or the word can never be learned again.
        let reopened = StrikeStore(fileURL: url)
        XCTAssertEqual(reopened.strikes(for: "ghbdtn"), 0)
        XCTAssertEqual(reopened.strikes(for: "ntcn"), 1)
    }
}

final class UndoLearningTests: XCTestCase {
    /// Records config writes. A reference box, because `configWriter` is
    /// `@escaping @Sendable` and Swift 6 forbids capturing a mutable local in it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Set<String>] = []
        func record(_ words: Set<String>) { lock.withLock { stored.append(words) } }
        var writes: [Set<String>] { lock.withLock { stored } }
    }

    private struct Harness {
        let controller: UndoLearningController
        let filter: WordFilter
        let recorder: Recorder
        var persisted: [Set<String>] { recorder.writes }
    }

    private func makeHarness(words: Set<String> = []) -> Harness {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter(words: words)
        let recorder = Recorder()
        return Harness(
            controller: UndoLearningController(
                strikeStore: store,
                wordFilter: filter,
                thresholdProvider: { 3 },
                notifyProvider: { true },
                configWriter: { recorder.record($0) }
            ),
            filter: filter,
            recorder: recorder
        )
    }

    func testNilUndoIsIgnored() {
        let h = makeHarness()
        h.controller.handleUndo(nil)
        XCTAssertTrue(h.filter.isEmpty)
    }

    func testStrikeBelowThresholdDoesNotExclude() {
        let h = makeHarness()
        h.controller.handleUndo((original: "ghb", converted: "при"))
        h.controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertTrue(h.filter.isEmpty)
    }

    func testThirdUndoExcludesThePrefix() {
        let h = makeHarness()
        for _ in 0..<3 {
            h.controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertTrue(h.filter.isExcluded("ghb"))
        // The learned word is inert from its first keystroke: every shorter run
        // toward it is a prefix of an excluded word.
        XCTAssertTrue(h.filter.isPrefixOfExcluded("g"))
        XCTAssertTrue(h.filter.isPrefixOfExcluded("gh"))
        // `isPrefixOfExcluded` asks "is this a prefix of an excluded word", not
        // the other way around: a longer word that merely starts with the
        // learned word is not protected, so `ghbdtn` → `привет` still converts.
        XCTAssertFalse(h.filter.isPrefixOfExcluded("ghbdtn"))
    }

    func testLearningPersistsToConfigExactlyOnce() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter()
        let recorder = Recorder()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: filter,
            thresholdProvider: { 3 },
            notifyProvider: { true },
            configWriter: { recorder.record($0) }
        )
        for _ in 0..<5 {
            controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertEqual(recorder.writes.count, 1)
        XCTAssertEqual(recorder.writes.first, ["ghb"])
    }

    func testThresholdZeroNeverLearns() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: filter,
            thresholdProvider: { 0 },
            notifyProvider: { false },
            configWriter: { _ in }
        )
        for _ in 0..<10 {
            controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertTrue(filter.isEmpty)
    }

    func testLogsThePairInMenuForm() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let buffer = LogBuffer()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 3 },
            notifyProvider: { true },
            configWriter: { _ in },
            logBuffer: buffer
        )
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertTrue(buffer.lines().contains {
            $0.text == "Отменено: ghb → при (1/3)"
        })
    }

    func testLogsTheLearnedRuleWhenItLands() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let buffer = LogBuffer()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 1 },
            notifyProvider: { false },
            configWriter: { _ in },
            logBuffer: buffer
        )
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertTrue(buffer.lines().contains {
            $0.level == .warn && $0.text == "Запомнено: ghb больше не станет при"
        })
    }

    func testNotificationSuppressedWhenDisabled() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let buffer = LogBuffer()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 3 },
            notifyProvider: { false },
            configWriter: { _ in },
            logBuffer: buffer
        )
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertFalse(buffer.lines().contains { $0.text.contains("Отменено") })
    }

    private final class NoticeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [LearningNotice] = []
        func record(_ notice: LearningNotice) { lock.withLock { stored.append(notice) } }
        var notices: [LearningNotice] { lock.withLock { stored } }
    }

    func testNoticesMirrorTheTwoLines() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let filter = WordFilter()
        let recorder = NoticeRecorder()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: filter,
            thresholdProvider: { 3 },
            notifyProvider: { true },
            configWriter: { _ in }
        )
        controller.onNotice = { recorder.record($0) }
        for _ in 0..<3 {
            controller.handleUndo((original: "ghb", converted: "при"))
        }
        XCTAssertEqual(recorder.notices, [
            .undo(prefix: "ghb", converted: "при", count: 1, threshold: 3),
            .undo(prefix: "ghb", converted: "при", count: 2, threshold: 3),
            .learned(prefix: "ghb", converted: "при"),
        ])
        XCTAssertTrue(filter.isExcluded("ghb"))
    }

    func testLearnedNoticeSurvivesNotificationsBeingOff() {
        let store = StrikeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString).json"))
        let recorder = NoticeRecorder()
        let controller = UndoLearningController(
            strikeStore: store,
            wordFilter: WordFilter(),
            thresholdProvider: { 2 },
            notifyProvider: { false },
            configWriter: { _ in }
        )
        controller.onNotice = { recorder.record($0) }
        controller.handleUndo((original: "ghb", converted: "при"))
        controller.handleUndo((original: "ghb", converted: "при"))
        XCTAssertEqual(recorder.notices, [.learned(prefix: "ghb", converted: "при")])
    }
}
