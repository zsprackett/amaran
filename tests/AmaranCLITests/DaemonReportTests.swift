import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct DaemonReportTests {
    private func response(_ json: String) throws -> DaemonResponse {
        try DaemonProtocol.decodeResponse(json.data(using: .utf8)!)
    }

    @Test func humanStatusFormatsRunningDaemon() throws {
        let r = try response(
            "{\"ok\":true,\"data\":{\"daemon\":{\"pid\":86320},\"central_state\":\"poweredOn\",\"connected\":false}}")
        #expect(DaemonReport.humanStatus(r) == "daemon running: pid 86320, bluetooth poweredOn, connected no")
    }

    @Test func humanStatusFormatsConnected() throws {
        let r = try response(
            "{\"ok\":true,\"data\":{\"daemon\":{\"pid\":1},\"central_state\":\"poweredOn\",\"connected\":true}}")
        #expect(DaemonReport.humanStatus(r) == "daemon running: pid 1, bluetooth poweredOn, connected yes")
    }

    @Test func humanStatusReportsError() throws {
        let r = try response("{\"ok\":false,\"error\":\"Bluetooth is poweredOff\"}")
        #expect(DaemonReport.humanStatus(r) == "daemon error: Bluetooth is poweredOff")
    }
}
