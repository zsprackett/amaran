import ArgumentParser
import Foundation

/// Options shared by most commands, mirroring the zsh dispatcher's global flags.
/// Included via `@OptionGroup` on each leaf command.
public struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("state-path"), help: "Local CLI state file path.")
    public var statePath: String?

    @Option(name: .customLong("node"), help: "Target fixture node address or name.")
    public var node: String?

    @Option(name: .customLong("timeout"), help: "BLE helper timeout in seconds.")
    public var timeout: Double?

    @Flag(name: .customLong("json"), help: "Emit JSON output where supported.")
    public var json = false

    public init() {}

    /// Resolves the effective environment, overlaying flags onto env defaults.
    public func resolve() -> ResolvedOptions {
        let env = CLIEnvironment.current()
        return ResolvedOptions(
            env: env,
            statePath: statePath ?? env.statePath,
            node: node ?? env.defaultNodeID,
            timeout: timeout ?? env.timeout,
            json: json)
    }
}

/// Effective configuration for a single command invocation.
public struct ResolvedOptions {
    public let env: CLIEnvironment
    public let statePath: String
    public let node: String?
    public let timeout: Double
    public let json: Bool

    public func with(node: String?) -> ResolvedOptions {
        ResolvedOptions(env: env, statePath: statePath, node: node, timeout: timeout, json: json)
    }
}
