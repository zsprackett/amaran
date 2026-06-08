import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct SceneControlTests {
    private func fixture(code: String = "", name: String = "key", mac: String = "AABBCCDDEEFF") -> Fixture {
        Fixture(uuid: "f", macAddress: mac, code: code, name: name, nodeAddress: 3, updateTime: "t")
    }

    private func parsed(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: json.data(using: .utf8)!)
    }

    @Test func sceneFixtureFromStatus() throws {
        let status = try parsed(
            "{\"cct\":{\"intensity\":400,\"cct\":5600,\"gm\":4,\"sleep_mode\":1}}")
        let sf = SceneControl.sceneFixture(parsed: status, fixture: fixture())
        #expect(sf.nodeAddress == 3)
        #expect(sf.name == "key")
        #expect(sf.macSuffix == "DDEEFF")
        #expect(sf.intensity == 40)       // 400/10
        #expect(sf.cct == 5600)           // default range, no clamp
        #expect(sf.gm == 4)               // gm-capable default fixture
        #expect(sf.sleepMode == 1)
    }

    @Test func sceneFixtureDropsGmForUnsupportedFixture() throws {
        let status = try parsed("{\"cct\":{\"intensity\":500,\"cct\":4000,\"gm\":4,\"sleep_mode\":1}}")
        let sf = SceneControl.sceneFixture(parsed: status, fixture: fixture(code: "400M5"))
        #expect(sf.gm == nil)             // 400M5 has no gm
        #expect(sf.cct == 4000)
    }

    @Test func forcedOffFixture() {
        let sf = SceneControl.forcedOff(fixture())
        #expect(sf.sleepMode == 0)
        #expect(sf.intensity == nil)
        #expect(sf.cct == nil)
    }

    @Test func applySpecsForOff() {
        let entry = SceneFixture(nodeAddress: 3, name: "k", macSuffix: "x", sleepMode: 0)
        #expect(SceneControl.applySpecs(entry: entry, fixture: fixture()) == ["off"])
    }

    @Test func applySpecsForCctIntensityGm() {
        let entry = SceneFixture(nodeAddress: 3, name: "k", macSuffix: "x",
                                 intensity: 75, cct: 5600, gm: 6, sleepMode: 1)
        #expect(SceneControl.applySpecs(entry: entry, fixture: fixture())
            == ["on", "cct:5600:75:6:0"])
    }

    @Test func applySpecsDefaultsGmForUnsupported() {
        let entry = SceneFixture(nodeAddress: 3, name: "k", macSuffix: "x",
                                 intensity: 50, cct: 4000, gm: 6, sleepMode: 1)
        // 400M5 unsupported -> gm forced to 10; cct clamps into 2700..6500
        #expect(SceneControl.applySpecs(entry: entry, fixture: fixture(code: "400M5"))
            == ["on", "cct:4000:50:10:0"])
    }

    @Test func applySpecsIntensityOnly() {
        let entry = SceneFixture(nodeAddress: 3, name: "k", macSuffix: "x",
                                 intensity: 30, sleepMode: 1)
        #expect(SceneControl.applySpecs(entry: entry, fixture: fixture()) == ["on", "intensity:30"])
    }
}
