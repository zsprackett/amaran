import Foundation
import AmaranCore

/// Plan for `amaran identify`: how to flash a fixture and restore it, ported from
/// `run_identify_command`. Operates on a parsed status object.
public struct IdentifyPlan: Equatable {
    public let address: Int?
    public let originalState: String   // "on" or "off"
    public let restoreSpec: String
    public let flashOnSpec: String

    public static func plan(parsed: JSONValue) -> IdentifyPlan {
        let cct = parsed["cct"]?.objectValue ?? [:]
        let address = parsed["address"]?.intValue
        let sleepMode = cct["sleep_mode"]?.intValue
        let intensity = cct["intensity_percent"]?.doubleValue
            ?? cct["intensity"]?.doubleValue.map { $0 / 10 }
        let kelvin = cct["cct"]?.intValue
        let greenMagenta = cct["gm"]?.intValue ?? 10
        let gmFlag = cct["gm_flag"]?.intValue ?? 0

        func cctSpec(_ kelvinValue: Int, _ percent: Double) -> String {
            "cct:\(kelvinValue):\(trimFloat(percent)):\(greenMagenta):\(gmFlag)"
        }

        var restoreSpec: String
        if let kelvin, let intensity {
            restoreSpec = cctSpec(kelvin, intensity)
        } else if let intensity {
            restoreSpec = "intensity:\(trimFloat(intensity))"
        } else {
            restoreSpec = "on"
        }

        var originalState = "on"
        if sleepMode == 0 {
            originalState = "off"
            restoreSpec = "off"
        }

        let flashOnSpec = kelvin.map { cctSpec($0, 100) } ?? "intensity:100"
        return IdentifyPlan(address: address, originalState: originalState,
                            restoreSpec: restoreSpec, flashOnSpec: flashOnSpec)
    }

    /// The control sequence for three flashes plus restore.
    public func sequence() -> [String] {
        var specs: [String] = []
        for _ in 0..<3 {
            specs += originalState == "off" ? ["on", flashOnSpec, "off"] : ["off", "on", restoreSpec]
        }
        specs += originalState == "off" ? ["off"] : ["on", restoreSpec, restoreSpec]
        return specs
    }

    private static func trimFloat(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }
}
