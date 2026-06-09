import Foundation

/// Error thrown when a hex string cannot be decoded.
public enum HexError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let value):
            return "invalid hex: \(value)"
        }
    }
}

/// Hex encode/decode matching the existing `NativeMeshCrypto` helpers.
public enum Hex {
    /// Lowercase, no separators, two characters per byte.
    public static func encode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes a hex string, ignoring whitespace and `:`/`-` separators.
    /// Throws `HexError.invalid` for odd-length or non-hex input.
    public static func decode(_ hex: String) throws -> [UInt8] {
        let compact = hex.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard compact.count % 2 == 0 else {
            throw HexError.invalid(hex)
        }

        var result: [UInt8] = []
        result.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw HexError.invalid(hex)
            }
            result.append(byte)
            index = next
        }
        return result
    }
}
