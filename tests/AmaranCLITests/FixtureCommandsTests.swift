import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct FixtureCommandsTests {
    private func fixture(_ node: Int, name: String = "", code: String = "",
                         mac: String = "", friendly: String? = nil) -> Fixture {
        Fixture(uuid: "f\(node)", macAddress: mac, code: code, name: name, nodeAddress: node,
                updateTime: "t", friendlyName: friendly)
    }

    private func state(_ fixtures: [Fixture]) -> State {
        State(syncedAt: "t",
              source: Source(type: "native_provisioning"),
              mesh: Mesh(uuid: "m", netKey: String(repeating: "ab", count: 16),
                         appKey: String(repeating: "cd", count: 16), updateTime: "t"),
              fixtures: fixtures,
              runtime: Runtime(ivIndex: 0, sourceAddress: 3, telinkSourceAddress: 1,
                               sequenceNext: 1, updatedAt: "t"))
    }

    // MARK: list

    @Test func listEntriesAreRedactedSummaries() {
        let entries = ListReport.entries(state([
            fixture(6, name: "400M5-DDEEFF", code: "400M5", mac: "AABBCCDDEEFF", friendly: "key"),
        ]))
        let e = entries[0]
        #expect(e.name == "key")            // friendly wins
        #expect(e.friendlyName == "key")
        #expect(e.sourceName == "400M5-DDEEFF")
        #expect(e.address == 6)
        #expect(e.mac == "AA:BB:CC:DD:EE:FF")
        #expect(e.capabilities.cctMin == 2700)   // 400M5 family
        #expect(e.capabilities.gmSupported == false)
    }

    @Test func listMacUnknownWhenMissing() {
        let entries = ListReport.entries(state([fixture(6, name: "n")]))
        #expect(entries[0].mac == "unknown")
    }

    // MARK: select

    @Test func selectsByAddressHexAndName() throws {
        let fixtures = [fixture(6, name: "alpha"), fixture(7, name: "beta", friendly: "key")]
        #expect(try FixtureOps.selectIndex(fixtures, selector: "7") == 1)
        #expect(try FixtureOps.selectIndex(fixtures, selector: "0x7") == 1)
        #expect(try FixtureOps.selectIndex(fixtures, selector: "alpha") == 0)
        #expect(try FixtureOps.selectIndex(fixtures, selector: "key") == 1)
    }

    @Test func selectMissingThrows() {
        #expect(throws: CLIError.self) {
            try FixtureOps.selectIndex([fixture(6, name: "a")], selector: "nope")
        }
    }

    // MARK: rename / clear

    @Test func renameSetsFriendlyNameAndPreservesOtherFields() throws {
        var s = state([fixture(6, name: "alpha", code: "X", mac: "AABBCCDDEEFF")])
        let result = try FixtureOps.rename(state: &s, selector: "6", name: "key")
        #expect(result.renamed == true)
        #expect(result.previousFriendlyName == nil)
        #expect(s.fixtures[0].friendlyName == "key")
        #expect(s.fixtures[0].extra["updated_at"] != nil)   // timestamp stamped
        #expect(s.fixtures[0].code == "X")                  // untouched
    }

    @Test func renameRejectsInvalidNames() {
        var s = state([fixture(6, name: "alpha")])
        #expect(throws: CLIError.self) { try FixtureOps.rename(state: &s, selector: "6", name: "") }
        #expect(throws: CLIError.self) { try FixtureOps.rename(state: &s, selector: "6", name: "has space") }
        #expect(throws: CLIError.self) { try FixtureOps.rename(state: &s, selector: "6", name: "6") }       // numeric
        #expect(throws: CLIError.self) { try FixtureOps.rename(state: &s, selector: "6", name: "0x10") }    // hex numeric
    }

    @Test func renameRejectsConflictWithOtherSelector() {
        var s = state([fixture(6, name: "alpha"), fixture(7, name: "beta")])
        #expect(throws: CLIError.self) { try FixtureOps.rename(state: &s, selector: "6", name: "beta") }
    }

    @Test func clearNameRemovesFriendlyName() throws {
        var s = state([fixture(6, name: "alpha", friendly: "key")])
        let result = try FixtureOps.clearName(state: &s, selector: "6")
        #expect(result.cleared == true)
        #expect(result.previousFriendlyName == "key")
        #expect(s.fixtures[0].friendlyName == nil)
    }

    @Test func clearNameWhenNoneIsNoop() throws {
        var s = state([fixture(6, name: "alpha")])
        let result = try FixtureOps.clearName(state: &s, selector: "6")
        #expect(result.cleared == false)
        #expect(result.previousFriendlyName == nil)
    }
}
