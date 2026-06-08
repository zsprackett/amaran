import Foundation

/// Atomic, owner-only persistence for `state.json`, matching the existing
/// `NativeMeshState.writePayload` behavior: parent directory created `0700`,
/// file written atomically and chmod'd `0600`, JSON pretty-printed with sorted
/// keys and a trailing newline.
public enum StateStore {
    /// Canonical encoder for state files (deterministic, diff-friendly).
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        // 2-space indent, sorted keys, unescaped slashes, trailing newline. The
        // `"key" : value` spacing is Apple's JSON output style and matches the
        // app's existing NativeMeshState (JSONSerialization) writer.
        var data = try makeEncoder().encode(value)
        data.append(0x0a)
        return data
    }

    public static func encode(_ state: State) throws -> Data {
        try encoded(state)
    }

    public static func load(_ path: String) throws -> State {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(State.self, from: data)
    }

    public static func save(_ state: State, to path: String) throws {
        try writeEncodable(state, to: path)
    }

    /// Atomically writes any Encodable as canonical state-file JSON (sorted keys,
    /// pretty, trailing newline) with the same 0700-dir / 0600-file handling.
    public static func writeEncodable<T: Encodable>(_ value: T, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encoded(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
