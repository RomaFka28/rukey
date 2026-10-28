import Foundation

/// Small, shared JSON file primitive used by the app's persistent stores.
public enum JSONPersistence {
    public static func read<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public static func write<Value: Encodable>(
        _ value: Value,
        to url: URL,
        prettyPrinted: Bool = false
    ) throws {
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
