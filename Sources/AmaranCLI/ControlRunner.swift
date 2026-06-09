import Foundation
import AmaranCore

/// Routes control/status requests to the daemon, falling back to a one-shot app
/// launch when the daemon is disabled or unreachable. Mirrors the zsh
/// `daemon_request ... || launch_app` pattern.
public struct ControlRunner {
    public let env: CLIEnvironment
    public let statePath: String
    public let node: String?
    public let timeout: Double

    public init(env: CLIEnvironment, statePath: String, node: String?, timeout: Double) {
        self.env = env
        self.statePath = statePath
        self.node = node
        self.timeout = timeout
    }

    public func status() throws -> DaemonResponse {
        try run(
            request: .status(statePath: statePath, timeout: timeout, nodeID: node),
            oneShotArgs: ["--status-test"])
    }

    public func control(spec: String) throws -> DaemonResponse {
        try run(
            request: .control(spec: spec, statePath: statePath, timeout: timeout, nodeID: node),
            oneShotArgs: ["--control-test", spec])
    }

    public func controlSequence(specs: [String]) throws -> DaemonResponse {
        try run(
            request: .controlSequence(specs: specs, statePath: statePath, timeout: timeout, nodeID: node),
            oneShotArgs: ["--control-sequence", specs.joined(separator: ",")])
    }

    private func run(request: DaemonRequest, oneShotArgs: [String]) throws -> DaemonResponse {
        if !env.daemonDisabled {
            let client = env.daemonClient()
            if client.ensureRunning(), let response = try? client.exchange(request, timeout: timeout + 2) {
                return response
            }
        }
        return try oneShot(oneShotArgs)
    }

    private func oneShot(_ extra: [String]) throws -> DaemonResponse {
        var args = ["--timeout", String(format: "%g", timeout), "--state-path", statePath]
        if let node { args += ["--node", node] }
        args += extra
        return try AppLauncher.runOneShot(appPath: env.appPath, arguments: args)
    }
}

/// Shared helpers for interpreting control/status responses.
public enum ControlResult {
    /// Extracts a failure message from a non-ok response, matching the zsh
    /// fallbacks.
    public static func failureDetail(_ response: DaemonResponse, kind: String) -> String {
        if let error = response.error, !error.isEmpty { return error }
        if let state = response.data?["central_state"]?.stringValue {
            return "\(kind) failed (central_state \(state))"
        }
        return "\(kind) failed"
    }
}
