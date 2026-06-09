import ArgumentParser
import Foundation
import AmaranCore

/// `amaran daemon ...` — manage the local runtime daemon (launchd LaunchAgent).
public struct DaemonCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the local runtime daemon.",
        subcommands: [Start.self, Status.self, Stop.self, Logs.self, Install.self, Uninstall.self],
        defaultSubcommand: Status.self)

    public init() {}

    // Shared: ensure a daemon is reachable, then ping and print its status.
    private static func reportStatus(_ options: GlobalOptions) throws {
        let opts = options.resolve()
        let client = opts.env.daemonClient()
        guard !opts.env.daemonDisabled, client.ensureRunning() else {
            throw CLIError("daemon is not reachable")
        }
        let response = try client.exchange(.ping, timeout: max(1, opts.timeout))
        print(opts.json ? DaemonReport.compactJSON(response) : DaemonReport.humanStatus(response))
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the daemon if not running.")
        @OptionGroup var options: GlobalOptions
        func run() throws { try DaemonCommand.reportStatus(options) }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show daemon status.")
        @OptionGroup var options: GlobalOptions
        func run() throws { try DaemonCommand.reportStatus(options) }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the daemon.")
        @OptionGroup var options: GlobalOptions
        func run() throws {
            let opts = options.resolve()
            if LaunchAgent.isInstalled(env: opts.env) {
                LaunchAgent.stop(env: opts.env)
                if opts.json {
                    print("{\"ok\":true,\"stopped\":true,\"managed\":\"launchd\"}")
                } else {
                    print("daemon stopped (launchd agent unloaded; returns at next login)")
                }
                return
            }
            let client = opts.env.daemonClient()
            guard let response = try? client.exchange(.shutdown, timeout: max(1, opts.timeout)) else {
                throw CLIError("daemon is not reachable")
            }
            print(opts.json ? DaemonReport.compactJSON(response) : "daemon stopped")
        }
    }

    struct Logs: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stream or show daemon logs.")
        @OptionGroup var options: GlobalOptions
        @Option(name: .customLong("since"), help: "Show history over a duration (e.g. 1h, 30m).")
        var since: String?

        func run() throws {
            let opts = options.resolve()
            let predicate = "subsystem == \"\(opts.env.logSubsystem)\""
            let style = opts.json ? "ndjson" : "compact"
            var arguments: [String]
            if let since {
                arguments = ["show", "--predicate", predicate, "--last", since,
                             "--info", "--debug", "--style", style]
            } else {
                arguments = ["stream", "--predicate", predicate, "--level", "debug", "--style", style]
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw ExitCode(process.terminationStatus)
            }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register the launchd LaunchAgent.")
        @OptionGroup var options: GlobalOptions
        func run() throws {
            let opts = options.resolve()
            FileHandle.standardError.write(
                Data("amaran: priming Bluetooth permission (a prompt may appear)...\n".utf8))
            do {
                try LaunchAgent.install(env: opts.env)
            } catch {
                throw CLIError(String(describing: error))
            }
            if opts.json {
                print("{\"ok\":true,\"installed\":true,\"label\":\"\(opts.env.daemonLabel)\"}")
            } else {
                print("daemon installed: \(opts.env.daemonLabel) (runs at login, auto-restarts)")
                print("plist: \(opts.env.launchAgentPlistPath)")
                print("If Bluetooth control fails, grant permission in")
                print("System Settings > Privacy & Security > Bluetooth, then run: amaran daemon install")
            }
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the launchd LaunchAgent.")
        @OptionGroup var options: GlobalOptions
        func run() throws {
            let opts = options.resolve()
            LaunchAgent.uninstall(env: opts.env)
            if opts.json {
                print("{\"ok\":true,\"installed\":false,\"label\":\"\(opts.env.daemonLabel)\"}")
            } else {
                print("daemon uninstalled: \(opts.env.daemonLabel)")
            }
        }
    }
}
