// Layout tables: the physical-key -> character mapping for each supported layout.
//
// The tables are read from the running system via UCKeyTranslate, never hardcoded.
// keycode_probe confirmed the expected values on this machine (M.RU[42] == "ё"), but a
// hardcoded table would be wrong the moment the user adds or removes an input source.

import Carbon
import Foundation

public enum Language: String, Sendable, CaseIterable {
    case english = "en"
    case russian = "ru"

    /// Input source IDs as they appear on macOS. Discovered dynamically in production;
    /// these are the fallbacks used when discovery fails.
    public var fallbackInputSourceIDs: [String] {
        switch self {
        case .english: ["com.apple.keylayout.US", "com.apple.keylayout.ABC"]
        case .russian: ["com.apple.keylayout.Russian", "com.apple.keylayout.Russian-Win"]
        }
    }
}

public enum LayoutError: Error, CustomStringConvertible {
    case inputSourceNotFound(String)
    case unicodeLayoutDataUnavailable(String)
    case translateFailed(keyCode: UInt16)

    public var description: String {
        switch self {
        case .inputSourceNotFound(let id):
            "input source not found: \(id)"
        case .unicodeLayoutDataUnavailable(let id):
            "no kTISPropertyUnicodeKeyLayoutData for \(id)"
        case .translateFailed(let kc):
            "UCKeyTranslate failed for keycode \(kc)"
        }
    }
}

/// One layout's physical-key -> character table.
public struct LayoutTable: Sendable {
    /// Characters by virtual key code. Index = key code, value = character or nil.
    /// Key codes that produce nothing in this layout are nil.
    public let chars: [UInt16: Character]
    public let language: Language

    public init(chars: [UInt16: Character], language: Language) {
        self.chars = chars
        self.language = language
    }

    public func character(forKeyCode keyCode: UInt16) -> Character? {
        chars[keyCode]
    }

    /// Inverse of `character(forKeyCode:)`. A key code with no character in this layout
    /// is absent from the result.
    public var keyCodes: [Character: UInt16] {
        var out: [Character: UInt16] = [:]
        for (kc, ch) in chars { out[ch] = kc }
        return out
    }

    /// True when this layout can produce every character of `text`.
    public func canProduce(_ text: String) -> Bool {
        let codes = keyCodes
        return text.allSatisfy { codes[$0] != nil }
    }
}

public enum LayoutLoader {
    /// UCKeyTranslate and TISCreateInputSourceList are not thread-safe. swift-testing runs
    /// tests in parallel by default and crashes with SIGABRT without this; the tap, which
    /// loads tables lazily from an event callback, is not guaranteed to be on one thread
    /// either. Everything goes through this lock.
    private static let lock = NSLock()

    /// Virtual key codes probed on a US layout. Letters live at 0..20, and the Cyrillic
    /// letters that sit on punctuation keys live at 30/33/39/41/42/43/47.
    ///
    /// The set is deliberately a superset: it includes the key codes where US produces a
    /// letter AND the key codes where US produces punctuation, because the Cyrillic layout
    /// puts letters on several of those punctuation positions.
    private static let candidateKeyCodes: [UInt16] = {
        let letterCodes: [UInt16] = (0...20).map(UInt16.init) + [31, 32, 34, 35, 37, 38, 40, 45, 46]
        let cyrillicOnPunctuation: [UInt16] = [30, 33, 39, 41, 42, 43, 47]
        return Array(Set(letterCodes + cyrillicOnPunctuation)).sorted()
    }()

    /// Reads a layout's character table from the system.
    public static func load(language: Language, inputSourceID: String? = nil) throws -> LayoutTable {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(language: language, inputSourceID: inputSourceID)
    }

    private static func loadUnlocked(language: Language, inputSourceID: String?) throws -> LayoutTable {
        let source = try resolveInputSource(language: language, inputSourceID: inputSourceID)
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw LayoutError.unicodeLayoutDataUnavailable(inputSourceID ?? language.rawValue)
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data

        var chars: [UInt16: Character] = [:]
        for keyCode in candidateKeyCodes {
            guard let ch = translate(layoutData: layoutData, keyCode: keyCode, keyboardType: 0) else { continue }
            // Only letters. Punctuation is handled separately at conversion time and must
            // not enter the inverse map, or "-" would look like a letter.
            guard ch.isLetter else { continue }
            chars[keyCode] = ch
        }
        guard !chars.isEmpty else { throw LayoutError.translateFailed(keyCode: 0) }
        return LayoutTable(chars: chars, language: language)
    }

    private static func translate(layoutData: Data, keyCode: UInt16, keyboardType: UInt32) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,                      // no modifiers: we want the bare letter
                keyboardType,
                OptionBits(0),
                &deadKeyState,
                8,
                &length,
                &chars
            )
        }
        guard status == noErr, length == 1, chars[0] != 0,
              let scalar = UnicodeScalar(chars[0]) else { return nil }
        return Character(scalar)
    }

    /// All input source IDs present on the system, for diagnostics.
    public static func availableInputSourceIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
        else { return [] }
        return list.compactMap {
            guard let p = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
    }

    private static func resolveInputSource(language: Language, inputSourceID: String?) throws -> TISInputSource {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
        else { throw LayoutError.inputSourceNotFound(language.rawValue) }

        func id(of source: TISInputSource) -> String? {
            guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }

        if let wanted = inputSourceID, let match = list.first(where: { id(of: $0) == wanted }) {
            return match
        }
        for candidate in language.fallbackInputSourceIDs {
            if let match = list.first(where: { id(of: $0) == candidate }) { return match }
        }
        throw LayoutError.inputSourceNotFound(inputSourceID ?? language.fallbackInputSourceIDs.joined(separator: "|"))
    }
}