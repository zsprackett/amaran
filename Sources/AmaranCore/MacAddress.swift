import Foundation

/// Error thrown when a MAC address cannot be normalized.
public enum MacAddressError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let value):
            return "MAC address must contain 12 hex digits: \(value)"
        }
    }
}

/// MAC normalization and display helpers.
///
/// `normalize` matches `NativeMeshState.normalizedMacAddress` (strict 12-hex,
/// uppercase, colon-joined). `suffix` matches `amaran_capabilities.mac_suffix`
/// (last six hex characters, uppercased, used for display).
public enum MacAddress {
    /// Strict normalization to `AA:BB:CC:DD:EE:FF`. Throws on bad input.
    public static func normalize(_ value: String) throws -> String {
        let compact = value.filter { $0 != ":" && $0 != "-" }.uppercased()
        guard compact.count == 12, compact.allSatisfy({ $0.isHexDigit }) else {
            throw MacAddressError.invalid(value)
        }
        var parts: [String] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            parts.append(String(compact[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }

    /// Returns nil for nil/empty input, otherwise the strict normalized form.
    public static func normalizeOptional(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return try normalize(value)
    }

    /// Last six hex characters, uppercased; non-hex characters are ignored.
    public static func suffix(_ value: String?) -> String {
        let hexOnly = (value ?? "").filter { $0.isHexDigit }.uppercased()
        return String(hexOnly.suffix(6))
    }

    /// Non-throwing display form: `AA:BB:CC:DD:EE:FF` for 12 hex digits,
    /// otherwise "unknown" (matches the zsh `mac_display`).
    public static func display(_ value: String?) -> String {
        let hex = (value ?? "").filter { $0.isHexDigit }.uppercased()
        guard hex.count == 12 else { return "unknown" }
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }
}
