import Foundation

/// Entry point for the AmaranHelper executable. The logic lives in the
/// `AmaranHelperKit` library so it can be unit tested; the executable target
/// is a thin shim that calls `AmaranHelperMain.main()`.
public enum AmaranHelperMain {
    public static func main() {
        if CommandLine.arguments.contains("--daemon") {
            runDaemon()
            return
        }

        let options = ProbeOptions(arguments: CommandLine.arguments)
        if let configurationError = options.configurationError {
            writeConfigurationError(configurationError, options: options)
            return
        }
        if let run = options.nativeJoinCaptureRun {
            runJoinCapture(options: options, run: run)
        } else {
            let probe = MeshGattProbe(options: options)
            withExtendedLifetime(probe) {
                CFRunLoopRun()
            }
        }
    }

    private static func runDaemon() {
        do {
            let daemon = try MeshRuntimeDaemon(options: RuntimeDaemonOptions(arguments: CommandLine.arguments))
            daemon.start()
            withExtendedLifetime(daemon) {
                CFRunLoopRun()
            }
        } catch {
            Log.daemon.fault("failed to start daemon: \(String(describing: error), privacy: .public)")
            fputs("failed to start daemon: \(error)\n", stderr)
        }
    }

    private static func writeConfigurationError(_ configurationError: String, options: ProbeOptions) {
        let payload: [String: Any] = [
            "ok": false,
            "error": configurationError,
            "data": [
                "central_state": "notStarted",
                "discoveries": [],
                "scanned_services": options.scanServices.map(cbuuidString).sorted()
            ]
        ]
        do {
            try writeJSONPayload(payload, to: options.outputPath)
        } catch {
            fputs("failed to write probe output: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func runJoinCapture(options: ProbeOptions, run: NativeJoinCaptureRun) {
        do {
            let capture = try MeshJoinCapturePeripheral(options: options, run: run)
            withExtendedLifetime(capture) {
                CFRunLoopRun()
            }
        } catch {
            let payload: [String: Any] = [
                "ok": false,
                "error": String(describing: error),
                "data": [
                    "central_state": "notStarted",
                    "join_capture": [
                        "started": false,
                        "completed": false,
                        "state_written": false
                    ]
                ]
            ]
            do {
                try writeJSONPayload(payload, to: options.outputPath)
            } catch {
                fputs("failed to write join capture output: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
