import Foundation

/// UTC ISO-8601 timestamps without fractional seconds (e.g. `2024-01-15T10:30:45Z`),
/// matching the zsh `now_iso` format.
public enum Timestamp {
    public static func nowISO8601() -> String {
        iso8601(from: Date())
    }

    public static func iso8601(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
