import ArgumentParser
import Foundation

/// `amaran doctor` — inspect local state and control readiness.
public struct DoctorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Inspect local state, runtime counters, and control readiness.")

    @OptionGroup var options: GlobalOptions

    public init() {}

    public func run() throws {
        let opts = options.resolve()
        let data = DoctorReport.inspect(statePath: opts.statePath)
        if opts.json {
            print(JSONOutput.pretty(data))
        } else {
            DoctorReport.humanLines(data).forEach { print($0) }
        }
    }
}
