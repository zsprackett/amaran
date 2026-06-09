import Foundation
import Testing
@testable import AmaranCore

struct DaemonProtocolTests {
    @Test func encodesPingAsCompactLine() throws {
        let data = try DaemonProtocol.encodeRequest(.ping)
        #expect(String(data: data, encoding: .utf8) == "{\"action\":\"ping\"}\n")
    }

    @Test func encodesShutdownAsCompactLine() throws {
        let data = try DaemonProtocol.encodeRequest(.shutdown)
        #expect(String(data: data, encoding: .utf8) == "{\"action\":\"shutdown\"}\n")
    }

    @Test func controlRequestRoundTrips() throws {
        let request = DaemonRequest.control(
            spec: "cct:3200:50:10:1", statePath: "/tmp/state.json", timeout: 20, nodeID: "0x3")
        let data = try DaemonProtocol.encodeRequest(request)
        let decoded = try DaemonProtocol.decodeRequest(data)
        #expect(decoded == request)
        #expect(decoded.action == "control")
        #expect(decoded.spec == "cct:3200:50:10:1")
        #expect(decoded.statePath == "/tmp/state.json")
        #expect(decoded.nodeID == "0x3")
    }

    @Test func controlSequenceRoundTrips() throws {
        let request = DaemonRequest.controlSequence(
            specs: ["on", "intensity:75"], statePath: "/tmp/s.json", timeout: 20, nodeID: nil)
        let decoded = try DaemonProtocol.decodeRequest(try DaemonProtocol.encodeRequest(request))
        #expect(decoded == request)
        #expect(decoded.specs == ["on", "intensity:75"])
    }

    @Test func omitsNilNodeId() throws {
        let request = DaemonRequest.status(statePath: "/tmp/s.json", timeout: 10, nodeID: nil)
        let text = String(data: try DaemonProtocol.encodeRequest(request), encoding: .utf8)!
        #expect(!text.contains("node_id"))
        #expect(text.contains("\"state_path\":\"/tmp/s.json\""))
    }

    @Test func decodesSuccessResponse() throws {
        let line = Data("{\"ok\":true,\"data\":{\"central_state\":\"poweredOn\"}}\n".utf8)
        let response = try DaemonProtocol.decodeResponse(line)
        #expect(response.succeeded == true)
        #expect(response.error == nil)
        if case .object(let data)? = response.data, case .string(let state)? = data["central_state"] {
            #expect(state == "poweredOn")
        } else {
            Issue.record("expected central_state in data")
        }
    }

    @Test func decodesErrorResponse() throws {
        let line = Data("{\"ok\":false,\"error\":\"Bluetooth is poweredOff\"}".utf8)
        let response = try DaemonProtocol.decodeResponse(line)
        #expect(response.succeeded == false)
        #expect(response.error == "Bluetooth is poweredOff")
    }
}
