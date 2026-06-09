import ArgumentParser
import Foundation
import AmaranCore

/// Shared support for one-shot diagnostic commands: launch the app with the
/// given flags and render `data` (`--json`) or a concise human summary.
enum DiagnosticSupport {
    static func data(
        _ opts: ResolvedOptions, flags: [String],
        includeState: Bool = true, includeNode: Bool = true, kind: String
    ) throws -> JSONValue {
        var args = ["--timeout", String(format: "%g", opts.timeout)]
        if includeState { args += ["--state-path", opts.statePath] }
        if includeNode, let node = opts.node { args += ["--node", node] }
        args += flags
        let response = try AppLauncher.runOneShot(appPath: opts.env.appPath, arguments: args)
        guard response.succeeded, let data = response.data else {
            throw CLIError(response.error ?? "\(kind) failed")
        }
        return data
    }

    static func emit(_ data: JSONValue, json: Bool, summary: () -> String) {
        if json { print(JSONOutput.pretty(data)) } else { print(summary()) }
    }

    /// Generic "sent" summary for vendor/config PDUs.
    static func sendSummary(_ data: JSONValue, _ kind: String) -> String {
        var parts: [String] = []
        if let address = data["native_send"]?["address"]?.intValue {
            parts.append("address \(address)")
        }
        if let sequence = data["native_send"]?["sequence"]?.intValue {
            parts.append("sequence \(sequence)")
        }
        if let count = data["proxy_write"]?["notification_count"]?.intValue {
            parts.append("notifications \(count)")
        }
        return parts.isEmpty ? "\(kind) ok" : "\(kind): " + parts.joined(separator: ", ")
    }
}

public struct GattProbeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gatt-probe", abstract: "Discover Mesh Proxy/Provisioning services.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .customLong("all-services"), help: "Dump the full GATT service list.") var allServices = false
    @Flag(name: .customLong("read-values"), help: "Read readable characteristic values.") var readValues = false
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        var flags: [String] = []
        if allServices { flags.append("--discover-all-services") }
        if readValues { flags.append("--read-characteristics") }
        let data = try DiagnosticSupport.data(
            opts, flags: flags, includeState: false, includeNode: false, kind: "BLE probe")
        DiagnosticSupport.emit(data, json: opts.json) {
            let discoveries = data["discoveries"]?.arrayValue ?? []
            var lines = ["bluetooth \(data["central_state"]?.stringValue ?? "unknown"), "
                + "mesh devices \(discoveries.count)"]
            for item in discoveries {
                let roles = (item["mesh_roles"]?.arrayValue?.compactMap { $0.stringValue }
                    ?? ["unknown"]).joined(separator: ",")
                let name = item["name"]?.stringValue ?? "(unnamed)"
                let rssi = item["rssi"]?.intValue.map(String.init) ?? "?"
                lines.append("\(name)\t\(roles)\trssi \(rssi)")
            }
            return lines.joined(separator: "\n")
        }
    }
}

public struct ProbeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "probe", abstract: "Connect to a matching Mesh Proxy advertisement.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "probe")
        let data = try DiagnosticSupport.data(opts, flags: ["--proxy-state-probe"], kind: "probe")
        DiagnosticSupport.emit(data, json: opts.json) {
            "probe: bluetooth \(data["central_state"]?.stringValue ?? "unknown")"
        }
    }
}

public struct ProvisionScanCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "provision-scan", abstract: "Scan for unprovisioned PB-GATT advertisers.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        let data = try DiagnosticSupport.data(
            opts, flags: ["--provisioning-scan"], includeState: false, includeNode: false, kind: "provision scan")
        DiagnosticSupport.emit(data, json: opts.json) {
            let found = data["unprovisioned"]?.arrayValue ?? data["discoveries"]?.arrayValue ?? []
            return "provision scan: bluetooth \(data["central_state"]?.stringValue ?? "unknown"), "
                + "candidates \(found.count)"
        }
    }
}

