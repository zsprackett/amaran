import Foundation
import AmaranCore

enum Paths {
    /// Home-relative display form (`~/...`), matching the zsh `display_path`.
    static func display(_ path: String, home: String = NSHomeDirectory()) -> String {
        let abs = absolute(path)
        if abs == home { return "~" }
        if abs.hasPrefix(home + "/") { return "~" + abs.dropFirst(home.count) }
        return abs
    }

    static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Reads and parses a JSON file into a JSONValue, or throws a CLIError with
    /// the given subject (e.g. "join state file").
    static func readJSON(_ path: String, subject: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            throw CLIError("\(subject) could not be read")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw CLIError("\(subject) could not be read: invalid JSON")
        }
    }
}
