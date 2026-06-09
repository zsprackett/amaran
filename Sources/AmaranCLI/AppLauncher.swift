import Foundation
import AmaranCore

/// Runs the AmaranHelper app once (`/usr/bin/open -n -W ... --args`), injecting
/// `--output <tmp>` and returning the decoded `{ok,data,error}` it writes. Used
/// by the one-shot diagnostics and as the ControlRunner fallback.
public enum AppLauncher {
    public static func runOneShot(appPath: String, arguments: [String]) throws -> DaemonResponse {
        let outputPath = NSTemporaryDirectory() + "amaran-oneshot-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-W", appPath, "--args", "--output", outputPath] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard let data = FileManager.default.contents(atPath: outputPath), !data.isEmpty else {
            throw CLIError("native helper did not write a result")
        }
        return try DaemonProtocol.decodeResponse(data)
    }
}
