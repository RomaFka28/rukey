import Carbon.HIToolbox
import Foundation

/// Switches the active keyboard input source by ID.
///
/// Why TIS and not posting ⌘-space or a synthetic event: the layout switch must land in the
/// system's own state, not be simulated on top of it. A simulated shortcut toggles whatever
/// is "next" in the user's rotation, which is exactly the behaviour that makes hotkey-based
/// layout switchers unpredictable.
public struct InputSourceSwitcher: Sendable {

    public let russianID: String
    public let englishID: String

    public init(russianID: String = "com.apple.keylayout.Russian",
                englishID: String = "com.apple.keylayout.US") {
        self.russianID = russianID
        self.englishID = englishID
    }

    public func id(for language: Language) -> String {
        switch language {
        case .russian: russianID
        case .english: englishID
        }
    }

    public func language(for id: String) -> Language? {
        if id == russianID { return .russian }
        if id == englishID { return .english }
        return nil
    }

    /// Select the input source for `language`. Returns false when the source is not enabled
    /// on this machine, which is a real configuration state and must not be papered over.
    @discardableResult
    public func select(_ language: Language) -> Bool {
        guard let source = Self.source(id: id(for: language)) else {
            FileHandle.standardError.write(Data("rukey: input source \(id(for: language)) is not enabled\n".utf8))
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    public var currentID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return Self.id(of: source)
    }

    public var currentLanguage: Language? {
        currentID.flatMap(language(for:))
    }

    static func source(id: String) -> TISInputSource? {
        let properties = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return source
    }

    static func id(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}