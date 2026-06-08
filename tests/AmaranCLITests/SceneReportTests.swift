import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct SceneReportTests {
    private func state(scenes: [String: Scene]) -> State {
        State(syncedAt: "t", source: Source(type: "native_provisioning"),
              mesh: Mesh(uuid: "m", netKey: String(repeating: "ab", count: 16),
                         appKey: String(repeating: "cd", count: 16), updateTime: "t"),
              fixtures: [Fixture(uuid: "f", code: "400M5", name: "key", nodeAddress: 3, updateTime: "t")],
              runtime: Runtime(ivIndex: 0, sourceAddress: 4, telinkSourceAddress: 1,
                               sequenceNext: 1, updatedAt: "t"),
              scenes: scenes)
    }

    private let sceneA = Scene(capturedAt: "2026-01-01T00:00:00Z", fixtures: [
        SceneFixture(nodeAddress: 3, name: "key", macSuffix: "AABBCC",
                     intensity: 75.0, cct: 5600, gm: 4, sleepMode: 1),
    ])
    private let sceneB = Scene(capturedAt: "2026-02-02T00:00:00Z", fixtures: [])

    @Test func listSortsByName() {
        let summaries = SceneReport.list(state(scenes: ["warm": sceneA, "cool": sceneB]))
        #expect(summaries.map(\.name) == ["cool", "warm"])
        #expect(summaries[1].fixtureCount == 1)
    }

    @Test func showReturnsSummaryOrThrows() throws {
        let s = state(scenes: ["warm": sceneA])
        let summary = try SceneReport.show(s, name: "warm")
        #expect(summary.fixtures.first?.cct == 5600)
        #expect(throws: CLIError.self) { _ = try SceneReport.show(s, name: "missing") }
    }

    @Test func deleteRemovesSceneAndFlags() throws {
        var s = state(scenes: ["warm": sceneA, "cool": sceneB])
        let result = try SceneReport.delete(state: &s, name: "warm")
        #expect(result.deleted == true)
        #expect(s.scenes?["warm"] == nil)
        #expect(s.scenes?["cool"] != nil)
        #expect(throws: CLIError.self) { _ = try SceneReport.delete(state: &s, name: "warm") }
    }

    @Test func showLinesRenderFixtureDetail() {
        let s = state(scenes: ["warm": sceneA])
        let summary = try! SceneReport.show(s, name: "warm")
        let lines = SceneReport.showLines(summary, state: s)
        // fixture line: name, address, intensity, cct (400M5 clamps 5600 -> 6500 cap is 6500 so stays 5600)
        #expect(lines[1].contains("key"))
        #expect(lines[1].contains("75%"))
        #expect(lines[1].contains("5600K"))
        // 400M5 does not support gm, so gm omitted
        #expect(!lines[1].contains("gm"))
    }
}
