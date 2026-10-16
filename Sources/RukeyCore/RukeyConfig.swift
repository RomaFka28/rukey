import Foundation

/// User configuration: CLI flags merged with optional JSON config file.
public struct RukeyConfig: Sendable {
  /// Words the user never wants corrected, e.g. `["ghbdtn"]`.
  public var excludedWords: [String]
  public var excludeTerminals: Bool
  public var excludedBundleIDs: Set<String>
  public var launchAtLogin: Bool
  /// Strikes an unknown typo needs before the word is learned as valid.
  public var autoLearnThreshold: Int
  public var notifyOnEveryUndo: Bool
  public var showCorrectionFlash: Bool
  public var minPrefixLength: Int
  public var verbose: Bool

  public init(
    excludedWords: [String] = [],
    excludeTerminals: Bool = false,
    excludedBundleIDs: Set<String> = [],
    launchAtLogin: Bool = false,
    autoLearnThreshold: Int = 3,
    notifyOnEveryUndo: Bool = true,
    showCorrectionFlash: Bool = true,
    minPrefixLength: Int = 3,
    verbose: Bool = false
  ) {
    self.excludedWords = excludedWords
    self.excludeTerminals = excludeTerminals
    self.excludedBundleIDs = excludedBundleIDs
    self.launchAtLogin = launchAtLogin
    self.autoLearnThreshold = autoLearnThreshold
    self.notifyOnEveryUndo = notifyOnEveryUndo
    self.showCorrectionFlash = showCorrectionFlash
    self.minPrefixLength = minPrefixLength
    self.verbose = verbose
  }

  /// Config file location: `~/.config/rukey/exclude.json`.
  public static var configFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/rukey/exclude.json")
  }

  /// Merges CLI extras with values from the config file.
  ///
  /// Boolean flag semantics are a union, matching the bundle ID merge: an explicit
  /// `--exclude-terminals` is never undone by a file that says `false`.
  ///
  /// - Parameters:
  ///   - excludeTerminalsFlag: value of `--exclude-terminals`.
  ///   - extraBundleIDs: values passed via repeatable `--exclude-bundle <id>`.
  ///   - verbose: value of `--verbose` / `-v`.
  ///   - configFileURL: file to merge from. Defaults to `~/.config/rukey/exclude.json`.
  ///   - logBuffer: receives a `.warn` line when the file exists but cannot be parsed.
  /// - Returns: merged config. An absent file is silent; an unparseable one warns and
  ///   falls back to the flag-only result.
  public static func load(
    excludeTerminalsFlag: Bool,
    extraBundleIDs: [String],
    verbose: Bool,
    configFileURL: URL = RukeyConfig.configFileURL,
    logBuffer: LogBuffer = LogBuffer.shared
  ) -> RukeyConfig {
    var merged = Set(cleaned(extraBundleIDs))
    var config = RukeyConfig(
      excludeTerminals: excludeTerminalsFlag,
      excludedBundleIDs: merged,
      verbose: verbose
    )
    guard let shape = readFile(at: configFileURL, logBuffer: logBuffer) else { return config }
    if let fromFile = shape.excludeBundleIDs {
      merged.formUnion(cleaned(fromFile))
    }
    config.excludedBundleIDs = merged
    config.excludedWords = cleaned(shape.excludedWords ?? [])
    config.excludeTerminals = excludeTerminalsFlag || (shape.excludeTerminals ?? false)
    config.launchAtLogin = shape.launchAtLogin ?? config.launchAtLogin
    config.autoLearnThreshold = shape.autoLearnThreshold ?? config.autoLearnThreshold
    config.notifyOnEveryUndo = shape.notifyOnEveryUndo ?? config.notifyOnEveryUndo
    config.showCorrectionFlash = shape.showCorrectionFlash ?? config.showCorrectionFlash
    config.minPrefixLength = shape.minPrefixLength ?? config.minPrefixLength
    return config
  }

  /// Every key is optional so a config file written by an older build still decodes.
  private struct FileShape: Decodable {
    var excludeBundleIDs: [String]?
    var excludedWords: [String]?
    var excludeTerminals: Bool?
    var launchAtLogin: Bool?
    var autoLearnThreshold: Int?
    var notifyOnEveryUndo: Bool?
    var showCorrectionFlash: Bool?
    var minPrefixLength: Int?
  }

  private static func readFile(at url: URL, logBuffer: LogBuffer) -> FileShape? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try JSONDecoder().decode(FileShape.self, from: Data(contentsOf: url))
    } catch {
      // The old code swallowed this and silently fell back to defaults; report it
      // so a user who mistyped their config learns why their settings are ignored.
      logBuffer.log(
        "Could not read \(url.path): \(error.localizedDescription). Using CLI flags only.",
        level: .warn
      )
      return nil
    }
  }

  private static func cleaned(_ values: [String]) -> [String] {
    values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
