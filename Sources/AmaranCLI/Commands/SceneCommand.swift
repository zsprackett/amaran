import ArgumentParser
import Foundation
import AmaranCore

/// One fixture entry in a `scene apply` result.
struct SceneApplyFixture: Codable {
    let address: Int
    let name: String
    let succeeded: Bool
    enum CodingKeys: String, CodingKey {
        case address, name
        case succeeded = "ok"
    }
}

/// Result of `scene apply`.
struct SceneApplyResult: Codable {
    let name: String
    let applied: Int
    let fixtures: [SceneApplyFixture]
}

/// `amaran scene ...` — saved lighting looks.
public struct SceneCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "scene",
        abstract: "Manage saved scenes.",
        subcommands: [Capture.self, Apply.self, List.self, Show.self, Delete.self])

    public init() {}

    struct Capture: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Capture fixture state as a named scene.")
        @Option(name: .customLong("state-path")) var statePath: String?
        @Option(name: .customLong("timeout")) var timeout: Double?
        @Flag(name: .customLong("json")) var json = false
        @Option(name: .customLong("node"), help: "Fixture to include (repeatable).") var nodes: [String] = []
        @Option(name: .customLong("off-node"), help: "Fixture to mark off (repeatable).") var offNodes: [String] = []
        @Argument(help: "Scene name.") var name: String

        func run() throws {
            let env = CLIEnvironment.current()
            let path = statePath ?? env.statePath
            let timeout = timeout ?? env.timeout
            var state = try StateLoading.load(path)

            let offFixtures = offNodes.isEmpty ? [] : try SceneControl.selectedFixtures(state, selectors: offNodes)
            let offAddresses = Set(offFixtures.map(\.nodeAddress))
            let onFixtures: [AmaranCore.Fixture]
            if !nodes.isEmpty {
                onFixtures = try SceneControl.selectedFixtures(state, selectors: nodes)
                    .filter { !offAddresses.contains($0.nodeAddress) }
            } else if !offNodes.isEmpty {
                onFixtures = []
            } else {
                onFixtures = try SceneControl.selectedFixtures(state, selectors: [])
            }
            guard !onFixtures.isEmpty || !offFixtures.isEmpty else {
                throw CLIError("local state has no fixtures")
            }

            var captured: [SceneFixture] = []
            for fixture in onFixtures {
                let runner = ControlRunner(env: env, statePath: path,
                                           node: String(fixture.nodeAddress), timeout: timeout)
                let response = try runner.status()
                guard response.succeeded, let data = response.data else {
                    let detail = ControlResult.failureDetail(response, kind: "status")
                    throw CLIError("could not capture fixture \(Capabilities.label(fixture)) "
                        + "at address \(fixture.nodeAddress): \(detail)")
                }
                captured.append(SceneControl.sceneFixture(
                    parsed: try StatusReport.statusObject(data), fixture: fixture))
            }
            for fixture in offFixtures {
                captured.append(SceneControl.forcedOff(fixture))
            }

            let scene = Scene(capturedAt: Timestamp.nowISO8601(), fixtures: captured)
            var scenes = state.scenes ?? [:]
            scenes[name] = scene
            state.scenes = scenes
            try StateLoading.save(state, to: path)

            if json {
                print(JSONOutput.pretty(SceneReport.summary(name: name, scene: scene)))
            } else {
                print("captured scene '\(name)' with \(captured.count) fixtures")
            }
        }
    }

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Apply a saved scene.")
        @Option(name: .customLong("state-path")) var statePath: String?
        @Option(name: .customLong("timeout")) var timeout: Double?
        @Flag(name: .customLong("json")) var json = false
        @Option(name: .customLong("node"), help: "Limit to these fixtures (repeatable).") var nodes: [String] = []
        @Option(name: .customLong("off-node")) var offNodes: [String] = []
        @Argument(help: "Scene name.") var name: String

        func run() throws {
            guard offNodes.isEmpty else {
                throw CLIError("--off-node is only supported for scene capture")
            }
            let env = CLIEnvironment.current()
            let path = statePath ?? env.statePath
            let timeout = timeout ?? env.timeout
            let state = try StateLoading.load(path)
            guard let scene = state.scenes?[name] else { throw CLIError("scene not found: \(name)") }

            let selected: Set<Int>? = nodes.isEmpty
                ? nil
                : Set(try SceneControl.selectedFixtures(state, selectors: nodes).map(\.nodeAddress))
            let byAddress = Dictionary(
                state.fixtures.map { ($0.nodeAddress, $0) }, uniquingKeysWith: { first, _ in first })

            var applied: [SceneApplyFixture] = []
            for entry in scene.fixtures {
                if let selected, !selected.contains(entry.nodeAddress) { continue }
                let fixture = byAddress[entry.nodeAddress]
                    ?? AmaranCore.Fixture(uuid: "", name: entry.name, nodeAddress: entry.nodeAddress, updateTime: "")
                let specs = SceneControl.applySpecs(entry: entry, fixture: fixture)
                let runner = ControlRunner(env: env, statePath: path,
                                           node: String(entry.nodeAddress), timeout: timeout)
                let response = specs.count > 1
                    ? try runner.controlSequence(specs: specs)
                    : try runner.control(spec: specs[0])
                let label = entry.name.isEmpty ? "fixture-\(entry.nodeAddress)" : entry.name
                applied.append(SceneApplyFixture(
                    address: entry.nodeAddress, name: label, succeeded: response.succeeded))
                guard response.succeeded else {
                    throw CLIError("could not apply scene fixture \(label): "
                        + "\(ControlResult.failureDetail(response, kind: "control"))")
                }
            }

            if json {
                print(JSONOutput.pretty(SceneApplyResult(name: name, applied: applied.count, fixtures: applied)))
            } else {
                print("applied scene '\(name)' to \(applied.count) fixtures")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List saved scenes.")
        @OptionGroup var options: GlobalOptions
        func run() throws {
            let opts = options.resolve()
            let summaries = SceneReport.list(try StateLoading.load(opts.statePath))
            if opts.json {
                print(JSONOutput.pretty(SceneListOutput(scenes: summaries)))
            } else {
                SceneReport.listLines(summaries).forEach { print($0) }
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a scene's details.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Scene name.") var name: String
        func run() throws {
            let opts = options.resolve()
            let state = try StateLoading.load(opts.statePath)
            let summary = try SceneReport.show(state, name: name)
            if opts.json {
                print(JSONOutput.pretty(summary))
            } else {
                SceneReport.showLines(summary, state: state).forEach { print($0) }
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a scene.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Scene name.") var name: String
        func run() throws {
            let opts = options.resolve()
            var state = try StateLoading.load(opts.statePath)
            let result = try SceneReport.delete(state: &state, name: name)
            try StateLoading.save(state, to: opts.statePath)
            if opts.json {
                print(JSONOutput.pretty(result))
            } else {
                print("deleted scene '\(result.name)'")
            }
        }
    }
}
