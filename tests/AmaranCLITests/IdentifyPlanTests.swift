import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct IdentifyPlanTests {
    private func parsed(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: json.data(using: .utf8)!)
    }

    @Test func planForOnFixture() throws {
        let plan = IdentifyPlan.plan(parsed: try parsed(
            "{\"address\":3,\"cct\":{\"sleep_mode\":1,\"intensity\":400,\"cct\":5600,\"gm\":4,\"gm_flag\":0}}"))
        #expect(plan.address == 3)
        #expect(plan.originalState == "on")
        #expect(plan.restoreSpec == "cct:5600:40:4:0")
        #expect(plan.flashOnSpec == "cct:5600:100:4:0")
        #expect(plan.sequence() == [
            "off", "on", "cct:5600:40:4:0",
            "off", "on", "cct:5600:40:4:0",
            "off", "on", "cct:5600:40:4:0",
            "on", "cct:5600:40:4:0", "cct:5600:40:4:0"
        ])
    }

    @Test func planForOffFixture() throws {
        let plan = IdentifyPlan.plan(parsed: try parsed(
            "{\"address\":3,\"cct\":{\"sleep_mode\":0,\"intensity\":400,\"cct\":5600}}"))
        #expect(plan.originalState == "off")
        #expect(plan.restoreSpec == "off")
        #expect(plan.sequence() == [
            "on", "cct:5600:100:10:0", "off",
            "on", "cct:5600:100:10:0", "off",
            "on", "cct:5600:100:10:0", "off",
            "off"
        ])
    }
}
