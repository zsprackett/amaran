import Foundation
import AmaranCore

/// Builds `cct:...`/`gm:...` control specs from user input plus the fixture's
/// current status, ported from the zsh `build_native_cct_spec_from_status` and
/// `build_native_gm_spec_from_status`.
public enum ControlSpecBuilder {
    /// Whether `cct` needs a status read: when intensity is omitted, or GM is
    /// omitted on a GM-capable fixture.
    public static func cctNeedsStatus(intensityPercent: Double?, gm greenMagenta: Int?, fixture: Fixture) -> Bool {
        let gmSupported = Capabilities.gmSupported(fixture)
        return intensityPercent == nil || (greenMagenta == nil && gmSupported)
    }

    public struct CctSpec {
        public let spec: String
        public let clampWarning: String?
    }

    public static func cctSpec(
        requestedKelvin: Int,
        intensityPercent: Double?,
        gm gmArg: Int?,
        fixture: Fixture,
        current: StatusReport.CurrentValues?
    ) throws -> CctSpec {
        let caps = Capabilities.resolve(fixture)
        let label = Capabilities.label(fixture)

        if gmArg != nil, !caps.gmSupported {
            throw CLIError("\(label) does not support green-magenta correction")
        }

        let kelvin = max(caps.cctMin, min(caps.cctMax, requestedKelvin))
        let warning = kelvin != requestedKelvin
            ? "cct \(requestedKelvin)K clamped to \(kelvin)K for \(label)" : nil

        let intensityPercentValue: Double
        if let intensityPercent {
            intensityPercentValue = try validatedPercent(intensityPercent)
        } else if let tenths = current?.intensityTenths {
            intensityPercentValue = tenths / 10.0
        } else {
            throw CLIError("status did not include current intensity")
        }

        let greenMagenta: Int
        let gmFlag: Int
        if let gmArg {
            greenMagenta = try validatedGM(gmArg)
            gmFlag = 0
        } else if !caps.gmSupported {
            greenMagenta = 10
            gmFlag = 0
        } else {
            greenMagenta = current?.greenMagenta ?? 10
            gmFlag = current?.gmFlag ?? 0
        }

        let spec = "cct:\(kelvin):\(trimFloat(intensityPercentValue)):\(greenMagenta):\(gmFlag)"
        return CctSpec(spec: spec, clampWarning: warning)
    }

    public static func gmSpec(
        gm gmArg: Int, fixture: Fixture, current: StatusReport.CurrentValues
    ) throws -> String {
        let label = Capabilities.label(fixture)
        guard Capabilities.gmSupported(fixture) else {
            throw CLIError("\(label) does not support green-magenta correction")
        }
        let greenMagenta = try validatedGM(gmArg)
        guard let kelvin = current.cctKelvin else {
            throw CLIError("status did not include current CCT")
        }
        guard let tenths = current.intensityTenths else {
            throw CLIError("status did not include current intensity")
        }
        return "cct:\(kelvin):\(trimFloat(tenths / 10.0)):\(greenMagenta):0"
    }

    // MARK: - Validation

    private static func validatedPercent(_ value: Double) throws -> Double {
        guard value >= 0, value <= 100 else {
            throw CLIError("--intensity must be between 0 and 100")
        }
        return value
    }

    private static func validatedGM(_ value: Int) throws -> Int {
        guard value >= 0, value <= 20 else {
            throw CLIError("--gm must be an integer from 0 to 20")
        }
        return value
    }

    static func trimFloat(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }
}
