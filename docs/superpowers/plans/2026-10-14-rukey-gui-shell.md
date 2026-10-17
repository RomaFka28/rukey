# Rukey GUI Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Rukey as a double-clickable `.app` with a menu-bar icon, a settings window, notifications and launch-at-login, while the `rukey` CLI daemon keeps working unchanged.

**Architecture:** A new `RukeyGUI` executable target holds an `NSApplication` whose delegate owns a `RukeyEngine` from the engine plan. Because the event tap is installed in `.commonModes` of the main run loop, `NSApplication.run()` delivers events to it exactly as `CFRunLoopRun()` did, so no IPC and no second process exist. The engine stays in `RukeyCore` and stays UI-free; the GUI reads state from it and writes settings back through the same lock-guarded setters the settings window exposes. `LSUIElement = true` removes the Dock icon. Two naming notes for readers comparing this plan to spec §5's block diagram: the diagram calls the app layer `RukeyApp`, while this plan keeps `RukeyApp` as the console `rukey` binary and names the GUI target `RukeyGUI` (intentional — do not "correct" either side); and the same diagram places `AppEventHub` inside the `RukeyCore` block (`ObservableObject для UI`), which is why the hub lives in core even though the core is otherwise UI-free.

**Tech Stack:** Swift 6.0, SwiftPM, AppKit + SwiftUI, `UNUserNotificationCenter`, `codesign`, no third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-14-rukey-gui-design.md` — sections 6.5, 8, 9.4 phases 5–7, 10.

**Prerequisite:** `docs/superpowers/plans/2026-10-14-rukey-engine.md` must be complete and `swift test` green. Every task here consumes `RukeyEngine` and `AppEventHub` from its Tasks 8 and 9.

## Global Constraints

- `RukeyCore` stays UI-free. No `import AppKit`, no `import SwiftUI`, no `NSWindow` in that target. The engine plan's rule that the core changes only by narrow lock-guarded setters still holds.
- The `rukey` CLI target keeps every flag and its current output. `swift run rukey --test-conversion` must produce the same five sample lines after every task in this plan.
- The app must not start its tap before it knows whether it holds the Accessibility grant. No `exit(1)` anywhere in the GUI target.
- All UI state reads must cross to the main actor. The engine runs on the main thread already, so no additional hops are needed for the tap, but SwiftUI bindings must still be `@MainActor`.
- One commit per task, pushed to `origin/main`. Rollback point for this plan is the last engine-plan commit.
- Every task that adds user-visible text writes it in Russian, matching the spec and the existing `print` strings.

## Review Focus

Failure modes this plan implies but no automated test can reach. Each is pinned by a test in the owning task where a seam exists, and otherwise by a named manual check in that task's last step.

1. **App launched without the Accessibility grant.** Expectation: red status in the menu bar, a working button that opens the right System Settings pane, and the app waiting — not exiting, not silently doing nothing. Manual, Task 2.
2. **Rebuild after the first successful grant.** Expectation: the grant survives, because the bundle is signed with the stable self-signed certificate from Task 1. If it does not, Task 1 is wrong and must be fixed before any UI work proceeds. Manual, Task 1.
3. **Menu closed while a correction notification is pending.** Expectation: no crash, no lost state, and the menu shows a readable summary afterwards. Manual, Task 3.
4. **Two words learned in the same session.** Expectation: both appear in the settings list, neither overwrites the other, and the config file written to disk is the union. Test, Task 4.
5. **User removes a word that was learned.** Expectation: it disappears from the filter immediately and stays gone after a restart, because the removal is written to `exclude.json`, not just to memory. Test, Task 4.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `Sources/RukeyGUI/main.swift` | Entry point: builds `NSApplication`, installs the delegate |
| `Sources/RukeyGUI/AppDelegate.swift` | Owns `RukeyEngine`, permission state, tap start/stop, termination |
| `Sources/RukeyGUI/PermissionGate.swift` | Polls the Accessibility grant without exiting; reports transitions and opens the System Settings pane |
| `Sources/RukeyGUI/StatusItemController.swift` | `NSStatusItem`, menu construction, learned-word banner |
| `Sources/RukeyGUI/SettingsWindowController.swift` | One `NSWindow` hosting the tabbed SwiftUI view |
| `Sources/RukeyGUI/SettingsState.swift` | The GUI's single live settings copy, seeded from the launch-time config |
| `Sources/RukeyGUI/SettingsStore.swift` | Writes settings through the live engine, `exclude.json` and `SettingsState`; launch-at-login rollback |
| `Sources/RukeyGUI/SettingsView.swift` | The four tabs' SwiftUI bodies |
| `Sources/RukeyGUI/AppPicker.swift` | Installed-application discovery and search |
| `Sources/RukeyGUI/CorrectionFlash.swift` | Transient corner panel showing the last correction |
| `Sources/RukeyGUI/NotificationService.swift` | `UNUserNotificationCenter` wrapper and permission request |
| `Sources/RukeyGUI/Icon.swift` | Vector lightning path, template and colour variants |
| `Sources/RukeyGUI/Resources/Info.plist` | Bundle metadata, `LSUIElement`, identifier |
| `tools/make-signing-cert.sh` | One-time self-signed certificate creation |
| `tools/package-app.sh` | Builds, assembles and signs the `.app` |

**Modified:** `Package.swift` — add the `RukeyGUI` executable target.

**Never modified:** anything under `Sources/RukeyCore/` except where a task explicitly says to add a narrow setter. If a GUI task seems to need a core change beyond that, stop and re-read the spec §5.

---

### Task 1: Signing certificate and `.app` packaging

**Files:**
- Create: `tools/make-signing-cert.sh`
- Create: `tools/package-app.sh`
- Create: `Sources/RukeyGUI/Resources/Info.plist`

**Interfaces:**
- Consumes: nothing.
- Produces: `Rukey.app` at `dist/Rukey.app`, signed with the certificate created by `make-signing-cert.sh`. Both scripts are idempotent: re-running them must not recreate the certificate or change the identifier, because either would invalidate the Accessibility grant.

- [ ] **Step 1: Write the certificate script**

`tools/make-signing-cert.sh` must:

1. Check for an existing key named `Rukey Local Signing` in the login keychain via `security find-identity -v -p codesigning` and exit 0 if found.
2. Otherwise generate a key with `openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/rukey-key.pem -out /tmp/rukey-cert.pem -days 3650 -subj "/CN=Rukey Local Signing"` — plus `-addext` entries for `basicConstraints=critical,CA:FALSE`, `keyUsage=critical,digitalSignature` and `extendedKeyUsage=critical,codeSigning` (without the codeSigning EKU the certificate never appears in `security find-identity -p codesigning`, so step 3's own check could not pass). Import both into the **login keychain** with `security import … -T /usr/bin/codesign` — the identity must live as long as the Accessibility grant (TCC keys off the leaf certificate hash across rebuilds), so a temporary keychain is not an option — delete the plaintext key PEM after the import, and mark the cert trusted for code signing in the **user domain** with `security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db` (no `-d`: the admin domain needs authorization and changes nothing for this workflow; run from a regular Terminal if macOS refuses the trust change non-interactively).
3. Print the SHA-1 hash `security find-identity -v -p codesigning` reports, because `package-app.sh` needs it.
4. Never delete or overwrite an existing identity.

Run: `bash tools/make-signing-cert.sh`
Expected: prints a SHA-1 fingerprint, exits 0. Run it twice — the second run must print the same hash.

- [ ] **Step 2: Write the packaging script**

`tools/package-app.sh` must:

1. `swift build -c release`.
2. Assemble `dist/Rukey.app/Contents/{MacOS,Resources}`; copy the built executable product to `Contents/MacOS/Rukey` — today that is the `rukey` product, since the GUI target does not exist yet; once Task 2 adds `RukeyGUI` the script must copy that product instead, so keep the product name in a variable at the top of the script. Copy `Info.plist` into `Contents/`.
3. Embed the dictionaries into the bundle and point `Bundle.module` at the bundle — verify the copy list against `Package.swift`'s `.process("Resources")` declaration rather than assuming filenames.
4. Sign with `codesign --force --sign "<identity>" --options runtime --timestamp=none dist/Rukey.app`, where `<identity>` is the hash from Step 1. `--options runtime` is the hardened runtime; if it rejects the self-signed identity, drop it and record why in the script header.
5. Print the resulting bundle path.

Run: `bash tools/package-app.sh`
Expected: prints a path ending in `dist/Rukey.app`.

Run: `codesign -dv --verbose=2 dist/Rukey.app 2>&1 | grep -i authority`
Expected: shows the Rukey certificate, not `(adhoc)`.

- [ ] **Step 3: Write Info.plist**

`Sources/RukeyGUI/Resources/Info.plist` must contain, with exactly these values:

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `com.roman.rukey` |
| `CFBundleName` | `Rukey` |
| `CFBundleExecutable` | `Rukey` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString` | `1.0` |
| `LSUIElement` | `true` |
| `LSMinimumSystemVersion` | `13.0` |
| `NSHumanReadableCopyright` | `Rukey` |

