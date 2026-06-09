import Foundation
import Testing
@testable import AmaranCore

struct StateModelTests {
    // Representative provisioned state with an extra/unknown fixture field
    // ("vendor_blob") plus the version strings the native writer emits.
    private let provisionedJSON = Data("""
    {
      "schema_version": 1,
      "synced_at": "2024-01-15T10:30:45Z",
      "source": {
        "type": "native_provisioning",
        "provisioned_at": "2024-01-15T10:30:45Z",
        "device_uuid": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
      },
      "mesh": {
        "uuid": "studio-mesh-001",
        "net_key": "0123456789abcdef0123456789abcdef",
        "app_key": "fedcba9876543210fedcba9876543210",
        "fixtures_ordered_list": "[]",
        "scenes_ordered_list": "[]",
        "update_time": "2024-01-15T10:30:45Z",
        "state": 0
      },
      "fixtures": [
        {
          "uuid": "fixture-1-uuid",
          "mac_address": "AA:BB:CC:DD:EE:FF",
          "code": "400M5",
          "name": "400M5-DDEEFF",
          "friendly_name": "key-light",
          "node_address": 6,
          "device_key": "11223344556677889900aabbccddeeff",
          "device_uuid": "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7",
          "composition_data": "",
          "element_count": 1,
          "update_time": "2024-01-15T10:30:45Z",
          "state": 0,
          "fast_provision_supported": 0,
          "control_hw_version": "",
          "vendor_blob": "keep-me"
        }
      ],
      "runtime": {
        "iv_index": 0,
        "source_address": 3,
        "telink_source_address": 1,
        "sequence_next": 1,
        "updated_at": "2024-01-15T10:30:45Z",
        "last_reserved_by": "provisioning"
      },
      "scenes": {
        "warm": {
          "captured_at": "2024-01-15T10:31:00Z",
          "fixtures": [
            {"node_address": 6, "name": "key-light", "mac_suffix": "DDEEFF",
             "intensity": 75.5, "cct": 3200, "gm": 10, "sleep_mode": 1}
          ]
        }
      }
    }
    """.utf8)

    private func decode(_ data: Data) throws -> State {
        try JSONDecoder().decode(State.self, from: data)
    }

    @Test func decodesRepresentativeState() throws {
        let state = try decode(provisionedJSON)
        #expect(state.schemaVersion == 1)
        #expect(state.mesh.netKey == "0123456789abcdef0123456789abcdef")
        #expect(state.fixtures.count == 1)
        #expect(state.fixtures[0].nodeAddress == 6)
        #expect(state.fixtures[0].friendlyName == "key-light")
        #expect(state.fixtures[0].deviceKey == "11223344556677889900aabbccddeeff")
        #expect(state.runtime.sequenceNext == 1)
        #expect(state.runtime.lastReservedBy == "provisioning")
        #expect(state.scenes?["warm"]?.fixtures.first?.cct == 3200)
        #expect(state.scenes?["warm"]?.fixtures.first?.intensity == 75.5)
    }

    @Test func roundTripPreservesUnmodeledFixtureFields() throws {
        let state = try decode(provisionedJSON)
        let reencoded = try JSONEncoder().encode(state)
        let again = try decode(reencoded)
        // The unknown field and the native version field must survive a load/save.
        #expect(again.fixtures[0].extra["vendor_blob"] == .string("keep-me"))
        #expect(again.fixtures[0].extra["fast_provision_supported"] == .int(0))
        #expect(again.fixtures[0].extra["control_hw_version"] == .string(""))
    }

    @Test func decodesControlOnlyFixtureWithoutDeviceKey() throws {
        let json = Data("""
        {
          "schema_version": 1, "synced_at": "t",
          "source": {"type": "mesh_join_import", "control_only": true},
          "mesh": {"uuid": "m", "net_key": "0123456789abcdef0123456789abcdef",
                   "app_key": "fedcba9876543210fedcba9876543210",
                   "fixtures_ordered_list": "[]", "scenes_ordered_list": "[]",
                   "update_time": "t", "state": 0},
          "fixtures": [{"uuid": "f", "mac_address": "", "code": "", "name": "n",
                        "node_address": 5, "composition_data": "",
                        "update_time": "t", "state": 0}],
          "runtime": {"iv_index": 0, "source_address": 3, "telink_source_address": 1,
                      "sequence_next": 1, "updated_at": "t"}
        }
        """.utf8)
        let state = try decode(json)
        #expect(state.fixtures[0].deviceKey == nil)
        #expect(state.fixtures[0].deviceUUID == nil)
        #expect(state.scenes == nil)
        #expect(state.source.controlOnly == true)
    }
}
