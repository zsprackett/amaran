import Foundation

/// Resolved CCT/green-magenta capabilities for a fixture.
public struct ResolvedCapabilities: Equatable, Codable {
    public var cctMin: Int
    public var cctMax: Int
    public var gmSupported: Bool

    enum CodingKeys: String, CodingKey {
        case cctMin = "cct_min"
        case cctMax = "cct_max"
        case gmSupported = "gm_supported"
    }
}

/// Fixture capability and selection helpers, ported from the former
/// `scripts/amaran_capabilities.py`. This is now the single source of truth.
public enum Capabilities {
    /// Resolves a fixture's CCT range and G/M support, applying the 400M5
    /// family override and any explicit `capabilities` block.
    public static func resolve(_ fixture: Fixture) -> ResolvedCapabilities {
        var cctMin = 2000
        var cctMax = 10000
        var gmSupported = true

        let code = fixture.code.uppercased()
        let name = fixture.name.uppercased()
        if code == "400M5" || name.hasPrefix("400M5-") {
            cctMin = 2700
            cctMax = 6500
            gmSupported = false
        }

        if let explicit = fixture.capabilities {
            if let value = explicit.cctMin { cctMin = value }
            if let value = explicit.cctMax { cctMax = value }
            if let value = explicit.gmSupported { gmSupported = value }
        }

        if cctMin > cctMax {
            swap(&cctMin, &cctMax)
        }
        return ResolvedCapabilities(cctMin: cctMin, cctMax: cctMax, gmSupported: gmSupported)
    }

    public static func gmSupported(_ fixture: Fixture) -> Bool {
        resolve(fixture).gmSupported
    }

    /// Treats values below 1000 as deci-kelvin (matching `normalize_cct_kelvin`).
    public static func normalizeCctKelvin(_ value: Int) -> Int {
        value < 1000 ? value * 10 : value
    }

    /// Normalizes then clamps a CCT value to the fixture's supported range.
    public static func clampCct(_ value: Int, for fixture: Fixture) -> Int {
        let caps = resolve(fixture)
        let cct = normalizeCctKelvin(value)
        return max(caps.cctMin, min(caps.cctMax, cct))
    }

    /// Display label, mirroring `fixture_label`.
    public static func label(_ fixture: Fixture) -> String {
        if let friendly = fixture.friendlyName, !friendly.isEmpty {
            return friendly
        }
        if !fixture.name.isEmpty {
            return fixture.name
        }
        let suffix = MacAddress.suffix(fixture.macAddress)
        if !fixture.code.isEmpty, !suffix.isEmpty {
            return "\(fixture.code)-\(suffix)"
        }
        return suffix.isEmpty ? "fixture-\(fixture.nodeAddress)" : suffix
    }

    /// Selector strings that match a fixture, mirroring `selector_values`.
    public static func selectorValues(_ fixture: Fixture) -> [String] {
        var values = [String(fixture.nodeAddress), "0x" + String(fixture.nodeAddress, radix: 16)]
        if let friendly = fixture.friendlyName, !friendly.isEmpty {
            values.append(friendly)
        }
        if !fixture.name.isEmpty {
            values.append(fixture.name)
        }
        values.append(label(fixture))
        return values
    }

    /// Resolves a fixture from a selector, mirroring `selected_fixture`:
    /// a unique match for an explicit selector, otherwise the sole fixture.
    public static func selectedFixture(_ fixtures: [Fixture], selector: String?) -> Fixture? {
        if let selector, !selector.isEmpty {
            let matches = fixtures.filter { selectorValues($0).contains(selector) }
            return matches.count == 1 ? matches[0] : nil
        }
        return fixtures.count == 1 ? fixtures[0] : nil
    }
}
