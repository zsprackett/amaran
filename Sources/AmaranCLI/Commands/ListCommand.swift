import ArgumentParser
import AmaranCore

/// `amaran list` — redacted fixture summaries from local state.
public struct ListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Read redacted fixture summaries from local state.")

    @OptionGroup var options: GlobalOptions

    public init() {}

    public func run() throws {
        let opts = options.resolve()
        let state = try StateLoading.load(opts.statePath)
        let entries = ListReport.entries(state)
        if opts.json {
            print(JSONOutput.pretty(entries))
        } else {
            ListReport.humanLines(entries).forEach { print($0) }
        }
    }
}
