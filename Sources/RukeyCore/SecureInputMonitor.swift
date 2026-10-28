import AppKit
import Carbon
import Foundation

public final class SecureInputMonitor: @unchecked Sendable {
  // `@unchecked Sendable` is sound because the frontmost-app TTL cache is
  // guarded by `cacheLock`, `excludeTerminals` and `customExcludedBundleIDs`
  // by their own `settingsLock`, and `secureInputCheck`/`frontmostBundleID`
  // are immutable `@Sendable` closures. Every path takes the two locks
  // separately, never one while holding the other.
  public static let shared = SecureInputMonitor()

  /// Bundles that should ALWAYS be bypassed for security (password managers, Keychain).
  public static let securitySensitiveBundleIDs: Set<String> = [
    "org.keepassxc.keepassxc",
    "com.agilebits.onepassword",
    "com.1password.1password",
    "com.bitwarden.desktop",
    "com.lastpass.LastPass",
    "com.apple.keychainaccess",
  ]

  /// Optional terminal bundle identifiers.
  public static let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "io.alacritty",
    "net.kovidgoyal.kitty",
    "com.mitchellh.ghostty",
    "com.termius-danilevsky.mac",
    "com.termius.mac",
  ]

  // The app-exclusion settings are mutable at runtime so the settings window
  // can change them without rebuilding the tap: one `NSLock` guards both, kept
  // separate from `cacheLock` (which guards the frontmost-app TTL cache and is
  // never held together with this one). One uncontended acquisition per read is
  // negligible next to the `IsSecureEventInputEnabled()` syscall already on the
  // per-keystroke path.
  private let settingsLock = NSLock()
  private var storedExcludeTerminals: Bool
  private var storedCustomExcludedBundleIDs: Set<String>

  public var excludeTerminals: Bool {
    get { settingsLock.withLock { storedExcludeTerminals } }
    set { settingsLock.withLock { storedExcludeTerminals = newValue } }
  }
  public var customExcludedBundleIDs: Set<String> {
    get { settingsLock.withLock { storedCustomExcludedBundleIDs } }
    set { settingsLock.withLock { storedCustomExcludedBundleIDs = newValue } }
  }
  private let secureInputCheck: @Sendable () -> Bool
  private let frontmostBundleID: @Sendable () -> String?

  // Throttle for `frontmostApplication` (NSWorkspace IPC, main-thread-affine).
  // Called on EVERY keystroke before — now cached for 0.5 s.
  private let cacheLock = NSLock()
  private var cachedBundleID: String?
  private var cachedAt: Date = .distantPast
  private static let bundleCacheTTL: TimeInterval = 0.5

  public init(
    excludeTerminals: Bool = false,
    customExcludedBundleIDs: Set<String> = [],
    secureInputCheck: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
    frontmostBundleID: @escaping @Sendable () -> String? = {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
  ) {
    self.storedExcludeTerminals = excludeTerminals
    self.storedCustomExcludedBundleIDs = customExcludedBundleIDs
    self.secureInputCheck = secureInputCheck
    self.frontmostBundleID = frontmostBundleID
  }

  /// Checks if macOS SecureEventInput is currently active (password fields, system prompts).
  public func isSecureInputActive() -> Bool {
    return secureInputCheck()
  }

  /// Feeds the frontmost-app TTL cache (e.g. from NSWorkspace activation notifications).
  public func noteFrontmostBundleID(_ id: String?) {
    cacheLock.lock()
    cachedBundleID = id
    cachedAt = Date()
    cacheLock.unlock()
  }

  private func cachedFrontmostBundleID() -> String? {
    let now = Date()
    // Serve from cache without holding the lock over the NSWorkspace IPC.
    cacheLock.lock()
    if now.timeIntervalSince(cachedAt) < Self.bundleCacheTTL, cachedAt != .distantPast {
      let hit = cachedBundleID
      cacheLock.unlock()
      return hit
    }
    cacheLock.unlock()
    // The workspace call runs outside the lock so a slow accessibility
    // query cannot serialize every keystroke on this lock.
    let fresh = frontmostBundleID()
    cacheLock.lock()
    cachedBundleID = fresh
    cachedAt = now
    cacheLock.unlock()
    return fresh
  }

  /// Pure decision function — unit-testable without NSWorkspace.
  public func shouldBypass(bundleID: String?, secureInput: Bool) -> Bool {
    if secureInput { return true }
    guard let bundleID else { return false }
    if Self.securitySensitiveBundleIDs.contains(bundleID)
      || customExcludedBundleIDs.contains(bundleID)
    {
      return true
    }
    if excludeTerminals && Self.terminalBundleIDs.contains(bundleID) {
      return true
    }
    return false
  }

  /// Checks if the frontmost active application is in the excluded list or is secure.
  public func shouldBypassForActiveApplication() -> Bool {
    if isSecureInputActive() {
      return true
    }
    return shouldBypass(bundleID: cachedFrontmostBundleID(), secureInput: false)
  }
}
