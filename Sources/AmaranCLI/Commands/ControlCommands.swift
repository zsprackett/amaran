import ArgumentParser
import Foundation
import AmaranCore

// Shared helpers for the control/status commands.
enum ControlSupport {
    static func runner(_ opts: ResolvedOptions) -> ControlRunner {
        ControlRunner(env: opts.env, statePath: opts.statePath, node: opts.node, timeout: opts.timeout)
    }

    static func requireState(_ path: String, kind: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CLIError("\(kind) requires local state at \(path)")
        }
    }

    /// The fixture used for capability resolution (clamping, GM support), or a
    /// defaults-only fixture when no unique selection is possible.
    static func capabilityFixture(_ state: State, node: String?) -> Fixture {
        Capabilities.selectedFixture(state.fixtures, selector: node)
            ?? Fixture(uuid: "", name: "", nodeAddress: 0, updateTime: "")
    }

    /// Sends a control spec and renders output: silent on success, JSON data with
    /// `--json`, a CLIError on failure.
    static func sendControl(_ runner: ControlRunner, spec: String, json: Bool) throws {
        let response = try runner.control(spec: spec)
        guard response.ok else {
            throw CLIError(ControlResult.failureDetail(response, kind: "control"))
        }
        if json, let data = response.data {
            print(JSONOutput.pretty(data))
        }
    }
}

public struct OnCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "on", abstract: "Turn the fixture on.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        try ControlSupport.sendControl(ControlSupport.runner(opts), spec: "on", json: opts.json)
    }
}

public struct OffCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "off", abstract: "Turn the fixture off.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        try ControlSupport.sendControl(ControlSupport.runner(opts), spec: "off", json: opts.json)
    }
}

public struct IntensityCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "intensity", abstract: "Set brightness 0-100 percent.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Brightness percent (0-100).") var percent: Double
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let spec = "intensity:\(ControlSpecBuilder.trimFloat(percent))"
        try ControlSupport.sendControl(ControlSupport.runner(opts), spec: spec, json: opts.json)
    }
}

public struct StatusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Read the fixture's CCT status.")
    @OptionGroup var options: GlobalOptions
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "status")
        let response = try ControlSupport.runner(opts).status()
        guard response.ok, let data = response.data else {
            throw CLIError(ControlResult.failureDetail(response, kind: "status"))
        }
        if opts.json {
            print(JSONOutput.pretty(try StatusReport.statusObject(data)))
        } else {
            print(try StatusReport.humanLine(data))
        }
    }
}

public struct CctCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cct", abstract: "Set color temperature in Kelvin.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Color temperature in Kelvin.") var kelvin: Int
    @Option(name: .customLong("intensity"), help: "Brightness percent (0-100).") var intensity: Double?
    @Option(name: .customLong("gm"), help: "Green-magenta correction (0-20).") var gm: Int?
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let state = try StateLoading.load(opts.statePath)
        let fixture = ControlSupport.capabilityFixture(state, node: opts.node)
        let runner = ControlSupport.runner(opts)

        var current: StatusReport.CurrentValues?
        if ControlSpecBuilder.cctNeedsStatus(intensityPercent: intensity, gm: gm, fixture: fixture) {
            let response = try runner.status()
            guard response.ok, let data = response.data else {
                throw CLIError(ControlResult.failureDetail(response, kind: "status"))
            }
            current = StatusReport.currentValues(parsed: try StatusReport.statusObject(data))
        }

        let built = try ControlSpecBuilder.cctSpec(
            requestedKelvin: kelvin, intensityPercent: intensity, gm: gm,
            fixture: fixture, current: current)
        if let warning = built.clampWarning {
            FileHandle.standardError.write(Data("amaran: \(warning)\n".utf8))
        }
        try ControlSupport.sendControl(runner, spec: built.spec, json: opts.json)
    }
}

public struct GmCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gm", abstract: "Set green-magenta correction (0-20).")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Green-magenta value (0-20; 10 is neutral).") var value: Int
    public init() {}
    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "control")
        let state = try StateLoading.load(opts.statePath)
        let fixture = ControlSupport.capabilityFixture(state, node: opts.node)
        guard Capabilities.gmSupported(fixture) else {
            throw CLIError("selected fixture does not support green-magenta correction")
        }
        let runner = ControlSupport.runner(opts)
        let response = try runner.status()
        guard response.ok, let data = response.data else {
            throw CLIError(ControlResult.failureDetail(response, kind: "status"))
        }
        let current = StatusReport.currentValues(parsed: try StatusReport.statusObject(data))
        let spec = try ControlSpecBuilder.gmSpec(gm: value, fixture: fixture, current: current)
        try ControlSupport.sendControl(runner, spec: spec, json: opts.json)
    }
}
