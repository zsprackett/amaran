import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct DiscoverScanTests {
    private func state(fixtures: [Fixture], source: Int = 4, telink: Int = 1) -> State {
        State(syncedAt: "t", source: Source(type: "mesh_join_import"),
              mesh: Mesh(uuid: "m", netKey: String(repeating: "ab", count: 16),
                         appKey: String(repeating: "cd", count: 16), updateTime: "t"),
              fixtures: fixtures,
              runtime: Runtime(ivIndex: 0, sourceAddress: source, telinkSourceAddress: telink,
                               sequenceNext: 1, updatedAt: "t"))
    }
    private func fixture(_ address: Int) -> Fixture {
        Fixture(uuid: "f\(address)", name: "n\(address)", nodeAddress: address, updateTime: "t")
    }

    @Test func parseRangeExpandsAndDedups() throws {
        #expect(try DiscoverScan.parseRange("2-5") == [2, 3, 4, 5])
        #expect(try DiscoverScan.parseRange("2-4,4,8") == [2, 3, 4, 8])
        #expect(try DiscoverScan.parseRange("0x2-0x4") == [2, 3, 4])
    }

    @Test func parseRangeRejectsBad() {
        #expect(throws: CLIError.self) { _ = try DiscoverScan.parseRange("") }
        #expect(throws: CLIError.self) { _ = try DiscoverScan.parseRange("5-2") }
        #expect(throws: CLIError.self) { _ = try DiscoverScan.parseRange("0-3") }   // 0 non-unicast
    }

    @Test func relocatesRuntimeSourceInScanRange() throws {
        var meshState = state(fixtures: [fixture(2)], source: 3, telink: 1)
        // scanning 2-5 includes source 3 -> must relocate away from {2,3,4,5} and telink 1
        let reloc = try DiscoverScan.relocateRuntimeSourceIfNeeded(&meshState, scan: [2, 3, 4, 5], now: "now")
        #expect(reloc?.from == 3)
        #expect(reloc?.toAddress == 6)
        #expect(meshState.runtime.sourceAddress == 6)
        #expect(meshState.runtime.lastReservedBy == "discover-source-relocation")
    }

    @Test func noRelocationWhenSourceOutsideRange() throws {
        var meshState = state(fixtures: [fixture(2)], source: 50, telink: 1)
        #expect(try DiscoverScan.relocateRuntimeSourceIfNeeded(&meshState, scan: [2, 3], now: "now") == nil)
    }

    @Test func mapsStatusesBySource() throws {
        let batch = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"proxy_notifications":[
          {"network":{"source":3},"access":{"telink":{"cct":
            {"cct_kelvin":5600,"intensity":400,"gm_decoded":4,"sleep_mode":1}}}},
          {"network":{"source":99},"access":{"telink":{"cct":{"cct_kelvin":3000}}}}
        ]}
        """.utf8))
        let map = DiscoverScan.statusesBySource(batch, addresses: [3, 4])
        #expect(map[3] != nil)
        #expect(map[99] == nil)   // not in addresses
        let discovered = DiscoverScan.normalizeStatus(address: 3, fixture: fixture(3), cct: map[3]!)
        #expect(discovered.cct == 5600)
        #expect(discovered.intensity == 40)
        #expect(discovered.greenMagenta == 4)
        #expect(discovered.sleepMode == 1)
    }

    @Test func ensureFixtureAddsControlOnly() {
        var meshState = state(fixtures: [fixture(2)])
        #expect(DiscoverScan.ensureFixture(&meshState, address: 9, now: "t") == true)
        #expect(meshState.fixtures.contains { $0.nodeAddress == 9 && $0.controlOnly == true })
        #expect(DiscoverScan.ensureFixture(&meshState, address: 2, now: "t") == false)  // already present
    }
}
