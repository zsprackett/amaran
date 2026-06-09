import Foundation
import AmaranCore

/// Formats daemon responses for display, matching the zsh dispatcher's output.
public enum DaemonReport {
    public static func humanStatus(_ response: DaemonResponse) -> String {
        guard response.succeeded, let data = response.data else {
            return "daemon error: \(response.error ?? "unknown")"
        }
        let pid = data["daemon"]?["pid"]?.intValue.map(String.init) ?? "?"
        let state = data["central_state"]?.stringValue ?? "unknown"
        let connected = (data["connected"]?.boolValue ?? false) ? "yes" : "no"
        return "daemon running: pid \(pid), bluetooth \(state), connected \(connected)"
    }

    /// Compact JSON for `--json` output.
    public static func compactJSON(_ response: DaemonResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8)
        else {
            return "{\"ok\":false}"
        }
        return text
    }
}
