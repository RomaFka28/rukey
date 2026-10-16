import Foundation
import UserNotifications

/// `UNUserNotificationCenter` wrapper: permission, and the two notification
/// kinds the engine produces.
///
/// The bodies are built from the *exact* strings `RukeyCore` already logs —
/// `Отменено: …` from `UndoLearningController.handleUndo` and
/// `Запомнено: …` from the same method — so a banner and the corresponding
/// menu row (or console line) can never disagree.
///
/// The undo notice is gated **upstream**: `UndoLearningController` emits
/// `.undo` only when the live `notifyOnEveryUndo` is true, exactly like the
/// console's own `Отменено:` line. This service therefore adds **no second
/// gate** — gating here again would be how the menu and the notifications
/// drift apart. The learned notice is always attempted.
///
/// An unauthorised (or not-yet-authorised) centre is not an error: the public
/// methods check `isAuthorized` and return quietly, and `add` failures are
/// swallowed.
///
/// **Construction hazard:** `UNUserNotificationCenter.current()` aborts a
/// process that is not a real bundle ("bundleProxyForCurrentProcess is nil").
/// The default initialiser argument evaluates at the call site, so the caller
/// must construct this service only when `Bundle.main.bundleIdentifier != nil`
/// — `AppDelegate.buildEngineIfNeeded` owns that guard, which is what keeps
/// `swift run` and the test harness quiet.
@MainActor
public final class NotificationService {
    private let center: UNUserNotificationCenter

    /// The last answer to `requestAuthorization()`; notices are only attempted
    /// once it is true, so a denied (or never-asked) centre stays quiet.
    public private(set) var isAuthorized = false

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Asks for `.alert` and `.sound` and records the answer. A refused prompt
    /// is not an error — every method returns quietly.
    public func requestAuthorization() async {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        isAuthorized = granted
    }

    /// `«prefix» → «converted» (count/threshold)` — the same text as the
    /// engine's `Отменено:` line. Already gated upstream (see the type's
    /// documentation); no `notifyOnEveryUndo` check lives here.
    public func showUndoNotice(
        prefix: String, converted: String, count: Int, threshold: Int
    ) async {
        guard isAuthorized else { return }
        await deliver(
            body: "Отменено: \(prefix) → \(converted) (\(count)/\(threshold))")
    }

    /// `«prefix» больше не станет «converted»` — the same text as the engine's
    /// `.warn` `Запомнено:` line, which is also the menu banner's row. Always
    /// attempted; the icon flash is the status item's own.
    public func showLearnedNotice(prefix: String, converted: String) async {
        guard isAuthorized else { return }
        await deliver(body: "Запомнено: \(prefix) больше не станет \(converted)")
    }

    /// One immediate notification, one unique identifier so consecutive
    /// notices cannot replace each other. A centre that refuses the request
    /// simply does not deliver; it must not surface as an error.
    private func deliver(body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Rukey"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}
