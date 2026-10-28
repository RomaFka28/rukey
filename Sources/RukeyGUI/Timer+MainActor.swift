import Foundation

extension Timer {
    /// Schedules a repeating timer on the main run loop's `.common` mode and
    /// hands every tick to a main-actor closure.
    ///
    /// Timers added to `RunLoop.main` fire on the main thread, so the
    /// `assumeIsolated` is sound; centralising the dance keeps that reasoning
    /// in one place instead of five hand-copied timer blocks.
    static func scheduleOnMain(
        interval: TimeInterval, tick: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated(tick)
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
