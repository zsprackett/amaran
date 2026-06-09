import Foundation
import AmaranCore

public struct DiscoverFixture: Codable, Equatable {
    public let address: Int
    public let name: String
    public let macSuffix: String
    public let intensity: Double?
    public let cct: Int?
    public let gm: Int?
    public let sleepMode: Int?
    public let controlOnly: Bool
    enum CodingKeys: String, CodingKey {
        case address, name
        case macSuffix = "mac_suffix"
        case intensity, cct, gm
        case sleepMode = "sleep_mode"
        case controlOnly = "control_only"
    }
}

public struct DiscoverMiss: Codable, Equatable {
    public let address: Int
    public let reason: String
}

public struct SourceRelocation: Codable, Equatable {
    public let from: Int
    public let to: Int
}

/// Pure discovery logic, ported from `scripts/discover-existing-mesh`. The live
/// batch probe is the one piece that needs hardware; everything here is testable.
public enum DiscoverScan {
    /// Parses an address range spec like "2-32" or "2-8,12" into unique unicast
    /// addresses.
    public static func parseRange(_ spec: String) throws -> [Int] {
        guard !spec.isEmpty else { throw CLIError("discover requires --range <start-end>") }
        var addresses: [Int] = []
        for rawPart in spec.split(separator: ",") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            if let dash = part.firstIndex(of: "-") {
                guard let start = parseIntBase0(String(part[part.startIndex..<dash])),
                    let end = parseIntBase0(String(part[part.index(after: dash)...])), start <= end
                else { throw CLIError("discover has invalid --range") }
                addresses.append(contentsOf: start...end)
            } else if let value = parseIntBase0(part) {
                addresses.append(value)
            } else {
                throw CLIError("discover has invalid --range")
            }
        }
        guard !addresses.isEmpty else { throw CLIError("discover has invalid --range") }
        var seen = Set<Int>()
        var unique: [Int] = []
        for address in addresses {
            guard (1...0x7FFF).contains(address) else {
                throw CLIError("discover --range contains a non-unicast address")
            }
            if seen.insert(address).inserted { unique.append(address) }
        }
        return unique
    }

    public static func occupiedAddresses(_ state: State) -> Set<Int> {
        var occupied = Set<Int>()
        for fixture in state.fixtures where (1...0x7FFF).contains(fixture.nodeAddress) {
            let count = fixture.elementCount.flatMap { (1...255).contains($0) ? $0 : 1 } ?? 1
            for offset in 0..<count where (1...0x7FFF).contains(fixture.nodeAddress + offset) {
                occupied.insert(fixture.nodeAddress + offset)
            }
        }
        return occupied
    }

    public static func chooseSourceAddress(_ state: State, avoid: Set<Int>) throws -> Int {
        var blocked = occupiedAddresses(state).union(avoid)
        if (1...0x7FFF).contains(state.runtime.telinkSourceAddress) {
            blocked.insert(state.runtime.telinkSourceAddress)
        }
        for candidate in 3..<0x8000 where !blocked.contains(candidate) { return candidate }
        for candidate in 2..<0x8000 where !blocked.contains(candidate) { return candidate }
        throw CLIError("discover could not choose a safe CLI source address")
    }

    /// If the runtime source address sits in the scan range, relocate it.
    public static func relocateRuntimeSourceIfNeeded(
        _ state: inout State, scan: Set<Int>, now: String
    ) throws -> SourceRelocation? {
        let source = state.runtime.sourceAddress
        guard (1...0x7FFF).contains(source), scan.contains(source) else { return nil }
        let replacement = try chooseSourceAddress(state, avoid: scan)
        state.runtime.sourceAddress = replacement
        state.runtime.updatedAt = now
        state.runtime.lastReservedBy = "discover-source-relocation"
        return SourceRelocation(from: source, to: replacement)
    }

    /// Maps batch proxy notifications to their source address's telink CCT block.
    public static func statusesBySource(_ batch: JSONValue, addresses: [Int]) -> [Int: JSONValue] {
        let wanted = Set(addresses)
        var result: [Int: JSONValue] = [:]
        for notification in batch["proxy_notifications"]?.arrayValue ?? [] {
            guard let source = notification["network"]?["source"]?.intValue, wanted.contains(source),
                let cct = notification["access"]?["telink"]?["cct"], cct.objectValue != nil
            else { continue }
            result[source] = cct
        }
        return result
    }

    /// Builds a discovered-fixture summary from a raw telink CCT block.
    public static func normalizeStatus(address: Int, fixture: Fixture?, cct: JSONValue) -> DiscoverFixture {
        let cctObj = cct.objectValue ?? [:]
        let intensity = cctObj["intensity_percent"]?.doubleValue
            ?? cctObj["intensity"]?.doubleValue.map { $0 / 10 }
        var kelvin = cctObj["cct_kelvin"]?.intValue ?? cctObj["cct"]?.intValue
        if let k = kelvin, k < 1000 { kelvin = k * 10 }
        let name = fixture.map { Capabilities.label($0) } ?? "fixture-\(address)"
        return DiscoverFixture(
            address: address, name: name,
            macSuffix: MacAddress.suffix(fixture?.macAddress),
            intensity: intensity, cct: kelvin,
            gm: cctObj["gm_decoded"]?.intValue ?? cctObj["gm"]?.intValue,
            sleepMode: cctObj["sleep_mode"]?.intValue,
            controlOnly: fixture?.controlOnly ?? true)
    }

    /// Adds a control-only fixture for an address if not already present.
    @discardableResult
    public static func ensureFixture(_ state: inout State, address: Int, now: String) -> Bool {
        if state.fixtures.contains(where: { $0.nodeAddress == address }) { return false }
        state.fixtures.append(Fixture(
            uuid: "discovered-\(address)", name: "fixture-\(address)",
            nodeAddress: address, compositionData: "", elementCount: 1,
            updateTime: now, controlOnly: true))
        return true
    }

    public static func settleAfterWrite(addressCount: Int, timeout: Double) -> Double {
        min(max(2.0, 1.5 + Double(addressCount) * 0.02), max(0.5, timeout - 2.0))
    }

    private static func parseIntBase0(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] {
            if s.hasPrefix(prefix) { return Int(s.dropFirst(2), radix: radix) }
        }
        return Int(s)
    }
}
