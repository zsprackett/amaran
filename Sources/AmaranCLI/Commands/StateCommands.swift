import ArgumentParser
import Foundation
import AmaranCore

/// `amaran state-join <file>` — join an existing mesh from external keys for
/// runtime control only.
public struct StateJoinCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "state-join",
        abstract: "Join an existing mesh from external NetKey/AppKey metadata.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Join-state JSON file.") var source: String

    public init() {}

    public func run() throws {
        let opts = options.resolve()
        let target = (opts.statePath as NSString).expandingTildeInPath
        let src = (source as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: src) else {
            throw CLIError("join state file not found at \(src)")
        }
        guard !FileManager.default.fileExists(atPath: target) else {
            throw CLIError("target state file already exists at \(target); move it before joining mesh")
        }
        guard Paths.absolute(src) != Paths.absolute(target) else {
            throw CLIError("source and target state paths must be different")
        }

        let json = try Paths.readJSON(src, subject: "join state file")
        let state = try StateJoin.build(source: json, now: Timestamp.nowISO8601())
        do {
            try StateStore.save(state, to: target)
        } catch {
            throw CLIError("target state file could not be written: \(error)")
        }

        let result = StateJoin.result(
            state: state, sourcePath: Paths.display(src), targetPath: Paths.display(target))
        if opts.json {
            print(JSONOutput.pretty(result))
        } else {
            StateJoin.humanLines(result).forEach { print($0) }
        }
    }
}

/// `amaran state-install <file>` — validate and install a full state file.
public struct StateInstallCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "state-install",
        abstract: "Validate and install a state file with 0600 permissions.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Source state JSON file.") var source: String

    public init() {}

    public func run() throws {
        let opts = options.resolve()
        let target = (opts.statePath as NSString).expandingTildeInPath
        let src = (source as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: src) else {
            throw CLIError("source state file not found at \(src)")
        }
        guard !FileManager.default.fileExists(atPath: target) else {
            throw CLIError("target state file already exists at \(target); move it before installing state")
        }
        guard Paths.absolute(src) != Paths.absolute(target) else {
            throw CLIError("source and target state paths must be different")
        }

        let payload = try Paths.readJSON(src, subject: "source state file")
        try StateInstall.validate(payload)
        do {
            try StateStore.writeEncodable(payload, to: target)
        } catch {
            throw CLIError("target state file could not be written: \(error)")
        }

        let result = StateInstall.summary(
            payload: payload, sourcePath: Paths.display(src), targetPath: Paths.display(target))
        if opts.json {
            print(JSONOutput.pretty(result))
        } else {
            StateInstall.humanLines(result).forEach { print($0) }
        }
    }
}
