import ArgumentParser
import Foundation
import AmaranCore

/// JSON output shape for `amaran discover`.
struct DiscoverOutput: Codable {
    let discovered: Int
    let range: String
    let updatedState: Bool
    let fixtures: [DiscoverFixture]
    let misses: [DiscoverMiss]
    let runtimeSourceRelocated: SourceRelocation?
    enum CodingKeys: String, CodingKey {
        case discovered, range
        case updatedState = "updated_state"
        case fixtures, misses
        case runtimeSourceRelocated = "runtime_source_relocated"
    }
}

/// `amaran discover --range <spec>` — probe an address range over one Mesh Proxy
/// connection (`--status-batch`) and optionally add responsive control-only
/// fixtures. Ported from `scripts/discover-existing-mesh` (batch path).
public struct DiscoverCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "discover", abstract: "Probe an address range for control-only fixtures.")

    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("range"), help: "Address range, e.g. 2-32 or 2-8,12.") var range: String
    @Flag(name: .customLong("update-state"), help: "Keep responsive fixtures in local state.") var updateState = false

    public init() {}

    public func run() throws {
        let opts = options.resolve()
        var state = try StateLoading.load(opts.statePath)
        let addresses = try DiscoverScan.parseRange(range)
        let now = Timestamp.nowISO8601()

        let relocation = try DiscoverScan.relocateRuntimeSourceIfNeeded(
            &state, scan: Set(addresses), now: now)
        if relocation != nil { try StateLoading.save(state, to: opts.statePath) }

        // Probe all addresses over one connection.
        let settle = DiscoverScan.settleAfterWrite(addressCount: addresses.count, timeout: opts.timeout)
        let args = ["--timeout", String(format: "%g", opts.timeout),
                    "--state-path", opts.statePath,
                    "--status-batch", addresses.map(String.init).joined(separator: ","),
                    "--settle-after-write", String(format: "%g", settle)]
        let response = try AppLauncher.runOneShot(appPath: opts.env.appPath, arguments: args)
        guard response.succeeded, let data = response.data else {
            throw CLIError(response.error ?? "status batch failed")
        }

        let statuses = DiscoverScan.statusesBySource(data, addresses: addresses)
        var found: [DiscoverFixture] = []
        var misses: [DiscoverMiss] = []
        for address in addresses {
            let fixture = state.fixtures.first { $0.nodeAddress == address }
            if let cct = statuses[address] {
                found.append(DiscoverScan.normalizeStatus(address: address, fixture: fixture, cct: cct))
            } else {
                misses.append(DiscoverMiss(address: address, reason: "no-status"))
            }
        }

        if updateState, !found.isEmpty {
            for fixture in found { DiscoverScan.ensureFixture(&state, address: fixture.address, now: now) }
            try StateLoading.save(state, to: opts.statePath)
        }

        let output = DiscoverOutput(discovered: found.count, range: range, updatedState: updateState,
                                    fixtures: found, misses: misses, runtimeSourceRelocated: relocation)
        if opts.json {
            print(JSONOutput.pretty(output))
        } else {
            print("discovered \(found.count) fixtures in range \(range)")
            for fixture in found {
                print("\(fixture.address)\t\(fixture.name)\t\(detail(fixture))")
            }
            if let relocation {
                print("runtime source moved \(relocation.from)->\(relocation.toAddress) "
                    + "to avoid scanned fixture addresses")
            }
            if !updateState {
                print("state fixtures unchanged; sequence counters may be advanced")
            }
        }
    }

    private func detail(_ fixture: DiscoverFixture) -> String {
        var parts: [String] = []
        if let intensity = fixture.intensity { parts.append("\(ControlSpecBuilder.trimFloat(intensity))%") }
        if let cct = fixture.cct { parts.append("\(cct)K") }
        if let greenMagenta = fixture.greenMagenta { parts.append("gm=\(greenMagenta)") }
        if let sleep = fixture.sleepMode { parts.append("sleep=\(sleep)") }
        return parts.joined(separator: ", ")
    }
}