`LSUIElement` is what removes the Dock icon; `CFBundleIdentifier` must never change once a grant is issued.

- [ ] **Step 4: Verify the grant survives a rebuild**

Run the app once from `dist/Rukey.app`, grant Accessibility in System Settings, quit it, then:

Run: `bash tools/package-app.sh && echo rebuilt`
Expected: after relaunching, `System Settings → Privacy & Security → Accessibility` still lists Rukey as enabled. If the grant vanished, the identity is not stable — fix the script before continuing. Record the observed result in the commit message. **Owner-performed:** the grant, the relaunch and the observation need a human at the keyboard; an agent reports this step as *unverified*, never as passed.

- [ ] **Step 5: Commit**

```bash
git add tools/ Sources/RukeyGUI/Resources/Info.plist
git commit -m "Add stable signing identity and app packaging script"
git push
```

---

### Task 2: GUI target, permission UX and tap lifecycle

**Files:**
- Modify: `Package.swift` — add `.executableTarget(name: "RukeyGUI", dependencies: ["RukeyCore"], exclude: ["Resources"])` (the `Info.plist` under `Resources/` is packaging input, not a SwiftPM resource — without the exclusion SwiftPM warns about it)
- Modify: `tools/package-app.sh` — switch its executable-product variable from `rukey` to `RukeyGUI`
- Create: `Sources/RukeyGUI/main.swift`
- Create: `Sources/RukeyGUI/AppDelegate.swift`
- Create: `Sources/RukeyGUI/PermissionGate.swift`
- Create: `Sources/RukeyGUI/SettingsState.swift`

**Interfaces:**
- Consumes: `RukeyEngine` and `AppEventHub` from the engine plan, `RukeyConfig` (the launch-time load), `EventTapManager.checkAccessibilityPermissions(prompt:)`.
- Produces:

```swift
@MainActor
public enum PermissionState: Equatable {
    case unknown
    case granted
    case denied
    case needsPrompt
}

@MainActor
public final class PermissionGate {
    public init(pollInterval: TimeInterval = 2.0)
    public private(set) var state: PermissionState { get }
    public var onChange: ((PermissionState) -> Void)?
    public func start()
    public func stop()
    @discardableResult
    public func openSystemSettings() -> Bool
}

@MainActor
public final class SettingsState {
    public init(config: RukeyConfig)
    public var minPrefixLength: Int
    public var autoLearnThreshold: Int
    public var notifyOnEveryUndo: Bool
    public var showCorrectionFlash: Bool
    public var excludeTerminals: Bool
    public var launchAtLogin: Bool
    public var excludedWords: [String]
    public var excludedBundleIDs: Set<String>
}
```

- [ ] **Step 1: Write the failing test**

`PermissionGate` lives in `RukeyGUI` and has no UI, so it is testable once the accessibility probe is injectable:

