import Foundation
import AmaranCore

/// Parses a daemon/app status response into the redacted status object and human
/// line, ported from the zsh `run_native_status_app` formatter.
public enum StatusReport {
    /// The first proxy notification whose decoded Telink access payload carries a
    /// CCT block, or nil.
    private static func telinkWithCCT(_ data: JSONValue) -> JSONValue? {
        for notification in data["proxy_notifications"]?.arrayValue ?? [] {
            if let telink = notification["access"]?["telink"], telink["cct"] != nil {
                return telink
            }
        }
        return nil
    }

    /// Redacted status object (`{address, menu, cct}`) for `--json`.
    public static func statusObject(_ data: JSONValue) throws -> JSONValue {
        guard let telink = telinkWithCCT(data) else {
            throw CLIError("status returned no CCT packet")
        }
        let cct = telink["cct"]?.objectValue ?? [:]

        var cctOut: [String: JSONValue] = [:]
        func put(_ key: String, _ value: JSONValue?) {
            if let value, value != .null { cctOut[key] = value }
        }
        put("sleep_mode", cct["sleep_mode"])
        put("reserve", cct["reserve"])
        put("cct_flag", cct["cct_flag"])
        put("gm_flag", cct["gm_flag"])
        put("gm_high", cct["gm_high"])
        put("gm", cct["gm_decoded"])
        put("cct", cct["cct_kelvin"])
        put("intensity", cct["intensity"])
        put("intensity_percent", cct["intensity_percent"])
        put("check_sum", telink["check_sum"])
        put("command_type", telink["command_type"])
        put("opera_type", telink["opera_type"])

        let menu = JSONValue.object(["type": .object(["name": .string("CCT"), "value": .int(0)])])
        return .object([
            "address": data["native_send"]?["address"] ?? .null,
            "menu": menu,
            "cct": .object(cctOut)
        ])
    }

    /// Human one-line summary, e.g. `address 3, intensity 40%, cct 5600K, gm 4, sleep_mode 1`.
    public static func humanLine(_ data: JSONValue) throws -> String {
        guard let telink = telinkWithCCT(data) else {
            throw CLIError("status returned no CCT packet")
        }
        let cct = telink["cct"]?.objectValue ?? [:]
        let address = data["native_send"]?["address"]?.intValue.map(String.init) ?? "None"
        var parts = ["address \(address)"]
        if let intensity = cct["intensity"]?.doubleValue {
            parts.append("intensity \(trimFloat(intensity / 10))%")
        }
        if let kelvin = cct["cct_kelvin"]?.intValue {
            parts.append("cct \(kelvin)K")
        }
        if let greenMagenta = cct["gm_decoded"]?.intValue {
            parts.append("gm \(greenMagenta)")
        }
        if let sleep = cct["sleep_mode"]?.intValue {
            parts.append("sleep_mode \(sleep)")
        }
        return parts.joined(separator: ", ")
    }

    /// Pulls current intensity/CCT/GM out of the *parsed* status object (the
    /// `{address, menu, cct}` shape from `statusObject`) for the `cct`/`gm` spec
    /// builders. There `cct` maps `cct_kelvin`->`cct` and `gm_decoded`->`gm`.
    public struct CurrentValues {
        public let intensityTenths: Double?  // cct.intensity (0-1000)
        public let cctKelvin: Int?           // cct.cct
        public let greenMagenta: Int?        // cct.gm
        public let gmFlag: Int?              // cct.gm_flag
    }

    public static func currentValues(parsed: JSONValue) -> CurrentValues {
        let cct = parsed["cct"]?.objectValue ?? [:]
        return CurrentValues(
            intensityTenths: cct["intensity"]?.doubleValue,
            cctKelvin: cct["cct"]?.intValue,
            greenMagenta: cct["gm"]?.intValue,
            gmFlag: cct["gm_flag"]?.intValue)
    }

    static func trimFloat(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }
}
