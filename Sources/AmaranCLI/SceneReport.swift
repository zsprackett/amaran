import Foundation
import AmaranCore

public struct SceneSummary: Codable, Equatable {
    public let name: String
    public let capturedAt: String?
    public let fixtureCount: Int
    public let fixtures: [SceneFixture]
    public var deleted: Bool?
    enum CodingKeys: String, CodingKey {
        case name
        case capturedAt = "captured_at"
        case fixtureCount = "fixture_count"
        case fixtures, deleted
    }
}

public struct SceneListOutput: Codable, Equatable {
    public let scenes: [SceneSummary]
}

/// `scene list/show/delete` — the pure (no-daemon) scene operations, ported from
/// `scripts/scene-store`. `capture`/`apply` live with the control commands.
public enum SceneReport {
    public static func summary(name: String, scene: Scene) -> SceneSummary {
        SceneSummary(name: name, capturedAt: scene.capturedAt,
                     fixtureCount: scene.fixtures.count, fixtures: scene.fixtures, deleted: nil)
    }

    public static func list(_ state: State) -> [SceneSummary] {
        (state.scenes ?? [:]).sorted { $0.key < $1.key }.map { summary(name: $0.key, scene: $0.value) }
    }

    public static func show(_ state: State, name: String) throws -> SceneSummary {
        guard let scene = state.scenes?[name] else { throw CLIError("scene not found: \(name)") }
        return summary(name: name, scene: scene)
    }

    public static func delete(state: inout State, name: String) throws -> SceneSummary {
        guard let scene = state.scenes?[name] else { throw CLIError("scene not found: \(name)") }
        var result = summary(name: name, scene: scene)
        state.scenes?[name] = nil
        result.deleted = true
        return result
    }

    // MARK: - Human output

    public static func listLines(_ summaries: [SceneSummary]) -> [String] {
        guard !summaries.isEmpty else { return ["No scenes saved."] }
        return summaries.map { "\($0.name)\t\($0.fixtureCount)\t\($0.capturedAt ?? "unknown")" }
    }

    public static func showLines(_ summary: SceneSummary, state: State) -> [String] {
        let byAddress = Dictionary(
            state.fixtures.map { ($0.nodeAddress, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = ["\(summary.name)\t\(summary.fixtureCount)\t\(summary.capturedAt ?? "unknown")"]
        for entry in summary.fixtures {
            let capsFixture = byAddress[entry.nodeAddress] ?? syntheticFixture(entry)
            var parts = [entry.name.isEmpty ? "fixture-\(entry.nodeAddress)" : entry.name,
                         String(entry.nodeAddress)]
            if entry.sleepMode == 0 { parts.append("off") }
            if let intensity = entry.intensity { parts.append("\(trimFloat(intensity))%") }
            if let cct = entry.cct {
                parts.append("\(Capabilities.clampCct(cct, for: capsFixture))K")
            }
            if let gm = entry.gm, Capabilities.gmSupported(capsFixture) {
                parts.append("gm \(gm)")
            }
            lines.append(parts.joined(separator: "\t"))
        }
        return lines
    }

    /// Builds a fixture carrying just enough for capability resolution (name for
    /// the 400M5 family check) when the scene's fixture is no longer in state.
    private static func syntheticFixture(_ entry: SceneFixture) -> Fixture {
        Fixture(uuid: "", name: entry.name, nodeAddress: entry.nodeAddress, updateTime: "")
    }

    /// `%g`-style formatting (trims trailing zeros), matching Python's `:g`.
    private static func trimFloat(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }
}
