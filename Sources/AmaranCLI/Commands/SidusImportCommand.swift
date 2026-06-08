import ArgumentParser
import Foundation
import AmaranCore

/// `amaran sidus-import --backup <path>` — import a Sidus Link iPad backup into
/// local state. Fully native, including encrypted-backup decryption.
public struct SidusImportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sidus-import",
        abstract: "Import a Sidus Link Pro iPad backup into local state.")

    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("backup"), help: "iPad backup or extracted Sidus app container.")
    var backup: String
    @Option(name: .customLong("mesh"), help: "Pick a mesh by name, UUID, or file path substring.")
    var mesh: String = ""
    @Flag(name: .customLong("replace"), help: "Overwrite the target CLI state instead of failing.")
    var replace = false

    public init() {}

    public func run() throws {
        let opts = options.resolve()
        let target = (opts.statePath as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: target), !replace {
            throw CLIError("target state file already exists at \(target); pass --replace to overwrite it")
        }

        let files = try SidusBackup.loadMeshFiles(backupPath: backup)
        let now = Timestamp.nowISO8601()
        let candidates = files.compactMap { SidusImport.candidate(from: $0, now: now) }
        let selected = try SidusImport.select(candidates, selector: mesh)
        let state = SidusImport.buildState(selected, now: now)

        do {
            try StateStore.save(state, to: target)
        } catch {
            throw CLIError("target state file could not be written: \(error)")
        }

        let result = SidusImport.result(state: state, targetPath: Paths.display(target))
        if opts.json {
            print(JSONOutput.pretty(result))
        } else {
            SidusImport.humanLines(result).forEach { print($0) }
        }
    }
}
