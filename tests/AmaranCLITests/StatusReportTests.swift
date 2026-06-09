import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct StatusReportTests {
    private func data(_ jsonString: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(jsonString.utf8))
    }

    private let sample = """
    {"native_send":{"address":3},
     "proxy_notifications":[
       {"access":{"telink":{"check_sum":171,"command_type":18,"opera_type":16,
         "cct":{"sleep_mode":1,"reserve":0,"cct_flag":0,"gm_flag":0,"gm_high":0,
                "gm_decoded":4,"cct_kelvin":5600,"cct":5600,"intensity":400,
                "intensity_percent":40}}}}]}
    """

    @Test func humanLineMatchesZshFormat() throws {
        let line = try StatusReport.humanLine(data(sample))
        #expect(line == "address 3, intensity 40%, cct 5600K, gm 4, sleep_mode 1")
    }

    @Test func statusObjectMapsFields() throws {
        let obj = try StatusReport.statusObject(data(sample))
        #expect(obj["address"]?.intValue == 3)
        #expect(obj["cct"]?["gm"]?.intValue == 4)          // from gm_decoded
        #expect(obj["cct"]?["cct"]?.intValue == 5600)      // from cct_kelvin
        #expect(obj["cct"]?["intensity"]?.intValue == 400)
        #expect(obj["cct"]?["check_sum"]?.intValue == 171)
        #expect(obj["menu"]?["type"]?["name"]?.stringValue == "CCT")
    }

    @Test func currentValuesForSpecBuilders() throws {
        // Operates on the parsed status object, as the cct/gm builders do.
        let parsed = try StatusReport.statusObject(data(sample))
        let values = StatusReport.currentValues(parsed: parsed)
        #expect(values.intensityTenths == 400)
        #expect(values.cctKelvin == 5600)
        #expect(values.greenMagenta == 4)
        #expect(values.gmFlag == 0)
    }

    @Test func throwsWhenNoCCT() {
        #expect(throws: CLIError.self) {
            _ = try StatusReport.humanLine(data("{\"proxy_notifications\":[]}"))
        }
    }
}
