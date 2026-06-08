import Foundation

/// Error thrown when a control spec string is malformed.
public enum ControlSpecError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let value):
            return "invalid control spec: \(value)"
        }
    }
}

/// The control-spec grammar exchanged between the CLI and the daemon, ported
/// from `NativeTelinkControlCommand.parse`.
///
/// Numeric values for `intensity`/`cct` are kept as strings to match the native
/// parser, which validates and converts them only when building the Telink
/// packet. Telink raw-packet checksum validation likewise stays in the app's
/// Telink layer; this type owns the spec string grammar.
public enum ControlSpec: Equatable {
    case on
    case off
    case intensity(percent: String)
    case cct(kelvin: String, intensity: String, gm: Int, gmFlag: Int)
    case raw(hex: String)
    case status

    public static func parse(_ spec: String) throws -> ControlSpec {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first else {
            throw ControlSpecError.invalid(spec)
        }

        switch name {
        case "on":
            try requirePartCount(parts, 1, spec)
            return .on
        case "off":
            try requirePartCount(parts, 1, spec)
            return .off
        case "status":
            try requirePartCount(parts, 1, spec)
            return .status
        case "intensity":
            try requirePartCount(parts, 2, spec)
            return .intensity(percent: parts[1])
        case "cct":
            guard parts.count == 5, let gm = Int(parts[3]), let gmFlag = Int(parts[4]) else {
                throw ControlSpecError.invalid(spec)
            }
            return .cct(kelvin: parts[1], intensity: parts[2], gm: gm, gmFlag: gmFlag)
        case "raw":
            try requirePartCount(parts, 2, spec)
            return .raw(hex: parts[1])
        default:
            throw ControlSpecError.invalid(spec)
        }
    }

    /// The canonical spec string. `parse(spec).serialized == spec` for canonical input.
    public var serialized: String {
        switch self {
        case .on: return "on"
        case .off: return "off"
        case .status: return "status"
        case .intensity(let percent): return "intensity:\(percent)"
        case .cct(let kelvin, let intensity, let gm, let gmFlag):
            return "cct:\(kelvin):\(intensity):\(gm):\(gmFlag)"
        case .raw(let hex): return "raw:\(hex)"
        }
    }

    private static func requirePartCount(_ parts: [String], _ expected: Int, _ spec: String) throws {
        guard parts.count == expected else {
            throw ControlSpecError.invalid(spec)
        }
    }
}