```swift
import XCTest
@testable import RukeyGUI

@MainActor
final class PermissionGateTests: XCTestCase {
    func testStartsUnknownAndReportsGranted() {
        var trusted = false
        let gate = PermissionGate { trusted }
        gate.start()
        XCTAssertEqual(gate.state, .unknown)
        trusted = true
        gate.pollNow()
        XCTAssertEqual(gate.state, .granted)
        gate.stop()
    }

    func testDeniedIsReported() {
        let trusted = false
        let gate = PermissionGate { trusted }
        gate.start()
        gate.pollNow()
        XCTAssertEqual(gate.state, .denied)
        gate.stop()
    }

    func testChangeCallbackFiresOnlyOnTransition() {
        let trusted = false
        var calls: [PermissionState] = []
        let gate = PermissionGate { trusted }
        gate.onChange = { calls.append($0) }
        gate.start()
        gate.pollNow()
        gate.pollNow()
        XCTAssertEqual(calls, [.denied])
        gate.stop()
    }
}
```

If `PermissionGate` cannot be tested from the `RukeyGUITests` target because of how `@testable import` resolves the executable, move the gate into a small library target `RukeyUILib` that `RukeyGUI` and `RukeyGUITests` both depend on. The injectable probe is not optional; a gate whose state can only be observed by granting real permissions cannot be tested at all.

- [ ] **Step 2: Run the test to see it fail**

Run: `swift test --filter PermissionGateTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'PermissionGate' in scope`.

- [ ] **Step 3: Implement the gate**

`PermissionGate` takes a probe closure `() -> Bool` defaulting to `{ AXIsProcessTrusted() }`. `start()` schedules a repeating timer on the main run loop in `.common` mode that calls `pollNow()`. `pollNow()` reads the probe and updates `state`, firing `onChange` only when the value actually changed. `openSystemSettings()` opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` via `NSWorkspace.open` and returns whether the call was accepted.

- [ ] **Step 4: Implement the app delegate**

`AppDelegate` is `@MainActor` and owns:

- `private var engine: RukeyEngine?` — built lazily on a background-safe path, because `RukeyEngine.init` loads ~1.1 MB of dictionaries
- `private let gate = PermissionGate()`
- `private let state: SettingsState` — the GUI's single live copy of the settings, initialised from the launch-time `RukeyConfig.load`. Everything downstream reads current values from it; never capture a `RukeyConfig` snapshot in a long-lived closure (the CLI's `{ config.notifyOnEveryUndo }` is fine for one-shot flags and wrong for a GUI whose settings change at runtime).
- `private var hub: AppEventHub?` — **retained**: nothing else holds it.
- `func applicationDidFinishLaunching(_:)` — starts the gate, then observes it. **The tap is not started here.**
- When `gate.state` becomes `.granted`, build the engine, then the controller, then the hub — on the main actor, in that order (none of the three is `Sendable`):

```swift
// Both come from `init`'s single launch-time load; `state` mirrors it live.
engine = try RukeyEngine(config: initialConfig, verbose: false)
let learningController = UndoLearningController(
    strikeStore: engine.strikeStore,
    wordFilter: engine.wordFilter,
    thresholdProvider: { state.autoLearnThreshold },
    notifyProvider: { state.notifyOnEveryUndo },
    configWriter: { words in
        // Re-read before mutating — the writer may not be the only editor.
        var current = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false)
        current.excludedWords = words.sorted()
        RukeyConfig.write(current, to: RukeyConfig.configFileURL)
        state.excludedWords = current.excludedWords
    })
hub = AppEventHub(tapManager: engine.tapManager, learningController: learningController)
```

The hub's initialiser owns all five hooks (the four `tapManager.on…` callbacks and `learningController.onNotice`) — do **not** assign any of them by hand: Task 9's rule is exactly one owner per process, and the console keeps its own callbacks and no hub. `thresholdProvider` and `notifyProvider` read live values through `state`, never a captured snapshot.

- Call `engine.tapManager.start()` exactly once, after the hub exists. If `start()` returns false, report it through the status item rather than exiting.
- `func applicationShouldTerminate(_:)` — call `engine.tapManager.stop()` and return `.terminateNow`

The critical behaviour: with no grant the app stays alive, shows a red status, and starts working the moment the grant appears. There must be no `exit(1)` anywhere.

- [ ] **Step 5: Implement the entry point**

`main.swift` builds an `NSApplication`, sets the delegate, and calls `run()`. It must not call `CFRunLoopRun()` directly.

- [ ] **Step 6: Build and verify the tap still fires**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

Flip `tools/package-app.sh`'s executable-product variable from `rukey` to `RukeyGUI` and re-package — from this task on the bundle must launch the GUI:

Run: `bash tools/package-app.sh && codesign -dv --verbose=2 dist/Rukey.app 2>&1 | grep -i authority`
Expected: prints a path ending in `dist/Rukey.app`; the authority line shows the Rukey certificate, not `(adhoc)`.

Run: `swift run rukey --test-conversion 2>&1 | tail -8`
Expected: the same five sample lines. The CLI target must be untouched by this task.

- [ ] **Step 7: Manual check — permission UX**

Launch `dist/Rukey.app` **without** granting Accessibility. Expect: the process stays alive and does not exit (the red status item itself only appears after Task 3 — here verify process survival, e.g. with `ps`; Task 3's manual check re-verifies the red status). Grant the permission while it is running. Expect: the app picks the grant up without relaunching (visible as the green status from Task 3 on; here verify the process survives). Report both observations in the commit message.

- [ ] **Step 8: Commit**

```bash
git add Package.swift tools/ Sources/RukeyGUI/ Tests/RukeyGUITests/
git commit -m "Add GUI target that waits for the Accessibility grant instead of exiting"
git push
```

---

### Task 3: Menu bar item and icon

**Files:**
- Create: `Sources/RukeyGUI/Icon.swift`
- Create: `Sources/RukeyGUI/StatusItemController.swift`

**Interfaces:**
- Consumes: `RukeyEngine`, `PermissionGate`, `UndoLearningController`, `AppEventHub` (`lastLearned`).
- Produces:

```swift
@MainActor
public enum StatusItemController {
    public static let menuTitleLimit = 40
    public static func flashImage() -> NSImage
}
```

- [ ] **Step 1: Write the failing test for the menu model**

Menu construction must be testable without a status item. Extract the model:

```swift
import XCTest
@testable import RukeyGUI

