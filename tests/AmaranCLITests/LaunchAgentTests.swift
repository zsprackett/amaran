import Foundation
import Testing
@testable import AmaranCLI

struct LaunchAgentTests {
    @Test func plistContainsExpectedKeys() throws {
        let data = try LaunchAgent.plistData(
            label: "dev.local.bluetooth-probe",
            executable: "/repo/BluetoothProbe.app/Contents/MacOS/BluetoothProbe",
            metadataPath: "/Users/test/Library/Application Support/amaran-cli/daemon.json",
            logDir: "/Users/test/Library/Logs/amaran")

        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(plist as? [String: Any])

        #expect(dict["Label"] as? String == "dev.local.bluetooth-probe")
        #expect(dict["RunAtLoad"] as? Bool == true)
        #expect(dict["KeepAlive"] as? Bool == true)
        #expect(dict["ProcessType"] as? String == "Background")
        #expect(dict["StandardOutPath"] as? String == "/Users/test/Library/Logs/amaran/daemon.out.log")
        #expect(dict["StandardErrorPath"] as? String == "/Users/test/Library/Logs/amaran/daemon.err.log")

        let args = try #require(dict["ProgramArguments"] as? [String])
        #expect(args == [
            "/repo/BluetoothProbe.app/Contents/MacOS/BluetoothProbe",
            "--daemon",
            "--daemon-port-file",
            "/Users/test/Library/Application Support/amaran-cli/daemon.json",
        ])
    }

    @Test func plistIsValidXML() throws {
        let data = try LaunchAgent.plistData(
            label: "x", executable: "/e", metadataPath: "/m", logDir: "/l")
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("<?xml"))
        #expect(text.contains("<plist"))
    }
}
