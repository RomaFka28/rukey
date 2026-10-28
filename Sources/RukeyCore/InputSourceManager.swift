import Carbon
import Foundation

public final class InputSourceManager: @unchecked Sendable {
    public static let shared = InputSourceManager()

    private var cachedSources: [Language: TISInputSource] = [:]
    private let lock = NSLock()

    public init() {
        refreshInputSources()
    }

    /// Safely reads a CFString TIS property without taking ownership.
    /// Wraps the `Unmanaged.fromOpaque(takeUnretainedValue)` boilerplate so callers
    /// don't duplicate it (and can't accidentally take ownership).
    private func stringProperty(of source: TISInputSource, key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        let value = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
        return value as String
    }

    /// Safely reads a CFArray-of-strings TIS property without taking ownership.
    private func stringArrayProperty(of source: TISInputSource, key: CFString) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
    }

    /// Debug check that both layouts were found after a refresh.
    /// Returns true when both `.english` and `.russian` are cached; prints a
    /// warning (no crash) otherwise so missing layouts are visible in logs.
    @discardableResult
    private func validateMappings() -> Bool {
        let hasEnglish = cachedSources[.english] != nil
        let hasRussian = cachedSources[.russian] != nil
        #if DEBUG
        assert(
            hasEnglish && hasRussian,
            "InputSourceManager: missing cached sources (english: \(hasEnglish), russian: \(hasRussian))"
        )
        #endif
        if !hasEnglish || !hasRussian {
            print(
                "Warning: InputSourceManager missing sources after refresh "
                    + "(english: \(hasEnglish), russian: \(hasRussian))"
            )
            return false
        }
        return true
    }

    /// Scans available keyboard input sources and caches English and Russian sources.
    func refreshInputSources() {
        lock.lock()
        defer { lock.unlock() }
            cachedSources.removeAll()
            guard let categoryKeyboard = kTISCategoryKeyboardInputSource else { return }
            let filter =
                [
                    kTISPropertyInputSourceCategory: categoryKeyboard,
                    kTISPropertyInputSourceIsSelectCapable: true,
                ] as CFDictionary

            guard
                let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
                    as? [TISInputSource]
            else {
                return
            }

            for source in list {
                // The list was already category-filtered by
                // `TISCreateInputSourceList`; no per-source re-check needed.
                let langs = stringArrayProperty(of: source, key: kTISPropertyInputSourceLanguages)
                for lang in langs {
                    if lang.hasPrefix("en") && cachedSources[.english] == nil {
                        cachedSources[.english] = source
                    } else if lang.hasPrefix("ru") && cachedSources[.russian] == nil {
                        cachedSources[.russian] = source
                    }
                }

                // Also check ID as fallback
                if let id = stringProperty(of: source, key: kTISPropertyInputSourceID) {
                    if (id.contains("US") || id.contains("ABC") || id.contains("English"))
                        && cachedSources[.english] == nil
                    {
                        cachedSources[.english] = source
                    } else if (id.contains("Russian") || id.contains("ru"))
                        && cachedSources[.russian] == nil
                    {
                        cachedSources[.russian] = source
                    }
                }
            }
        validateMappings()
    }

    /// Returns the currently active input source language.
    public func currentLanguage() -> Language {
        guard let currentSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return .english
        }
        let langs = stringArrayProperty(of: currentSource, key: kTISPropertyInputSourceLanguages)
        for lang in langs {
            if lang.hasPrefix("ru") { return .russian }
            if lang.hasPrefix("en") { return .english }
        }
        if let id = stringProperty(of: currentSource, key: kTISPropertyInputSourceID) {
            if id.contains("Russian") || id.contains("ru") {
                return .russian
            }
        }
        return .english
    }

    /// Language that Rukey believes is currently active.
    /// TISCopyCurrentKeyboardInputSource can lag behind a programmatic switch, so we keep
    /// our own record of what we applied. Toggling from a stale read makes two presses
    /// cancel each other out (net zero), which is why repeated Option taps appeared broken.
    private var appliedLanguage: Language?
    private var lastAppliedAt: Date?

    /// Selects the input source for the requested language and records it as applied.
    ///
    /// TISSelectInputSource is called directly from the CGEventTap callback, where macOS
    /// intermittently refuses the switch. A silent failure leaves `appliedLanguage` stale,
    /// so the next Option tap computes its target from the wrong language and appears to
    /// do nothing. Retrying makes the recorded layout match the one actually applied.
    @discardableResult
    public func apply(language: Language) -> Bool {
        if select(language: language) {
            recordApplied(language)
            return true
        }
        // Retry once: TISSelectInputSource is intermittently flaky inside the event tap.
        if select(language: language) {
            recordApplied(language)
            return true
        }
        // Do NOT record a failed switch, otherwise the cached language stays
        // stuck while the physical layout never changed.
        return false
    }

    private func recordApplied(_ language: Language) {
        lock.lock()
        appliedLanguage = language
        lastAppliedAt = Date()
        lock.unlock()
    }

    /// Language Rukey believes is currently active.
    ///
    /// `TISCopyCurrentKeyboardInputSource` can lag behind a programmatic switch, so right
    /// after `apply` we trust what we tried to apply for a short grace window.
    /// After that, the real system value always wins and refreshes our cache — otherwise the
    /// cache drifts from reality and Option-toggle starts fighting the user's manual layout.
    public func effectiveLanguage() -> Language {
        lock.lock()
        let applied = appliedLanguage
        let appliedAt = lastAppliedAt
        lock.unlock()

        let system = currentLanguage()
        if system == applied {
            return system
        }
        if let appliedAt, Date().timeIntervalSince(appliedAt) < 0.6 {
            return applied ?? system
        }
        recordApplied(system)
        return system
    }

    /// Selects the input source for the requested language.
    @discardableResult
    public func select(language: Language) -> Bool {
        var sourceToSelect: TISInputSource?
        lock.lock()
        sourceToSelect = cachedSources[language]
        lock.unlock()

        if sourceToSelect == nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshInputSources() }
            return false
        }

        let status = TISSelectInputSource(sourceToSelect!)
        return status == noErr
    }
}