public struct ProvisionInviteTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "provision-invite-test", abstract: "Send only a Provisioning Invite.")
    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("attention"), help: "Attention duration (0-255).") var attention: Int?
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        let duration = attention ?? Int(ProcessInfo.processInfo.environment["AMARAN_ATTENTION_DURATION"] ?? "0") ?? 0
        let data = try DiagnosticSupport.data(
            opts, flags: ["--provisioning-invite-test", String(duration)],
            includeState: false, includeNode: false, kind: "provision invite")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "provision invite") }
    }
}

public struct ProxyTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "proxy-test", abstract: "Write a public sample Mesh Proxy PDU.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        let data = try DiagnosticSupport.data(
            opts, flags: ["--proxy-test"], includeState: false, includeNode: false, kind: "proxy test")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "proxy test") }
    }
}

public struct SigOnOffTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sig-onoff-test", abstract: "Send a standard Generic OnOff test PDU.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "on or off.") var value: String
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        guard value == "on" || value == "off" else {
            throw CLIError("sig-onoff-test requires on or off")
        }
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let data = try DiagnosticSupport.data(opts, flags: ["--sig-onoff-test", value], kind: "sig onoff")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "sig onoff \(value)") }
    }
}

public struct StatusTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status-test", abstract: "Read the Telink 0x26 status (raw).")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "status")
        let data = try DiagnosticSupport.data(opts, flags: ["--status-test"], kind: "status test")
        DiagnosticSupport.emit(data, json: opts.json) {
            (try? StatusReport.humanLine(data)) ?? "status test ok"
        }
    }
}

public struct ControlTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "control-test", abstract: "Send a Telink 0x26 control PDU (diagnostic).")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "on|off|intensity|cct|raw.") var action: String
    @Argument(help: "Value for intensity/cct/raw.") var value: String?
    @Option(name: .customLong("intensity")) var intensity: String?
    @Option(name: .customLong("gm")) var greenMagenta: String?
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let spec = try buildSpec()
        let data = try DiagnosticSupport.data(opts, flags: ["--control-test", spec], kind: "control test")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "control test \(action)") }
    }

    private func buildSpec() throws -> String {
        switch action {
        case "on", "off": return action
        case "intensity":
            guard let value else { throw CLIError("control-test intensity requires a value from 0 to 100") }
            return "intensity:\(value)"
        case "cct":
            guard let value else { throw CLIError("control-test cct requires a kelvin value") }
            guard let intensity else { throw CLIError("control-test cct requires --intensity <0-100>") }
            return "cct:\(value):\(intensity):\(greenMagenta ?? "10"):0"
        case "raw":
            guard let value else { throw CLIError("control-test raw requires a 10-byte packet hex value") }
            return "raw:\(value)"
        default:
            throw CLIError("control-test requires on, off, intensity, cct, or raw")
        }
    }
}

public struct ConfigCompositionGetTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config-composition-get-test", abstract: "Config Composition Data Get.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let data = try DiagnosticSupport.data(
            opts, flags: ["--config-composition-get-test"], kind: "config composition get")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "config composition get") }
    }
}

public struct ConfigAppKeyGetTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config-appkey-get-test", abstract: "Config AppKey List Get.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let data = try DiagnosticSupport.data(opts, flags: ["--config-appkey-get-test"], kind: "config appkey get")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "config appkey get") }
    }
}

public struct ConfigAppKeyAddTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config-appkey-add-test", abstract: "Config AppKey Add.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let data = try DiagnosticSupport.data(opts, flags: ["--config-appkey-add-test"], kind: "config appkey add")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "config appkey add") }
    }
}

public struct ConfigModelAppBindTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config-model-app-bind-test", abstract: "Config Model App Bind.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let data = try DiagnosticSupport.data(
            opts, flags: ["--config-model-app-bind-test"], kind: "config model app bind")
        DiagnosticSupport.emit(data, json: opts.json) { DiagnosticSupport.sendSummary(data, "config model app bind") }
    }
}

public struct MonitorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "monitor", abstract: "Subscribe to Mesh Proxy notifications.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "monitor")
        let data = try DiagnosticSupport.data(opts, flags: ["--monitor"], kind: "monitor")
        DiagnosticSupport.emit(data, json: opts.json) {
            let notifications = data["proxy_notifications"]?.arrayValue ?? []
            return "monitor captured \(notifications.count) notifications"
        }
    }
}
