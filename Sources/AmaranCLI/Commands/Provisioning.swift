import ArgumentParser
import Foundation
import AmaranCore

/// Shared provisioning/configuration helpers, ported from the zsh onboard flow.
enum Provisioning {
    static func ensureStatePath(_ statePath: String, add: Bool, context: String) throws {
        let exists = FileManager.default.fileExists(atPath: (statePath as NSString).expandingTildeInPath)
        if add, !exists {
            throw CLIError("existing state is required at \(statePath) before adding a fixture; run pair once without --add to create studio state")
        }
        if !add, exists {
            throw CLIError("state file already exists at \(statePath); pass --add to append a fixture or set --state-path before \(context)")
        }
    }

    /// Provisions one fixture; the app writes state to the target path.
    static func provisionTest(_ opts: ResolvedOptions, add: Bool, attention: Int) throws -> JSONValue {
        var args = ["--timeout", String(format: "%g", opts.timeout), "--state-path", opts.statePath]
        if add { args.append("--add-to-existing-state") }
        args += ["--provision-test", String(attention)]
        let response = try AppLauncher.runOneShot(appPath: opts.env.appPath, arguments: args)
        guard response.ok, let data = response.data else {
            throw CLIError(response.error ?? "provision test failed")
        }
        return data
    }

    static func provisionSummary(_ data: JSONValue) -> String {
        let p = data["native_provisioning"]
        var parts = ["provisioning complete: \(p?["state_mode"]?.stringValue ?? "create") address \(p?["node_address"]?.intValue.map(String.init) ?? "?")"]
        if let path = p?["state_path"]?.stringValue { parts.append("state \(path)") }
        if let suffix = p?["device_uuid_suffix"]?.stringValue { parts.append("uuid ...\(suffix)") }
        return parts.joined(separator: ", ")
    }

    // MARK: configure orchestration

    static func appkeyListHasIndex(_ data: JSONValue, _ target: Int) -> Bool {
        for notification in data["proxy_notifications"]?.arrayValue ?? [] {
            if let config = notification["access"]?["config"]?.objectValue,
                config["message"]?.stringValue == "appkey_list" {
                return (config["app_key_indexes"]?.arrayValue ?? []).contains { $0.intValue == target }
            }
        }
        return false
    }

    static func configureOnce(_ opts: ResolvedOptions) throws -> JSONValue {
        let composition = try DiagnosticSupport.data(opts, flags: ["--config-composition-get-test"], kind: "config composition get")
        let appkeyList = try DiagnosticSupport.data(opts, flags: ["--config-appkey-get-test"], kind: "config appkey get")
        let appkeyAdd: JSONValue = appkeyListHasIndex(appkeyList, 0)
            ? .object(["skipped": .bool(true), "reason": .string("app_key_index_present"), "app_key_index": .int(0)])
            : try DiagnosticSupport.data(opts, flags: ["--config-appkey-add-test"], kind: "config appkey add")
        let modelBind = try DiagnosticSupport.data(opts, flags: ["--config-model-app-bind-test"], kind: "config model app bind")
        return .object([
            "composition": composition, "appkey_list": appkeyList,
            "appkey_add": appkeyAdd, "model_bind": modelBind,
        ])
    }

    static func configureWithRetry(_ opts: ResolvedOptions) throws -> JSONValue {
        let env = ProcessInfo.processInfo.environment
        let attempts = max(1, Int(env["AMARAN_CONFIGURE_ATTEMPTS"] ?? "") ?? 3)
        let delay = Double(env["AMARAN_CONFIGURE_RETRY_DELAY"] ?? "") ?? 5
        var attempt = 1
        while true {
            do {
                return try configureOnce(opts)
            } catch {
                if attempt >= attempts { throw error }
                FileHandle.standardError.write(Data("amaran: configuration attempt \(attempt) failed; retrying in \(String(format: "%g", delay))s...\n".utf8))
                Thread.sleep(forTimeInterval: delay)
                attempt += 1
            }
        }
    }
}

public struct ProvisionTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "provision-test", abstract: "Run PB-GATT provisioning and write state.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .customLong("add"), help: "Append to existing state.") var add = false
    @Option(name: .customLong("attention"), help: "Provisioning Invite attention (0-255).") var attention: Int?
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try Provisioning.ensureStatePath(opts.statePath, add: add, context: "provisioning")
        let duration = attention ?? Int(ProcessInfo.processInfo.environment["AMARAN_ATTENTION_DURATION"] ?? "0") ?? 0
        let data = try Provisioning.provisionTest(opts, add: add, attention: duration)
        if opts.json { print(JSONOutput.pretty(data)) } else { print(Provisioning.provisionSummary(data)) }
    }
}

