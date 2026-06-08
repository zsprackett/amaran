import ArgumentParser
import AmaranCore

/// `amaran fixture rename|clear-name` — manage fixture friendly names in local state.
public struct FixtureCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "fixture",
        abstract: "Manage fixture friendly names in local state.",
        subcommands: [Rename.self, ClearName.self])

    public init() {}

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a fixture in local state.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Fixture node address or name.") var node: String
        @Argument(help: "New friendly name.") var name: String

        func run() throws {
            let opts = options.resolve()
            var state = try StateLoading.load(opts.statePath)
            let result = try FixtureOps.rename(state: &state, selector: node, name: name)
            try StateLoading.save(state, to: opts.statePath)
            if opts.json {
                print(JSONOutput.pretty(result))
            } else {
                print("renamed fixture \(result.fixture.address) to \(result.fixture.friendlyName ?? name)")
            }
        }
    }

    struct ClearName: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-name",
            abstract: "Clear a fixture's friendly name in local state.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Fixture node address or name.") var node: String

        func run() throws {
            let opts = options.resolve()
            var state = try StateLoading.load(opts.statePath)
            let result = try FixtureOps.clearName(state: &state, selector: node)
            try StateLoading.save(state, to: opts.statePath)
            if opts.json {
                print(JSONOutput.pretty(result))
            } else if let previous = result.previousFriendlyName {
                print("cleared friendly name \(previous) from fixture \(result.fixture.address)")
            } else {
                print("fixture \(result.fixture.address) had no friendly name")
            }
        }
    }
}