@MainActor
final class StatusMenuModelTests: XCTestCase {
    func testStatusTitleWhenRunning() {
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: false,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false, excludedBundleIDs: [])
        XCTAssertEqual(model.statusTitle, "Работает")
    }

    func testStatusTitleWithoutPermission() {
        let model = StatusMenuModel(
            permission: .denied, running: false, secureInputActive: false,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false, excludedBundleIDs: [])
        XCTAssertEqual(model.statusTitle, "Нет прав Accessibility")
    }

    func testStatusTitleWhenGrantedButNotRunning() {
        let model = StatusMenuModel(
            permission: .granted, running: false, secureInputActive: false,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false, excludedBundleIDs: [])
        XCTAssertEqual(model.statusTitle, "Не запущено")
    }

    func testStatusTitleUnderSecureInput() {
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: true,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false, excludedBundleIDs: [])
        XCTAssertEqual(model.statusTitle, "Приостановлено: защищённый ввод")
    }

    func testLastCorrectionIsTruncatedToTheLimit() {
        let long = String(repeating: "а", count: 200)
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: false,
            language: .russian,
            lastCorrection: .init(original: long, converted: long),
            learningBanner: nil, launchAtLogin: false, excludedBundleIDs: [])
        XCTAssertTrue(model.lastCorrectionTitle!.count <= StatusItemController.menuTitleLimit + 3)
        XCTAssertTrue(model.lastCorrectionTitle!.contains("…"))
    }

    func testLearningBannerWinsOverCorrectionForTheBannerSlot() {
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: false,
            language: .russian,
            lastCorrection: .init(original: "ghb", converted: "при"),
            learningBanner: .init(prefix: "ghb", converted: "при"),
            launchAtLogin: false, excludedBundleIDs: [])
        XCTAssertNotNil(model.learningBannerTitle)
        XCTAssertEqual(model.learningBannerTitle, "Запомнено: ghb больше не станет при")
    }
}
```

Put these in a `RukeyGUITests` target. Add it to `Package.swift` alongside `RukeyCoreTests` with `dependencies: ["RukeyGUI", "RukeyCore"]`, since the tests name core types directly.

- [ ] **Step 2: Run the test to see it fail**

Run: `swift test --filter StatusMenuModelTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'StatusMenuModel' in scope`.

- [ ] **Step 3: Implement the menu model**

`StatusMenuModel` is a `@MainActor` struct with stored properties matching the test's arguments, plus computed titles carrying the exact strings from the spec §8.1: `Работает`, `Нет прав Accessibility`, `Приостановлено: защищённый ввод`. A grant that is present but whose tap is not running (a failed `tapManager.start()`) reads `Не запущено` instead of `Работает`. `learningBannerTitle` renders the `Запомнено: … больше не станет …` line, derived from the same string `UndoLearningController` logs. Truncation is by `String.prefix` plus `…`.

- [ ] **Step 4: Draw the icon**

`Icon.swift` builds a lightning bolt as a `CGPath` in an 18×18 box with the proportions of a keycap glyph: a tapered zigzag, stroke width about 1.6pt, so it reads at menu-bar size. Produce:

- `templateImage()` — black with alpha, `isTemplate = true`. macOS then renders it correctly on light and dark menu bars automatically. Do **not** ship separate light and dark files, and do not observe the system appearance.
- `coloredImage(size:)` — accent-filled version for the settings window's about section.
- `templateImage(at scale:)` writing `RukeyMenuTemplate.png` at @1x and @2x.

- [ ] **Step 5: Build the status item**

`StatusItemController` owns an `NSStatusItem` with a variable length, sets `button.image` from `Icon.templateImage()`, and rebuilds the menu from `StatusMenuModel` on every relevant change. Menu order is exactly: status (disabled), current layout, last correction, learned-word banner, separator, launch-at-login checkbox, `Настройки…`, `Журнал…`, separator, `Выйти`. The banner, when present, carries a `Убрать` submenu item that removes the word from the filter and writes the config. Engine-build and tap-start failures must surface here: when `AppDelegate`'s `tapManager.start()` returns false or the engine fails to build, the status line reads `Не запущено` and the Task 2 `LogBuffer` line stays as the record.

- [ ] **Step 6: Wire learning events into the banner**

Observe `AppEventHub.lastLearned` (the hub Task 2 retains) — the value carries `prefix`/`converted`, the same `LearningNotice` the `Запомнено:` log line is built from, so the two can never disagree. When it changes, the status item shows the banner and briefly swaps the icon for an alternate image for about a second, then restores it. Do **not** read `LogBuffer.shared` and do not sniff log strings; convert the hub value into `StatusMenuModel.learningBanner` in the controller that owns the hub.

- [ ] **Step 7: Build and verify**

Run: `swift build 2>&1 | tail -5 && swift run rukey --test-conversion 2>&1 | tail -8`
Expected: `Build complete!` and the five unchanged sample lines.

- [ ] **Step 8: Manual check — menu behaviour**

Launch the packaged app with a grant in place. Expect: a lightning icon in the menu bar, no Dock icon, and a menu whose status line matches the engine's real state. Switch to a password field and back. Expect the status line to change to `Приостановлено: защищённый ввод` and back. Report both in the commit message.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/RukeyGUI/ Tests/RukeyGUITests/
git commit -m "Add template menu-bar icon and the status menu model"
git push
```

---

### Task 4: Settings window, words tab

**Files:**
- Create: `Sources/RukeyGUI/SettingsWindowController.swift`
- Create: `Sources/RukeyGUI/SettingsView.swift`

