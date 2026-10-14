import Foundation

/// User configuration: CLI flags merged with optional JSON config file.
public struct RukeyConfig: Sendable {
  public var excludeTerminals: Bool
  public var excludedBundleIDs: Set<String>
  public var verbose: Bool

  public init(excludeTerminals: Bool, excludedBundleIDs: Set<String>, verbose: Bool) {
    self.excludeTerminals = excludeTerminals
    self.excludedBundleIDs = excludedBundleIDs
    self.verbose = verbose
  }

  /// Config file location: `~/.config/rukey/exclude.json`.
  public static var configFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/rukey/exclude.json")
  }

  /// Merges CLI extras with bundle IDs from the config file.
  ///
  /// - Parameters:
  ///   - excludeTerminalsFlag: value of `--exclude-terminals`.
  ///   - extraBundleIDs: values passed via repeatable `--exclude-bundle <id>`.
  ///   - verbose: value of `--verbose` / `-v`.
  /// - Returns: merged config. Missing/unparseable file is silently ignored.
  public static func load(
    excludeTerminalsFlag: Bool,
    extraBundleIDs: [String],
    verbose: Bool
  ) -> RukeyConfig {
    var merged = Set(extraBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })
    if let fromFile = loadBundleIDsFromFile() {
      merged.formUnion(fromFile)
    }
    return RukeyConfig(
      excludeTerminals: excludeTerminalsFlag,
      excludedBundleIDs: merged,
      verbose: verbose
    )
  }

  private struct FileShape: Decodable {
    var excludeBundleIDs: [String]?
  }

  private static func loadBundleIDsFromFile() -> Set<String>? {
    let url = configFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let shape = try? JSONDecoder().decode(FileShape.self, from: data) else { return nil }
    guard let ids = shape.excludeBundleIDs else { return nil }
    let cleaned = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Set(cleaned)
  }
}
