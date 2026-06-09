import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct StateJoinTests {
    private func json(_ jsonString: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(jsonString.utf8))
    }

    @Test func chooseSourceAddressPrefersThree() throws {
        #expect(try StateJoin.chooseSourceAddress(occupied: []) == 3)
        #expect(try StateJoin.chooseSourceAddress(occupied: [3]) == 4)
        #expect(try StateJoin.chooseSourceAddress(occupied: [3, 4]) == 5)
        #expect(try StateJoin.chooseSourceAddress(occupied: [3], destination: 4) == 5)
    }

    @Test func buildsControlOnlyStateWithoutDeviceKey() throws {
        let source = try json("""
        {"mesh":{"uuid":"studio","net_key":"00112233445566778899aabbccddeeff",
                 "app_key":"ffeeddccbbaa99887766554433221100"},
         "fixtures":[{"node_address":5,"mac":"AABBCCDDEE05","name":"key"}]}
        """)
        let state = try StateJoin.build(source: source, now: "t")
        #expect(state.source.type == "mesh_join_import")
        #expect(state.source.controlOnly == true)
        #expect(state.fixtures[0].controlOnly == true)
        #expect(state.fixtures[0].deviceKey == nil)
        #expect(state.fixtures[0].macAddress == "AA:BB:CC:DD:EE:05")
        #expect(state.runtime.sourceAddress == 3)       // fixture at 5; prefer 3
        #expect(state.runtime.telinkSourceAddress == 1) // 1 free
        #expect(state.runtime.lastReservedBy == "state-join")
    }

    @Test func buildsFullStateWithDeviceKey() throws {
        let source = try json("""
        {"mesh":{"uuid":"studio","net_key":"00112233445566778899aabbccddeeff",
                 "app_key":"ffeeddccbbaa99887766554433221100"},
         "fixtures":[{"node_address":3,"device_key":"00112233445566778899aabbccddeeff",
                      "device_uuid":"ffeeddccbbaa99887766554433221100","name":"key"}]}
        """)
        let state = try StateJoin.build(source: source, now: "t")
        #expect(state.source.controlOnly == false)
        #expect(state.fixtures[0].controlOnly == false)
        #expect(state.fixtures[0].deviceKey == "00112233445566778899aabbccddeeff")
        #expect(state.runtime.sourceAddress == 4)   // 3 occupied by fixture
        #expect(state.runtime.telinkSourceAddress == 1)
    }

    @Test func rejectsBadNetKey() throws {
        let source = try json("""
        {"mesh":{"uuid":"s","net_key":"abcd","app_key":"ffeeddccbbaa99887766554433221100"},
         "fixtures":[{"node_address":3}]}
        """)
        #expect(throws: CLIError.self) { _ = try StateJoin.build(source: source, now: "t") }
    }

    @Test func rejectsEmptyFixtures() throws {
        let source = try json("""
        {"mesh":{"uuid":"s","net_key":"00112233445566778899aabbccddeeff",
                 "app_key":"ffeeddccbbaa99887766554433221100"},"fixtures":[]}
        """)
        #expect(throws: CLIError.self) { _ = try StateJoin.build(source: source, now: "t") }
    }
}
