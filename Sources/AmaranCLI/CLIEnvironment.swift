import Foundation

/// Resolved CLI configuration and filesystem paths. Mirrors the defaults and
/// environment variables the zsh dispatcher used, so behavior matches after the
/// cutover. `AMARAN_ROOT` is exported by the `bin/amaran` shim to locate the
/// AmaranHelper.app bundle.
public struct CLIEnvironment {
    public let statePath: String
    public let daemonMetadataPath: String
    public let appPath: String
    public let daemonExecutablePath: String
    public let launchAgentPlistPath: String
    public let logDir: String
    public let daemonLabel: String
    public let logSubsystem: String
    public let daemonDisabled: Bool
    public let timeout: Double
    public let defaultNodeID: String?

    public init(environment: [String: String], home: String, executablePath: String? = nil) {
        let label = "dev.local.amaran-helper"
        let appSupport = home + "/Library/Application Support/amaran-cli"

        statePath = environment["AMARAN_CLI_STATE_PATH"] ?? appSupport + "/state.json"
        daemonMetadataPath = environment["AMARAN_DAEMON_PORT_FILE"] ?? appSupport + "/daemon.json"

        let resolvedApp: String
        if let root = environment["AMARAN_ROOT"], !root.isEmpty {
            resolvedApp = root + "/AmaranHelper.app"
        } else if let executablePath {
            // Fallback: .../<root>/.build/<config>/amaran -> <root>/AmaranHelper.app
            let buildDir = (executablePath as NSString).deletingLastPathComponent
            let configParent = (buildDir as NSString).deletingLastPathComponent
            let root = (configParent as NSString).deletingLastPathComponent
            resolvedApp = root + "/AmaranHelper.app"
        } else {
            resolvedApp = appSupport + "/AmaranHelper.app"
        }
        appPath = resolvedApp
        daemonExecutablePath = resolvedApp + "/Contents/MacOS/AmaranHelper"

        launchAgentPlistPath = home + "/Library/LaunchAgents/" + label + ".plist"
        logDir = home + "/Library/Logs/amaran"
        daemonLabel = label
        logSubsystem = label
        daemonDisabled = environment["AMARAN_DAEMON_DISABLE"] == "1"
        timeout = max(1, Double(environment["AMARAN_TIMEOUT"] ?? "") ?? 20)
        let node = environment["AMARAN_NODE_ID"] ?? ""
        defaultNodeID = node.isEmpty ? nil : node
    }

    /// Resolves from the live process environment.
    public static func current() -> CLIEnvironment {
        CLIEnvironment(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            executablePath: CommandLine.arguments.first)
    }

    public func daemonClient() -> DaemonClient {
        DaemonClient(metadataPath: daemonMetadataPath, appPath: appPath)
    }

    /// Repo root (parent of AmaranHelper.app) and the helper-script directory.
    public var rootDir: String { (appPath as NSString).deletingLastPathComponent }
    public func scriptPath(_ name: String) -> String { rootDir + "/scripts/" + name }
}
