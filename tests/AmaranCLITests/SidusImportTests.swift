import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct SidusImportTests {
    private let meshJSON = """
    {"meshName":"Studio","meshUUID":"uuid-1",
     "netKeys":[{"key":"00112233445566778899aabbccddeeff"}],
     "appKeys":[{"key":"ffeeddccbbaa99887766554433221100"}],
     "nodes":[
       {"name":"ItonMeshProvisioner","unicastAddress":"0001"},
       {"name":"400D-AABBCC","unicastAddress":"0003","MAC":"AABBCCDDEEFF",
        "deviceKey":"00112233445566778899aabbccddeeff",
        "UUID":"ffeeddccbbaa99887766554433221100","elements":[{},{}]},
       {"name":"light2","unicastAddress":"0005","MAC":"112233445566"}
     ]}
    """

    private func file(_ json: String) -> SidusMeshFile {
        SidusMeshFile(domain: "AppDomain-com.aputure.cn.SidusLink",
                      relativePath: "Documents/mesh/m.json", data: json.data(using: .utf8)!)
    }

    @Test func parsesCandidateFromMesh() {
        let candidate = SidusImport.candidate(from: file(meshJSON), now: "t")!
        #expect(candidate.meshName == "Studio")
        #expect(candidate.meshUUID == "uuid-1")
        #expect(candidate.netKey == "00112233445566778899aabbccddeeff")
        #expect(candidate.fixtures.count == 2)                  // provisioner (addr 1) skipped
        #expect(candidate.fixtures[0].nodeAddress == 3)
        #expect(candidate.fixtures[0].code == "400D")
        #expect(candidate.fixtures[0].macAddress == "AA:BB:CC:DD:EE:FF")
        #expect(candidate.fixtures[0].deviceKey == "00112233445566778899aabbccddeeff")
        #expect(candidate.fixtures[0].controlOnly == false)
        #expect(candidate.fixtures[0].elementCount == 2)
        #expect(candidate.fixtures[1].nodeAddress == 5)
        #expect(candidate.fixtures[1].code == "")
        #expect(candidate.fixtures[1].controlOnly == true)
        #expect(candidate.score.fixtureCount == 2)
        #expect(candidate.score.deviceKeyCount == 1)
    }

    @Test func candidateRejectsMissingKeys() {
        let bad = file("{\"netKeys\":[],\"appKeys\":[],\"nodes\":[]}")
        #expect(SidusImport.candidate(from: bad, now: "t") == nil)
    }

    @Test func selectByScoreAndSelector() throws {
        let candidate = SidusImport.candidate(from: file(meshJSON), now: "t")!
        #expect(try SidusImport.select([candidate], selector: "").meshName == "Studio")
        #expect(try SidusImport.select([candidate], selector: "studio").meshName == "Studio")
        #expect(throws: CLIError.self) { _ = try SidusImport.select([candidate], selector: "nope") }
        #expect(throws: CLIError.self) { _ = try SidusImport.select([], selector: "") }
    }

    @Test func choosesSourceAddressesAroundOccupied() {
        let candidate = SidusImport.candidate(from: file(meshJSON), now: "t")!
        // addr 3 has 2 elements (3,4), addr 5 -> occupied {3,4,5}
        let (source, telink) = SidusImport.chooseSourceAddresses(candidate.fixtures)
        #expect(source == 6)
        #expect(telink == 1)
    }

    @Test func buildsStateWithSidusSource() {
        let candidate = SidusImport.candidate(from: file(meshJSON), now: "t")!
        let state = SidusImport.buildState(candidate, now: "t")
        #expect(state.source.type == "sidus_ios_backup_import")
        #expect(state.source.extra["mesh_name"] == .string("Studio"))
        #expect(state.runtime.sourceAddress == 6)
        #expect(state.runtime.lastReservedBy == "sidus-import")
        #expect(state.scenes != nil && state.scenes?.isEmpty == true)  // emits "scenes": {}
    }
}
