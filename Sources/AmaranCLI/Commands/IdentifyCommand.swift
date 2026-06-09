import ArgumentParser
import Foundation
import AmaranCore

/// `amaran identify [<id|name>]` — blink a fixture three times, then restore it.
public struct IdentifyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "identify",
        abstract: "Blink the selected fixture three times, then restore state.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Fixture node address or name (or use --node).") var node: String?

    public init() {}

    public func run() throws {
        let opts = options.resolve()
        try ControlSupport.requireState(opts.statePath, kind: "identify")
        if node != nil, options.node != nil {
            throw CLIError("pass fixture node/name either as identify argument or --node, not both")
        }
        let selector = node ?? opts.node
        let runner = ControlRunner(env: opts.env, statePath: opts.statePath,
                                   node: selector, timeout: opts.timeout)

        let statusResponse = try runner.status()
        guard statusResponse.ok, let data = statusResponse.data else {
            throw CLIError(ControlResult.failureDetail(statusResponse, kind: "status"))
        }
        let plan = IdentifyPlan.plan(parsed: try StatusReport.statusObject(data))

        let response = try runner.controlSequence(specs: plan.sequence())
        guard response.ok else {
            throw CLIError(ControlResult.failureDetail(response, kind: "control"))
        }

        if opts.json {
            let address = plan.address.map { JSONValue.int($0) } ?? .null
            print(JSONOutput.pretty(JSONValue.object([
                "identified": .bool(true),
                "address": address,
                "flashes": .int(3),
                "restored": .string(plan.originalState),
            ])))
        } else {
            print("identified address \(plan.address.map(String.init) ?? "unknown") with 3 flashes")
        }
    }
}