**Interfaces:**
- Consumes: `WordFilter`, `CustomDictionary`, `StrikeStore`, `RukeyConfig` write path, `SettingsState`, `AppDelegate`.
- Produces:

```swift
@MainActor
public final class SettingsWindowController {
    public init(engine: RukeyEngine, onClose: (() -> Void)?)
    public func show()
}
```

- [ ] **Step 1: Write the failing test**

The add/remove flow is the part worth testing; the SwiftUI layout is not. Extract it:

```swift
import XCTest
@testable import RukeyCore
@testable import RukeyGUI

@MainActor
final class WordListModelTests: XCTestCase {
    func testAddingANonBlankWordReachesTheFilter() {
        let filter = WordFilter()
        let dictionary = CustomDictionary(fileURL: temporaryURL())
        let model = WordListModel(
            filter: filter, dictionary: dictionary,
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addExcluded("ghbdtn")
        XCTAssertTrue(filter.isExcluded("ghbdtn"))
    }

    func testBlankInputIsIgnored() {
        let filter = WordFilter()
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addExcluded("   ")
        XCTAssertTrue(filter.isEmpty)
    }

    func testDuplicatesAreRejected() {
        let filter = WordFilter(words: ["ghbdtn"])
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addExcluded("ghbdtn")
        XCTAssertEqual(filter.words, ["ghbdtn"])
    }

    func testRemovingAWrittenWord() {
        let filter = WordFilter(words: ["ghbdtn"])
        var written: [Set<String>] = []
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()),
            writer: { written.append($0) })
        model.removeExcluded("ghbdtn")
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(written, [Set()])
    }

    func testTwoWordsBothPersistAsAUnion() {
        let filter = WordFilter()
        var written: [Set<String>] = []
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()),
            writer: { written.append($0) })
        model.addExcluded("ghbdtn")
        model.addExcluded("hello")
        XCTAssertEqual(written.last, ["ghbdtn", "hello"])
    }

    func testLearnedWordIsRemovableAndStaysGone() {
        let filter = WordFilter(words: ["ghb"])
        var written: [Set<String>] = []
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: StrikeStore(fileURL: temporaryURL()),
            writer: { written.append($0) })
        model.removeExcluded("ghb")
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(written.last, [])
    }

    func testRemovingALearnedWordClearsItsStrikes() {
        let strikes = StrikeStore(fileURL: temporaryURL())
        _ = strikes.registerUndo(key: "ghb")
        let filter = WordFilter(words: ["ghb"])
        let model = WordListModel(
            filter: filter, dictionary: CustomDictionary(fileURL: temporaryURL()),
            strikeStore: strikes, writer: { _ in })
        model.removeExcluded("ghb")
        XCTAssertEqual(strikes.strikes(for: "ghb"), 0)
        XCTAssertEqual(strikes.registerUndo(key: "ghb"), 1,
                       "re-learning must start from a fresh count, not continue at the old one")
    }

    func testTaughtWordsGoToTheCustomDictionaryNotTheFilter() {
        let filter = WordFilter()
        let dictionary = CustomDictionary(fileURL: temporaryURL())
        let model = WordListModel(
            filter: filter, dictionary: dictionary,
            strikeStore: StrikeStore(fileURL: temporaryURL()), writer: { _ in })
        model.addTaught("абракадабра")
        XCTAssertTrue(dictionary.contains("абракадабра"))
        XCTAssertTrue(filter.isEmpty)
    }
}
```

`testTwoWordsBothPersistAsAUnion` and `testLearnedWordIsRemovableAndStaysGone` pin Review Focus items 4 and 5. Define `temporaryURL()` in this file as a `FileManager.default.temporaryDirectory` path with a UUID, so no test touches the real config.

- [ ] **Step 2: Run the test to see it fail**

Run: `swift test --filter WordListModelTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'WordListModel' in scope`.

- [ ] **Step 3: Implement `WordListModel`**

`@MainActor` final class holding the filter, the dictionary, a required `strikeStore: StrikeStore` (never defaulted — a default would point every test at the real `learned.json`) and a `writer: (Set<String>) -> Void`. `addExcluded` trims, drops blanks and duplicates, unions into `wordFilter`, then calls `writer` with the full new set — never with a delta. `removeExcluded` removes the word, calls `strikeStore.removeAllKeys(for:)`, and writes the full remaining set: without the strike reset a removed word can never be re-learned, because its count stays at the old threshold and the learning condition is an exact match. `addTaught` and `removeTaught` mirror this against the dictionary. This is what makes a learned word's removal survive a restart: the writer persists the whole list, not the change. In the app the writer **re-reads** (`RukeyConfig.load`), merges the new full set into that fresh copy, and persists it with `RukeyConfig.write` (the one writer), keeping `state.excludedWords` in sync.

- [ ] **Step 4: Implement the settings window**

`SettingsWindowController` creates one `NSWindow` with `.titled, .closable, .miniaturizable`, `isReleasedWhenClosed = false`, and hosts a `TabView` in an `NSHostingView`. Four tabs, in this order: `Слова`, `Приложения`, `Общее`, `Журнал`.

The `Слова` tab has two sections. `Не заменять`: a text field that submits on Return, a list with per-row delete buttons, and `Очистить всё`. Each row shows the stored form and, when known, its conversion — `ghb → при`. `Мои слова`: the same shape over the custom dictionary. The model's `writer` goes through the re-read-merge-`RukeyConfig.write` path from Step 3 — never a snapshot write — and keeps `state.excludedWords` in sync.

- [ ] **Step 5: Verify**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: `Build complete!` and the full suite green.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/RukeyGUI/ Tests/RukeyGUITests/
git commit -m "Add settings window with the words tab"
git push
```

---

### Task 5: Settings window, applications tab

**Files:**
- Create: `Sources/RukeyGUI/AppPicker.swift`
- Modify: `Sources/RukeyGUI/SettingsView.swift`
- Modify: `Sources/RukeyGUI/SettingsWindowController.swift` — the picker's sheet needs the window as its parent

**Interfaces:**
- Consumes: `SecureInputMonitor.customExcludedBundleIDs` and `.excludeTerminals` setters from the engine plan.
- Produces:

```swift
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let id: String        // bundle identifier
    public let name: String
    public let url: URL
}

