import Foundation
import AmaranCore

/// A redacted, key-free fixture summary for `amaran list`. Field names match the
/// zsh `--json` output.
public struct FixtureListEntry: Codable, Equatable {
    public let name: String
    public let friendlyName: String?
    public let sourceName: String?
    public let address: Int
    public let mac: String
    public let capabilities: ResolvedCapabilities

    enum CodingKeys: String, CodingKey {
        case name
        case friendlyName = "friendly_name"
        case sourceName = "source_name"
        case address, mac, capabilities
    }
}

public enum ListReport {
    public static func entries(_ state: State) -> [FixtureListEntry] {
        state.fixtures.map { fixture in
            FixtureListEntry(
                name: Capabilities.label(fixture),
                friendlyName: fixture.friendlyName.flatMap { $0.isEmpty ? nil : $0 },
                sourceName: fixture.name.isEmpty ? nil : fixture.name,
                address: fixture.nodeAddress,
                mac: MacAddress.display(fixture.macAddress),
                capabilities: Capabilities.resolve(fixture))
        }
    }

    /// Aligned columns matching the zsh human output.
    public static func humanLines(_ entries: [FixtureListEntry]) -> [String] {
        guard !entries.isEmpty else { return ["No fixtures found."] }
        let nameWidth = entries.map { $0.name.count }.max() ?? 0
        let addressWidth = entries.map { String($0.address).count }.max() ?? 0
        return entries.map { entry in
            let name = entry.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let address = String(String(entry.address).reversed())
                .padding(toLength: addressWidth, withPad: " ", startingAt: 0)
            let addressRightAligned = String(address.reversed())
            return "\(name)  \(addressRightAligned)  \(entry.mac)"
        }
    }
}
