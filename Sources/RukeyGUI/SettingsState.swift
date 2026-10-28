import RukeyCore

/// The GUI's single live copy of the user's settings.
///
/// Initialised from the launch-time `RukeyConfig.load`; everything downstream
/// (learning thresholds, notification flags, the settings window) reads
/// current values from here instead of capturing a `RukeyConfig` snapshot,
/// because a GUI whose settings change at runtime must see those changes
/// without a restart.
@MainActor
public final class SettingsState {
    public var minPrefixLength: Int
    public var autoLearnThreshold: Int
    public var notifyOnEveryUndo: Bool
    public var showCorrectionFlash: Bool
    public var excludeTerminals: Bool
    public var launchAtLogin: Bool

    public init(config: RukeyConfig) {
        minPrefixLength = config.minPrefixLength
        autoLearnThreshold = config.autoLearnThreshold
        notifyOnEveryUndo = config.notifyOnEveryUndo
        showCorrectionFlash = config.showCorrectionFlash
        excludeTerminals = config.excludeTerminals
        launchAtLogin = config.launchAtLogin
    }
}