public struct ConfigureTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "configure-test", abstract: "Fetch composition, ensure AppKey, bind model.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let data = try Provisioning.configureWithRetry(opts)
        if opts.json { print(JSONOutput.pretty(data)) } else { print("configuration complete") }
    }
}

public struct PairCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pair", abstract: "Provision an unprovisioned fixture, configure it, write state.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .customLong("add"), help: "Append to existing state.") var add = false
    @Flag(name: .customLong("dry-run"), help: "Preflight + scan only.") var dryRun = false
    @Flag(name: .customLong("verify"), help: "Read status after configuring.") var verify = false
    @Option(name: .customLong("attention"), help: "Provisioning Invite attention (0-255).") var attention: Int?
    public init() {}

    public func run() throws {
        let opts = options.resolve()
        if dryRun {
            let scan = try DiagnosticSupport.data(opts, flags: ["--provisioning-scan"], includeState: false, includeNode: false, kind: "provision scan")
            if opts.json {
                print(JSONOutput.pretty(scan))
            } else {
                let found = scan["unprovisioned"]?.arrayValue ?? scan["discoveries"]?.arrayValue ?? []
                print("preflight: bluetooth \(scan["central_state"]?.stringValue ?? "unknown"), unprovisioned candidates \(found.count)")
            }
            return
        }

        try Provisioning.ensureStatePath(opts.statePath, add: add, context: "pairing")
        let duration = attention ?? Int(ProcessInfo.processInfo.environment["AMARAN_ATTENTION_DURATION"] ?? "0") ?? 0
        let provision = try Provisioning.provisionTest(opts, add: add, attention: duration)

        let provisionedNode = provision["native_provisioning"]?["node_address"]?.intValue.map(String.init)
        let configureOpts = opts.with(node: provisionedNode ?? opts.node)
        Thread.sleep(forTimeInterval: 3)
        let configure = try Provisioning.configureWithRetry(configureOpts)

        var aggregate: [String: JSONValue] = ["provision": provision, "configure": configure]
        if verify {
            let response = try ControlRunner(env: configureOpts.env, statePath: configureOpts.statePath,
                                             node: configureOpts.node, timeout: configureOpts.timeout).status()
            guard response.ok, let data = response.data else {
                throw CLIError("pairing configured state, but status verification failed; retry ./bin/amaran status")
            }
            aggregate["verify"] = data
        }

        if opts.json {
            print(JSONOutput.pretty(JSONValue.object(aggregate)))
        } else {
            print("pairing complete")
        }
    }
}

public struct ConfigNodeResetTestCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config-node-reset-test", abstract: "Dry-run or confirmed Config Node Reset.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .customLong("dry-run"), help: "Validate and print the target without resetting.") var dryRun = false
    @Flag(name: .customLong("confirm-reset"), help: "Allow the destructive reset.") var confirmReset = false
    public init() {}

    public func run() throws {
        let opts = options.resolve()
        if dryRun, confirmReset {
            throw CLIError("--dry-run cannot be used with --confirm-reset")
        }
        try ControlSupport.requireState(opts.statePath, kind: "control")

        if dryRun {
            let state = try StateLoading.load(opts.statePath)
            guard let fixture = Capabilities.selectedFixture(state.fixtures, selector: opts.node) else {
                throw CLIError("config-node-reset-test --dry-run requires a single fixture; pass --node")
            }
            if opts.json {
                print(JSONOutput.pretty(JSONValue.object([
                    "dry_run": .bool(true),
                    "address": .int(fixture.nodeAddress),
                    "name": .string(Capabilities.label(fixture)),
                ])))
            } else {
                print("would reset \(Capabilities.label(fixture)) at address \(fixture.nodeAddress) (pass --confirm-reset)")
            }
            return
        }

        guard confirmReset else {
            throw CLIError("config-node-reset-test is destructive; pass --confirm-reset to reset the fixture")
        }
        let data = try DiagnosticSupport.data(opts, flags: ["--config-node-reset-test", "--confirm-reset"], kind: "config node reset")
        if opts.json { print(JSONOutput.pretty(data)) } else { print(DiagnosticSupport.sendSummary(data, "config node reset")) }
    }
}

public struct JoinCaptureCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "join-capture", abstract: "Advertise as an unprovisioned device to capture join keys.")
    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("output-state"), help: "Where to write captured state (0600).") var outputState: String
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        let args = ["--timeout", String(format: "%g", opts.timeout),
                    "--join-capture", "--capture-state", (outputState as NSString).expandingTildeInPath]
        let response = try AppLauncher.runOneShot(appPath: opts.env.appPath, arguments: args)
        guard response.ok, let data = response.data else {
            throw CLIError(response.error ?? "join capture failed")
        }
        if opts.json { print(JSONOutput.pretty(data)) } else { print("join capture complete") }
    }
}
