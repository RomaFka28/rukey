import Foundation

/// One installed application, as the applications tab sees it: the bundle
/// identifier and a display name.
///
/// Plain data on purpose: the picker's search is a pure function over an array
/// of these, so the matching rules are testable without a disk or a window.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    /// The bundle identifier (`CFBundleIdentifier`); the row's identity and the
    /// value stored in `exclude.json`.
    public let id: String
    /// `CFBundleDisplayName`, or the bundle's directory name when it has none.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Finds installed applications and searches them for the picker sheet.
///
/// `reload()` enumerates `searchPaths` for `.app` bundles; the enumeration
/// touches the disk, so it runs inside a detached task and the method's
/// isolation brings the result back to the main actor for the UI. `search` is
/// a pure function over the returned array — it never touches disk, which is
/// also why it is `nonisolated`: the tests are plain `XCTestCase` methods and
/// could not call a main-actor-isolated member synchronously.
@MainActor
public final class AppPicker {
    /// The standard locations an installed app may live in: the system folders
    /// plus the per-user one. Enumeration order is also de-duplication
    /// priority, so a name in the first folder shadows the same identifier in
    /// a later one.
    public static let defaultSearchPaths: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications"),
    ]

    /// Where `reload()` looks; injectable so a future test can point the
    /// enumeration at a fixture directory instead of the real `/Applications`.
    public let searchPaths: [URL]

    public init(searchPaths: [URL] = AppPicker.defaultSearchPaths) {
        self.searchPaths = searchPaths
    }

    /// Re-reads the installed applications: every `.app` bundle directly under
    /// each search path, de-duplicated by bundle identifier (the first hit
    /// wins), sorted by localised name. Bundles without a `CFBundleIdentifier`
    /// are dropped — the identifier is the only thing the monitor can exclude
    /// by, so an anonymous bundle has nothing to contribute.
    public func reload() async -> [InstalledApp] {
        let paths = searchPaths
        return await Task.detached(priority: .userInitiated) {
            Self.enumerate(in: paths)
        }.value
    }

    /// Matches `query` against the display name and the bundle identifier,
    /// case-insensitively; an empty query matches everything. The result is
    /// always sorted by localised name — the input order is never preserved.
    public nonisolated static func search(
        _ query: String, in apps: [InstalledApp]
    ) -> [InstalledApp] {
        let sorted = sortedByName(apps)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// The disk half of `reload()`, `nonisolated` so it runs inside the
    /// detached task rather than on the main actor.
    private nonisolated static func enumerate(in paths: [URL]) -> [InstalledApp] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for path in paths {
            let entries =
                (try? fileManager.contentsOfDirectory(
                    at: path, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            for url in entries where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                    let identifier = bundle.bundleIdentifier,
                    !identifier.isEmpty,
                    // First hit wins: a later folder's copy of an app the user
                    // has already been offered is noise, not a second choice.
                    seen.insert(identifier).inserted
                else { continue }
                let displayName =
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                apps.append(
                    InstalledApp(
                        id: identifier,
                        name: displayName.flatMap { $0.isEmpty ? nil : $0 }
                            ?? url.deletingPathExtension().lastPathComponent))
            }
        }
        return sortedByName(apps)
    }

    private nonisolated static func sortedByName(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
