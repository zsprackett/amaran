import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct DoctorReportTests {
    private func writeState(_ json: String) -> String {
        let path = NSTemporaryDirectory() + "amaran-doctor-\(UUID().uuidString).json"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private let validState = """
    {"schema_version":1,"synced_at":"t","source":{"type":"native_provisioning"},
     "mesh":{"uuid":"m","net_key":"00112233445566778899aabbccddeeff",
             "app_key":"ffeeddccbbaa99887766554433221100","fixtures_ordered_list":"[]",
             "scenes_ordered_list":"[]","update_time":"t","state":0},
     "fixtures":[{"uuid":"f","mac_address":"AABBCCDDEE03","code":"X","name":"n","node_address":3,
                  "device_key":"00112233445566778899aabbccddeeff",
                  "device_uuid":"ffeeddccbbaa99887766554433221100",
                  "composition_data":"0011223344556677889900","update_time":"t","state":0}],
     "runtime":{"iv_index":0,"source_address":4,"telink_source_address":1,"sequence_next":5,"updated_at":"t"}}
    """

    @Test func reportsUsableAndReady() {
        let path = writeState(validState)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = DoctorReport.inspect(statePath: path, home: "/home")
        #expect(data.state.exists == true)
        #expect(data.state.usable == true)
        #expect(data.state.fixtureCount == 1)
        #expect(data.state.checks?.meshHasNetKey == true)
        #expect(data.readiness.runtimeControlReady == true)
        #expect(data.readiness.missing.isEmpty)
        #expect(data.state.checks?.fixtures.first?.hasDeviceKey == true)
        #expect(data.state.checks?.fixtures.first?.hasCompositionData == true)
    }

    @Test func missingFileReportsNotReady() {
        let data = DoctorReport.inspect(
            statePath: NSTemporaryDirectory() + "missing-\(UUID().uuidString).json", home: "/home")
        #expect(data.state.exists == false)
        #expect(data.state.usable == false)
        #expect(data.readiness.runtimeControlReady == false)
        #expect(data.readiness.missing.contains("usable local state"))
        #expect(data.readiness.pairing.createsFirstState == true)
    }

    @Test func controlOnlyFixtureProducesWarnings() {
        let json = """
        {"schema_version":1,"synced_at":"t","source":{"type":"mesh_join_import"},
         "mesh":{"uuid":"m","net_key":"00112233445566778899aabbccddeeff",
                 "app_key":"ffeeddccbbaa99887766554433221100","fixtures_ordered_list":"[]",
                 "scenes_ordered_list":"[]","update_time":"t","state":0},
         "fixtures":[{"uuid":"f","mac_address":"","code":"","name":"n","node_address":3,
                      "composition_data":"","update_time":"t","state":0}],
         "runtime":{"iv_index":0,"source_address":4,"telink_source_address":1,"sequence_next":5,"updated_at":"t"}}
        """
        let path = writeState(json)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = DoctorReport.inspect(statePath: path, home: "/home")
        // Control-only (no device key) is still runtime-ready, but warns.
        #expect(data.readiness.runtimeControlReady == true)
        #expect(data.state.checks?.fixtures.first?.controlOnly == true)
        #expect(data.readiness.warnings.contains(where: { $0.contains("DeviceKey") }))
    }

    @Test func displayPathUsesTilde() {
        let data = DoctorReport.inspect(statePath: "/home/sub/state.json", home: "/home")
        #expect(data.state.path == "~/sub/state.json")
    }
}
