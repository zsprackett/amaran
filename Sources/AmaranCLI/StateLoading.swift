import Foundation
import AmaranCore

/// Loads `state.json` for read/mutate commands with user-facing error messages
/// matching the zsh dispatcher.
public enum StateLoading {
    public static func load(_ path: String) throws -> State {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CLIError("local state not found at \(path)")
        }
        let state: State
        do {
            state = try StateStore.load(expanded)
        } catch {
            throw CLIError("local state could not be read (\(error))")
        }
        guard state.schemaVersion == 1 else {
            throw CLIError("unsupported state schema version: \(state.schemaVersion)")
        }
        return state
    }

    public static func save(_ state: State, to path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        try StateStore.save(state, to: expanded)
    }
}

/// Pretty JSON output for `--json`, matching the zsh `json.dumps(indent=2)` shape
/// (field names stable; slashes unescaped).
public enum JSONOutput {
    public static func pretty<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return text
    }
}
