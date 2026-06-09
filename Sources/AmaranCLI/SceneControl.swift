import Foundation
import AmaranCore

/// Pure helpers for `scene capture`/`scene apply`, ported from `scripts/scene-store`.
public enum SceneControl {
    /// Builds a captured `SceneFixture` from a parsed status object, mirroring
    /// `normalize_status`.
    public static func sceneFixture(parsed: JSONValue, fixture: Fixture) -> SceneFixture {
        let cct = parsed["cct"]?.objectValue ?? [:]
        let intensity = cct["intensity_percent"]?.doubleValue
            ?? cct["intensity"]?.doubleValue.map { $0 / 10 }
        let clampedCct = cct["cct"]?.intValue.map { Capabilities.clampCct($0, for: fixture) }
        let greenMagenta = Capabilities.gmSupported(fixture) ? cct["gm"]?.intValue : nil
        return SceneFixture(
            nodeAddress: fixture.nodeAddress,
            name: Capabilities.label(fixture),
            macSuffix: MacAddress.suffix(fixture.macAddress),
            intensity: intensity,
            cct: clampedCct,
            greenMagenta: greenMagenta,
            sleepMode: cct["sleep_mode"]?.intValue)
    }

    /// A fixture forced off in a scene (via `--off-node`), mirroring `forced_off_status`.
    public static func forcedOff(_ fixture: Fixture) -> SceneFixture {
        SceneFixture(
            nodeAddress: fixture.nodeAddress,
            name: Capabilities.label(fixture),
            macSuffix: MacAddress.suffix(fixture.macAddress),
            intensity: nil, cct: nil, greenMagenta: nil, sleepMode: 0)
    }

    /// Control specs to apply a captured scene fixture, mirroring `control()`.
    /// (External scenes lacking GM on a GM-capable fixture default GM to neutral
    /// rather than re-reading live status.)
    public static func applySpecs(entry: SceneFixture, fixture: Fixture) -> [String] {
        if entry.sleepMode == 0 { return ["off"] }
        let caps = Capabilities.resolve(fixture)

        if let cct = entry.cct, let intensity = entry.intensity {
            let kelvin = Capabilities.clampCct(cct, for: fixture)
            let greenMagenta = (caps.gmSupported && entry.greenMagenta != nil) ? entry.greenMagenta! : 10
            return ["on", "cct:\(kelvin):\(trimFloat(intensity)):\(greenMagenta):0"]
        }
        if let intensity = entry.intensity {
            return ["on", "intensity:\(trimFloat(intensity))"]
        }
        return ["on"]
    }

    static func trimFloat(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }

    /// Resolves scene fixture selectors (address/hex/friendly/name). No selectors
    /// means all fixtures; otherwise a unique fixture per selector. Mirrors
    /// `selected_fixtures`/`select_fixture` in scene-store.
    public static func selectedFixtures(_ state: State, selectors: [String]) throws -> [Fixture] {
        let active = selectors.filter { !$0.isEmpty }
        if active.isEmpty { return state.fixtures }
        var result: [Fixture] = []
        var seen = Set<Int>()
        for selector in active {
            let fixture = try select(state.fixtures, selector)
            if seen.insert(fixture.nodeAddress).inserted { result.append(fixture) }
        }
        return result
    }

    private static func select(_ fixtures: [Fixture], _ selector: String) throws -> Fixture {
        let matches = fixtures.filter { FixtureOps.selectorValues($0).contains(selector) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw CLIError("scene fixture selector is ambiguous: \(selector)") }
        throw CLIError("scene fixture not found: \(selector)")
    }
}
