import Foundation

/// launchd LaunchAgent management for the runtime daemon, ported from the zsh
/// `daemon_install`/`daemon_uninstall` flow. Same label and plist shape so an
/// existing install is unaffected.
public enum LaunchAgent {
    /// Generates the LaunchAgent property list (XML) for the daemon.
    public static func plistData(
        label: String,
        executable: String,
        metadataPath: String,
        logDir: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--daemon", "--daemon-port-file", metadataPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logDir + "/daemon.out.log",
            "StandardErrorPath": logDir + "/daemon.err.log",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public enum InstallError: Error, CustomStringConvertible {
        case executableMissing(String)
        case bootstrapFailed

        public var description: String {
            switch self {
            case .executableMissing(let path):
                return "\(path) is missing; run scripts/build-bluetooth-probe first"
            case .bootstrapFailed:
                return "failed to bootstrap launchd agent"
            }
        }
    }

    /// Registers the LaunchAgent, priming the Bluetooth permission first so the
    /// TCC grant is attributed to the signed bundle, then letting launchd own
    /// the resident daemon.
    public static func install(env: CLIEnvironment) throws {
        guard FileManager.default.isExecutableFile(atPath: env.daemonExecutablePath) else {
            throw InstallError.executableMissing(env.daemonExecutablePath)
        }

        let plistDir = (env.launchAgentPlistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: env.logDir, withIntermediateDirectories: true)
        let metadataDir = (env.daemonMetadataPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: metadataDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Prime permission: start a daemon (may prompt), then shut it down so
        // launchd owns the single resident instance.
        let client = env.daemonClient()
        if client.ensureRunning() {
            _ = try? client.exchange(.shutdown, timeout: 2.0)
        }

        let data = try plistData(
            label: env.daemonLabel,
            executable: env.daemonExecutablePath,
            metadataPath: env.daemonMetadataPath,
            logDir: env.logDir)
        try data.write(to: URL(fileURLWithPath: env.launchAgentPlistPath))

        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, env.launchAgentPlistPath])
        if runLaunchctl(["bootstrap", domain, env.launchAgentPlistPath]) != 0 {
            throw InstallError.bootstrapFailed
        }
        _ = runLaunchctl(["enable", "\(domain)/\(env.daemonLabel)"])
    }

    /// Removes the LaunchAgent (bootout first so KeepAlive will not relaunch).
    public static func uninstall(env: CLIEnvironment) {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, env.launchAgentPlistPath])
        _ = try? env.daemonClient().exchange(.shutdown, timeout: 2.0)
        try? FileManager.default.removeItem(atPath: env.launchAgentPlistPath)
    }

    public static func isInstalled(env: CLIEnvironment) -> Bool {
        FileManager.default.fileExists(atPath: env.launchAgentPlistPath)
    }

    /// Unloads the managed daemon without removing the plist. KeepAlive would
    /// relaunch a daemon that merely received `shutdown`, so bootout first.
    public static func stop(env: CLIEnvironment) {
        _ = runLaunchctl(["bootout", "gui/\(getuid())", env.launchAgentPlistPath])
        _ = try? env.daemonClient().exchange(.shutdown, timeout: 2.0)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