@MainActor
public final class AppPicker {
    public init(searchPaths: [URL] = AppPicker.defaultSearchPaths)
    public static let defaultSearchPaths: [URL]
    public func reload() async -> [InstalledApp]
    public nonisolated static func search(_ query: String, in apps: [InstalledApp]) -> [InstalledApp]
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/RukeyGUITests/AppPickerTests.swift`:

```swift
import XCTest
@testable import RukeyGUI

final class AppPickerTests: XCTestCase {
    private func makeApp(_ name: String, _ bundleID: String) -> InstalledApp {
        InstalledApp(
            id: bundleID,
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    func testSearchMatchesNameCaseInsensitively() {
        let apps = [makeApp("Safari", "com.apple.Safari"), makeApp("Slack", "com.tinyspeck.slack")]
        let found = AppPicker.search("saf", in: apps)
        XCTAssertEqual(found.map(\.name), ["Safari"])
    }

    func testSearchMatchesBundleIdentifier() {
        let apps = [makeApp("Safari", "com.apple.Safari"), makeApp("Slack", "com.tinyspeck.slack")]
        XCTAssertEqual(AppPicker.search("tinyspeck", in: apps).map(\.name), ["Slack"])
    }

    func testEmptyQueryReturnsEverything() {
        let apps = [makeApp("Safari", "com.apple.Safari"), makeApp("Slack", "com.tinyspeck.slack")]
        XCTAssertEqual(AppPicker.search("", in: apps).count, 2)
    }

    func testResultsAreSortedByName() {
        let apps = [makeApp("Slack", "b"), makeApp("Safari", "a")]
        XCTAssertEqual(AppPicker.search("", in: apps).map(\.name), ["Safari", "Slack"])
    }

    func testNoMatchReturnsEmpty() {
        let apps = [makeApp("Safari", "com.apple.Safari")]
        XCTAssertTrue(AppPicker.search("zzzz", in: apps).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to see they fail**

Run: `swift test --filter AppPickerTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'AppPicker' in scope`.

- [ ] **Step 3: Implement the picker**

`defaultSearchPaths` is `/Applications`, `/System/Applications` and `~/Applications`. `reload()` enumerates each path for `.app` bundles, reads `CFBundleIdentifier` and `CFBundleDisplayName` falling back to the directory name, drops bundles with no identifier, de-duplicates by identifier keeping the first, and sorts by localised name. It runs off the main actor and returns to it; it is `async`, so the harness cannot run a test through it — its enumeration and sorting get reading-only verification plus Step 6's manual check. `search` is a pure function on the returned array — it must not touch disk — and is declared `nonisolated static`, because a `static` member of a `@MainActor` class is main-actor-isolated under Swift 6 and the tests (plain `XCTestCase` methods) could not call it synchronously. Keep the tests exactly as written.

- [ ] **Step 4: Build the applications tab**

A `Добавить приложение` button opens a sheet listing `AppPicker` results with a search field. Selecting one adds its bundle identifier to `secureMonitor.customExcludedBundleIDs`, mirrors it into `SettingsState.excludedBundleIDs`, and persists through the same re-read-merge-`RukeyConfig.write` path the words tab uses. The current exclusions are listed below with delete buttons. A checkbox mirrors `excludeTerminals` (same save path, into `SettingsState` too).

- [ ] **Step 5: Verify the settings apply without a restart**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: green.

- [ ] **Step 6: Manual check**

Add Safari to the exclusions from the running app. Expect: autocorrection stops immediately inside Safari without relaunching, and the exclusion is still present after quitting and relaunching. Report both in the commit message.

- [ ] **Step 7: Commit**

```bash
git add Sources/RukeyGUI/ Tests/RukeyGUITests/
git commit -m "Add installed-application picker and the applications tab"
git push
```

---

### Task 6: Settings window, general tab and log

**Files:**
- Modify: `Sources/RukeyGUI/SettingsView.swift`
- Create: `Sources/RukeyGUI/SettingsStore.swift`
- Modify: `Sources/RukeyGUI/SettingsWindowController.swift` — hosts the store for the general and log tabs
- Modify: `Sources/RukeyGUI/AppDelegate.swift` — owns the `SettingsStore` and passes it to the controller

**Interfaces:**
- Consumes: `Detector.minPrefixLength` setter, `RukeyConfig` (`load`/`write`/`configFileURL`), `SettingsState`, `LogBuffer`.
- Produces:

```swift
@MainActor
public final class SettingsStore {
    public init(
        engine: RukeyEngine,
        state: SettingsState,
        configFileURL: URL,
        launchAgentFileURL: URL = SettingsStore.defaultLaunchAgentFileURL,
        logBuffer: LogBuffer = .shared
    )
    public static let defaultLaunchAgentFileURL: URL
    public let engine: RukeyEngine
    public let state: SettingsState
    public var minPrefixLength: Int { get set }
    public var autoLearnThreshold: Int { get set }
    public var notifyOnEveryUndo: Bool { get set }
    public var showCorrectionFlash: Bool { get set }
    public var excludeTerminals: Bool { get set }
    public var launchAtLogin: Bool { get set }
    public var launchAgentFileURLOverride: URL { get set }
    public var showOnlyErrors: Bool { get set }
    public private(set) var lastError: String? { get }
    public var logLines: [LogLine] { get }
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/RukeyGUITests/SettingsStoreTests.swift`. The interesting cases are launch-at-login registration and log filtering:

```swift
import XCTest
@testable import RukeyCore
@testable import RukeyGUI

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeStore(logBuffer: LogBuffer = LogBuffer()) throws -> (SettingsStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukey-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("com.roman.rukey.plist")
        let config = RukeyConfig.load(
            excludeTerminalsFlag: false, extraBundleIDs: [], verbose: false,
            configFileURL: base.appendingPathComponent("exclude.json"))
        let engine = try RukeyEngine(
            config: config,
            verbose: false,
            customDictionaryFileURL: base.appendingPathComponent("custom.json"),
            strikeStoreFileURL: base.appendingPathComponent("learned.json")
        )
        let store = SettingsStore(
            engine: engine, state: SettingsState(config: config),
            configFileURL: base.appendingPathComponent("exclude.json"),
            launchAgentFileURL: url, logBuffer: logBuffer)
        return (store, url)
    }

    func testEnablingLaunchAtLoginWritesALaunchAgent() throws {
        let (store, url) = try makeStore()
        store.launchAtLogin = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["Label"] as? String, "com.roman.rukey")
        XCTAssertNotNil((plist?["ProgramArguments"] as? [String])?.first)
        store.launchAtLogin = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailingRegistrationReportsRatherThanLying() throws {
        let (store, _) = try makeStore()
        store.launchAgentFileURLOverride = URL(fileURLWithPath: "/nonexistent-dir/x.plist")
        store.launchAtLogin = true
        XCTAssertFalse(store.launchAtLogin, "a failed write must not leave the checkbox on")
        XCTAssertTrue(store.lastError != nil)
    }

    func testLogFilterShowsOnlyErrors() throws {
        let buffer = LogBuffer()
        let (store, _) = try makeStore(logBuffer: buffer)
        buffer.log("noise", level: .debug)
        buffer.log("boom", level: .error)
        store.showOnlyErrors = true
        XCTAssertEqual(store.logLines.map(\.text), ["boom"])
    }

    func testMinPrefixLengthChangeReachesTheDetector() throws {
        let (store, _) = try makeStore()
        store.minPrefixLength = 4
        XCTAssertEqual(store.engine.detector.minPrefixLength, 4)
    }
}
```

The `launchAgentFileURLOverride` property exists only for the failure test; give it a default of the real path.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter SettingsStoreTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SettingsStore' in scope`.

- [ ] **Step 3: Implement `SettingsStore`**

Each property is a computed property that writes through in one call to the live `SettingsState`, the engine, and the config file — and reads its current value from `SettingsState`, never from `engine.config` (an immutable launch-time snapshot). Because two tabs can each hold a stale base, every file write **re-reads** (`RukeyConfig.load`) immediately before mutating and hands the whole struct to `RukeyConfig.write`; the writer cannot fix a stale base. `minPrefixLength` also writes to `detector.minPrefixLength`, clamped to 2...5. `launchAtLogin` writes a `~/Library/LaunchAgents/com.roman.rukey.plist` containing `Label`, `ProgramArguments` pointing at the bundle's `Contents/MacOS/Rukey`, and `RunAtLoad`; on any write error it rolls the checkbox back, stores `lastError`, and logs a `.warn`. `logLines` reads the injected `logBuffer` (`LogBuffer.shared` by default, a per-test buffer in tests, so one test's lines cannot leak into another's filter). Anti-goal 2 forbids a checkbox that lies.

- [ ] **Step 4: Build the general and log tabs**

`Общее`: a stepper for `minPrefixLength`, a stepper for `autoLearnThreshold` accepting 0, 2, 3 and 5, a toggle for `notifyOnEveryUndo`, a toggle for `showCorrectionFlash`, a toggle for `excludeTerminals`, a toggle for `launchAtLogin`, and a button opening the Accessibility pane. `Журнал`: a `List` over `store.logLines` (the injected buffer — `LogBuffer.shared` in the app), newest last, a `Picker` for all levels versus errors only, and a `Копировать` button.

- [ ] **Step 5: Verify**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/RukeyGUI/ Tests/RukeyGUITests/
git commit -m "Add general and log tabs with launch-at-login registration"
git push
```

---

### Task 7: Notifications and correction flash

**Files:**
- Create: `Sources/RukeyGUI/NotificationService.swift`
- Create: `Sources/RukeyGUI/CorrectionFlash.swift`
- Modify: `Sources/RukeyGUI/AppDelegate.swift` (Step 5's hub wiring and the `Журнал…` opener)
- Modify: `Sources/RukeyGUI/SettingsWindowController.swift` (the `Журнал…` opener's tab selection)
- Modify: `Sources/RukeyGUI/SettingsView.swift` (`TabView` binds to the held selection)

**Interfaces:**
- Consumes: `AppEventHub` (`lastCorrection`, `lastUndo`, `lastLearned`) and the live `SettingsState` (`showCorrectionFlash`).
- Produces:

```swift
@MainActor
public final class NotificationService {
    public init(center: UNUserNotificationCenter = .current())
    public private(set) var isAuthorized: Bool { get }
    public func requestAuthorization() async
    public func showUndoNotice(prefix: String, converted: String, count: Int, threshold: Int) async
    public func showLearnedNotice(prefix: String, converted: String) async
}

@MainActor
public final class CorrectionFlash {
    public static let duration: TimeInterval = 1.5
    public nonisolated static func text(original: String, converted: String) -> String
    public init(size: CGSize = CGSize(width: 220, height: 54))
    public func show(_ text: String)
    public func hide()
}
```

- [ ] **Step 1: Write the failing test for flash text formatting**

```swift
import XCTest
@testable import RukeyGUI

final class CorrectionFlashFormatterTests: XCTestCase {
    func testCorrectionTextUsesAnArrow() {
        XCTAssertEqual(CorrectionFlash.text(original: "ghb", converted: "при"), "ghb → при")
    }

    func testTextIsTruncatedForThePanelWidth() {
        let long = String(repeating: "я", count: 100)
        let text = CorrectionFlash.text(original: long, converted: long)
        XCTAssertTrue(text.count <= 60)
        XCTAssertTrue(text.hasSuffix("…"))
    }
}
```

- [ ] **Step 2: Run the test to see it fail**

Run: `swift test --filter CorrectionFlashFormatterTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'CorrectionFlash' in scope`.

- [ ] **Step 3: Implement the formatter and the panel**

`CorrectionFlash.text(original:converted:)` returns `"\(original) → \(converted)"`, truncated to 60 characters with a trailing `…`. The panel is an `NSPanel` with `.nonactivatingPanel`, style `.borderless`, `level = .floating`, `collectionBehavior` including `.canJoinAllSpaces`, `ignoresMouseEvents = true`, and `isOpaque = false`. Position it 16pt from the top-right of the screen's visible frame, show for `duration`, then hide. Create the panel once and reuse it; do not allocate per correction.

- [ ] **Step 4: Implement notifications**

`NotificationService.requestAuthorization()` asks for `.alert` and `.sound`. `showUndoNotice` and `showLearnedNotice` build `UNMutableNotificationContent` with the exact strings the engine already logs, so the menu and the notification can never disagree. Learned notices are always delivered; undo notices respect `notifyOnEveryUndo`. An unauthorised centre is not an error — every method returns quietly.

- [ ] **Step 5: Wire both to the engine**

Drive everything from `AppEventHub`'s published values instead of sniffing `LogBuffer.shared`:

- `hub.lastCorrection` — when a new correction lands and the live `state.showCorrectionFlash` is on, call `flash.show(CorrectionFlash.text(original:converted:))` (the tested formatter; do not re-implement the string).
- `hub.lastLearned` — fire the learned notice; the icon flash is Task 3's.
- `hub.lastUndo` — fire the undo notice, carrying `prefix`/`converted`/`count`/`threshold`.

The undo notice is already gated upstream: `UndoLearningController` emits `.undo` only when the live `notifyProvider()` (Task 2's `state.notifyOnEveryUndo`) is true, exactly like the console's own `Отменено:` line. Do not gate `hub.lastUndo` a second time — or, if you do, say plainly in the service's header that it is a second gate; a hidden second gate is how the menu and the notifications drift apart.
- Wire `Журнал…`: `StatusItemController` already accepts `onOpenLog` (nil since Task 3, which keeps the row disabled). Pass an opener that shows the settings window with the `Журнал` tab selected. The selection lives on the window's held model and `SettingsView`'s `TabView` binds to it (the same held-model pattern as the other tabs); the existing `show()` keeps opening the default tab.

- [ ] **Step 6: Verify**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10 && swift run rukey --test-conversion 2>&1 | tail -8`
Expected: `Build complete!`, green suite, five unchanged sample lines.

- [ ] **Step 7: Manual check**

Trigger one autocorrection, three undo notices, and a learned word. Expect: a corner panel per correction that disappears on its own, notification banners matching the menu text exactly, and the learned notice appearing once. **Owner-performed:** an agent executing this plan records it as *unverified*; the commit message carries no manual-check claims.

- [ ] **Step 8: Commit**

```bash
git add Sources/RukeyGUI/ Tests/RukeyGUITests/
git commit -m "Add correction flash and undo notifications"
git push
```

---

### Task 8: End-to-end verification

**Files:**
- Modify: `README.md`
- Carried from the review-focus audit: `Sources/RukeyGUI/StatusItemController.swift` and `Sources/RukeyGUI/AppDelegate.swift` gained the pre-grant «Открыть настройки Accessibility» row promised by Review Focus 1 and row 3 (a named manual check, no test pin).

**Interfaces:**
- Consumes: everything above.
- Produces: a README that matches the shipped app.

- [ ] **Step 1: Full build and test**

Run: `swift build -c release 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: `Build complete!` and a green suite.

- [ ] **Step 2: Package and verify signing**

Run: `bash tools/package-app.sh`
Expected: a signed `dist/Rukey.app` with the Rukey identity, not `(adhoc)`.

- [ ] **Step 3: Manual pass over every spec behaviour**

Work through this list and record each result in the commit message. Every line must pass before this task closes. **Owner-performed:** the whole pass needs a live GUI session, a real Accessibility grant and a human at the keyboard — an agent executing this plan reports these 17 rows as *unverified* and hands the owner exactly this table as the checklist.

| # | Check |
|---|---|
| 1 | Double-clicking `Rukey.app` starts it with no console window |
| 2 | No Dock icon; an icon appears in the menu bar |
| 3 | Without Accessibility rights: red status, app alive, button opens the right Settings pane |
| 4 | Granting rights while running starts the tap without a relaunch |
| 5 | `ghbdtn` becomes `привет`; the corner panel shows it for about a second |
| 6 | Undo within any time restores the original, including after typing more characters |
| 7 | A click elsewhere in the field disables undo, and `⌥` toggles the layout instead |
| 8 | `⌥` in a password field does not toggle the layout |
| 9 | A word in `Не заменять` never converts, and stays put while being typed |
| 10 | Removing that word restores normal behaviour immediately |
| 11 | Three undos of the same word add it to the filter and raise the learned notice |
| 12 | The learned word is removable from both the banner and the settings list |
| 13 | A word in `Мои слова` converts even though it is not in the dictionaries |
| 14 | Adding Safari to the applications list stops correction in Safari without a restart |
| 15 | Launch-at-login toggles a real LaunchAgent and survives a relaunch |
| 16 | The log tab shows what the CLI printed before |
| 17 | `swift run rukey --test-conversion` produces the five documented lines |

- [ ] **Step 4: Update the README**

Rewrite the build and run sections to describe `bash tools/package-app.sh`, the Accessibility grant, the menu-bar icon, and the three config files. Keep the architecture section's technical description — it is still accurate — and remove the "Press Ctrl+C to stop" line, which no longer describes the GUI.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document the packaged app and record the end-to-end verification results"
git push
```

## Out of Scope

Settings persistence beyond the three JSON files and the LaunchAgent. Cloud sync. A multi-entry undo history — the engine plan deliberately restricts undo to the most recent correction, so the history rows in the log tab are read-only. Themes beyond the system template-image behaviour.