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

  /// Values `autoLearnThreshold` may take, per spec §7 and the GUI stepper.
  public static let autoLearnThresholds = [0, 2, 3, 5]
  /// Inclusive range `minPrefixLength` may take. Below 2 the short-word guard in
  /// `Detector` collapses; above 5 a legit word stops converting.
  public static let minPrefixLengthRange = 2...5

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
    config.autoLearnThreshold = validated(
      shape.autoLearnThreshold, key: "autoLearnThreshold", admissible: Self.autoLearnThresholds,
      fallback: config.autoLearnThreshold, logBuffer: logBuffer)
    config.notifyOnEveryUndo = shape.notifyOnEveryUndo ?? config.notifyOnEveryUndo
    config.showCorrectionFlash = shape.showCorrectionFlash ?? config.showCorrectionFlash
    config.minPrefixLength = validated(
      shape.minPrefixLength, key: "minPrefixLength",
      admissible: Array(Self.minPrefixLengthRange),
      fallback: config.minPrefixLength, logBuffer: logBuffer)
    return config
  }

  /// Writes the whole config atomically to `url`, creating the `~/.config/rukey`
  /// directory when it does not exist. The one writer for this schema: callers
  /// mutate their own copy and hand it over whole, so no two writers can drop
  /// each other's fields. Keys outside the schema are not preserved — the file
  /// belongs to the app — and `verbose` is CLI-only and stays out of it.
  /// - Returns: `false`, and one `.warn` line, when the write fails.
  @discardableResult
  public static func write(
    _ config: RukeyConfig,
    to url: URL = RukeyConfig.configFileURL,
    logBuffer: LogBuffer = LogBuffer.shared
  ) -> Bool {
    // The same `FileShape` that reads the file defines what a write may carry,
    // so a key cannot be added to one side only. Every value below is non-nil,
    // so the synthesized encoder emits all eight keys.
    let shape = FileShape(
      excludeBundleIDs: config.excludedBundleIDs.sorted(),
      excludedWords: config.excludedWords,
      excludeTerminals: config.excludeTerminals,
      launchAtLogin: config.launchAtLogin,
      autoLearnThreshold: config.autoLearnThreshold,
      notifyOnEveryUndo: config.notifyOnEveryUndo,
      showCorrectionFlash: config.showCorrectionFlash,
      minPrefixLength: config.minPrefixLength
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(shape)
      // `~/.config/rukey` does not exist on a fresh install.
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      // Same shape as `readFile`'s warning: the path and the underlying reason.
      logBuffer.log(
        "Could not write \(url.path): \(describe(error)).",
        level: .warn
      )
      return false
    }
  }

  /// Every key is optional so a config file written by an older build still decodes.
  private struct FileShape: Codable {
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
        "Could not use \(url.path): \(describe(error)). Using CLI values only.",
        level: .warn
      )
      return nil
    }
  }

  /// `DecodingError.localizedDescription` is a generic Cocoa string ("The data
  /// couldn't be read because it isn't in the correct format."), and so is
  /// `context.underlyingError.localizedDescription` — on this toolchain the
  /// position of the parse error lives one level deeper, in the underlying
  /// `NSError`'s `NSDebugDescriptionErrorKey`. Surface it, or the user is told
  /// that something is wrong but not what.
  private static func describe(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else { return trimmed(error.localizedDescription) }
    let reason: String
    switch decoding {
    case .dataCorrupted(let context):
      if let underlying = context.underlyingError as NSError?,
        let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String
      {
        reason = detail
      } else {
        reason = context.debugDescription
      }
    case .keyNotFound(let key, let context):
      reason = "missing key \"\(key.stringValue)\": \(context.debugDescription)"
    case .typeMismatch(let type, let context):
      reason = "wrong type for \(type): \(context.debugDescription)"
    case .valueNotFound(let type, let context):
      reason = "missing value for \(type): \(context.debugDescription)"
    @unknown default:
      reason = String(describing: decoding)
    }
    return trimmed(reason)
  }

  /// Foundation's debug strings end in a period and the caller adds its own.
  private static func trimmed(_ text: String) -> String {
    var text = text
    while text.hasSuffix(".") { text.removeLast() }
    return text
  }

  private static func cleaned(_ values: [String]) -> [String] {
    values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Keeps a numeric key only when it is admissible.
  ///
  /// A hand-edited file bypasses the GUI's clamps, and `{"minPrefixLength": 0}`
  /// would dismantle the short-word guard. An out-of-range value falls back to the
  /// documented default and warns — it is *not* clamped to the nearest admissible
  /// value, because silently substituting a value the user never wrote is exactly
  /// what a visible fall-back exists to prevent.
  private static func validated(
    _ value: Int?,
    key: String,
    admissible: [Int],
    fallback: Int,
    logBuffer: LogBuffer
  ) -> Int {
    guard let value else { return fallback }
    guard !admissible.contains(value) else { return value }
    logBuffer.log(
      "\(key) = \(value) is out of range (admissible: "
        + "\(admissible.map(String.init).joined(separator: ", "))); "
        + "falling back to \(fallback).",
      level: .warn
    )
    return fallback
  }
}
