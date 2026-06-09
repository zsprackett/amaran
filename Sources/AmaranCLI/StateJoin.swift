import Foundation
import AmaranCore

public struct JoinFixtureSummary: Codable, Equatable {
    public let name: String
    public let address: Int
    public let macSuffix: String
    public let code: String
    public let controlOnly: Bool
    enum CodingKeys: String, CodingKey {
        case name, address
        case macSuffix = "mac_suffix"
        case code
        case controlOnly = "control_only"
    }
}

public struct JoinRuntimeSummary: Codable, Equatable {
    public let ivIndex: Int
    public let sourceAddress: Int
    public let telinkSourceAddress: Int
    public let sequenceNext: Int
    enum CodingKeys: String, CodingKey {
        case ivIndex = "iv_index"
        case sourceAddress = "source_address"
        case telinkSourceAddress = "telink_source_address"
        case sequenceNext = "sequence_next"
    }
}

public struct JoinResult: Codable, Equatable {
    public let joined: Bool
    public let sourcePath: String
    public let targetPath: String
    public let fixtureCount: Int
    public let fixtures: [JoinFixtureSummary]
    public let controlOnly: Bool
    public let runtime: JoinRuntimeSummary
    enum CodingKeys: String, CodingKey {
        case joined
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case fixtureCount = "fixture_count"
        case fixtures
        case controlOnly = "control_only"
        case runtime
    }
}

/// `state-join` builder: turns an external join file (mesh keys + fixtures) into
/// a control-ready local `State`, choosing unused runtime source addresses.
/// Ported from the zsh `run_state_join`.
public enum StateJoin {
    public static func build(source: JSONValue, now: String) throws -> State {
        let meshIn = source["mesh"]?.objectValue ?? source.objectValue ?? [:]
        let runtimeIn = source["runtime"]?.objectValue ?? [:]
        guard let fixturesIn = source["fixtures"]?.arrayValue, !fixturesIn.isEmpty else {
            throw CLIError("join state requires a non-empty fixtures array")
        }

        let netKey = try hexValue(meshIn["net_key"], bytes: 16, label: "mesh net_key")
        let appKey = try hexValue(meshIn["app_key"], bytes: 16, label: "mesh app_key")
        let ivIndex = try intInRange(
            runtimeIn["iv_index"] ?? meshIn["iv_index"] ?? source["iv_index"] ?? .int(0),
            0, 0xFFFF_FFFF, "runtime iv_index")
        let sequenceNext = try intInRange(
            runtimeIn["sequence_next"] ?? source["sequence_next"] ?? .int(1),
            0, 0x00FF_FFFE, "runtime sequence_next")

        var fixtures: [Fixture] = []
        var occupied = Set<Int>()
        for (offset, item) in fixturesIn.enumerated() {
            let index = offset + 1
            guard let fixture = item.objectValue else {
                throw CLIError("join state fixture #\(index) must be a JSON object")
            }
            let address = try intInRange(
                fixture["node_address"] ?? fixture["address"], 1, 0x7FFF,
                "fixture #\(index) node_address")
            let elementCount = try elementCountFor(fixture, index: index)
            for delta in 0..<elementCount {
                let elementAddress = address + delta
                guard elementAddress <= 0x7FFF else {
                    throw CLIError("join state fixture #\(index) element address exceeds unicast range")
                }
                guard !occupied.contains(elementAddress) else {
                    throw CLIError("join state has duplicate fixture element address \(elementAddress)")
                }
                occupied.insert(elementAddress)
            }
            let mac = try normalizeMac(fixture["mac_address"] ?? fixture["mac"])
            let deviceKey = try optionalHexValue(fixture["device_key"], bytes: 16, label: "fixture #\(index) device_key")
            let deviceUUID = try optionalHexValue(fixture["device_uuid"], bytes: 16, label: "fixture #\(index) device_uuid")
            let uuid = nonEmptyString(fixture["uuid"]) ?? deviceUUID ?? "joined-\(address)"
            fixtures.append(Fixture(
                uuid: uuid,
                macAddress: mac,
                code: nonEmptyString(fixture["code"]) ?? "",
                name: nonEmptyString(fixture["name"]) ?? nonEmptyString(fixture["label"]) ?? "",
                nodeAddress: address,
                deviceKey: deviceKey,
                deviceUUID: deviceUUID,
                compositionData: try optionalHexBlob(fixture["composition_data"], label: "fixture #\(index) composition_data"),
                elementCount: elementCount,
                updateTime: now,
                state: 0,
                controlOnly: deviceKey == nil))
        }

        let sourceAddress = try chooseRuntimeSourceAddress(runtimeIn, source, occupied: occupied)
        var occupiedWithSource = occupied
        occupiedWithSource.insert(sourceAddress)
        let telinkSourceAddress = try chooseTelinkSourceAddress(
            runtimeIn, source, occupied: occupied, occupiedWithSource: occupiedWithSource)

        let controlOnly = fixtures.contains { $0.controlOnly == true }
        return State(
            schemaVersion: 1,
            syncedAt: now,
            source: Source(type: "mesh_join_import", joinedAt: now, controlOnly: controlOnly),
            mesh: Mesh(
                uuid: nonEmptyString(meshIn["uuid"]) ?? nonEmptyString(source["uuid"]) ?? "joined-mesh",
                netKey: netKey, appKey: appKey, updateTime: now),
            fixtures: fixtures,
            runtime: Runtime(
                ivIndex: ivIndex, sourceAddress: sourceAddress,
                telinkSourceAddress: telinkSourceAddress, sequenceNext: sequenceNext,
                updatedAt: now, lastReservedBy: "state-join"))
    }

    public static func result(state: State, sourcePath: String, targetPath: String) -> JoinResult {
        let summaries = state.fixtures.map {
            JoinFixtureSummary(
                name: Capabilities.label($0), address: $0.nodeAddress,
                macSuffix: MacAddress.suffix($0.macAddress), code: $0.code,
                controlOnly: $0.controlOnly ?? false)
        }
        return JoinResult(
            joined: true, sourcePath: sourcePath, targetPath: targetPath,
            fixtureCount: state.fixtures.count, fixtures: summaries,
            controlOnly: state.source.controlOnly ?? false,
            runtime: JoinRuntimeSummary(
                ivIndex: state.runtime.ivIndex, sourceAddress: state.runtime.sourceAddress,
                telinkSourceAddress: state.runtime.telinkSourceAddress,
                sequenceNext: state.runtime.sequenceNext))
    }

    public static func humanLines(_ result: JoinResult) -> [String] {
        var lines: [String] = []
        let word = result.fixtureCount == 1 ? "fixture" : "fixtures"
        lines.append("joined mesh with \(result.fixtureCount) \(word) at \(result.targetPath)")
        for fixture in result.fixtures {
            let suffix = fixture.macSuffix.isEmpty ? "unknown" : fixture.macSuffix
            let mode = fixture.controlOnly ? "control-only" : "full"
            lines.append("\(fixture.name)\t\(fixture.address)\t...\(suffix)\t\(mode)")
        }
        if result.controlOnly {
            lines.append("warning: DeviceKeys are missing for at least one fixture; Config diagnostics and node reset are unavailable for those fixtures")
        }
        return lines
    }

    // MARK: - Address selection

    static func chooseSourceAddress(occupied: Set<Int>, destination: Int? = nil, prefer: Int = 3) throws -> Int {
        if !occupied.contains(prefer), prefer != destination { return prefer }
        for candidate in 4..<0x8000 where !occupied.contains(candidate) && candidate != destination {
            return candidate
        }
        if !occupied.contains(2), 2 != destination { return 2 }
        throw CLIError("join state could not choose an unused source address")
    }

    private static func chooseRuntimeSourceAddress(
        _ runtimeIn: [String: JSONValue], _ source: JSONValue, occupied: Set<Int>
    ) throws -> Int {
        let provided = runtimeIn["source_address"] ?? source["source_address"]
        if isEmpty(provided) {
            return try chooseSourceAddress(occupied: occupied, prefer: 3)
        }
        let value = try intInRange(provided, 1, 0x7FFF, "runtime source_address")
        if occupied.contains(value) {
            throw CLIError("join state runtime source_address collides with a fixture address")
        }
        return value
    }

    private static func chooseTelinkSourceAddress(
        _ runtimeIn: [String: JSONValue], _ source: JSONValue,
        occupied: Set<Int>, occupiedWithSource: Set<Int>
    ) throws -> Int {
        let provided = runtimeIn["telink_source_address"] ?? source["telink_source_address"]
        if isEmpty(provided) {
            return occupiedWithSource.contains(1)
                ? try chooseSourceAddress(occupied: occupiedWithSource, prefer: 3)
                : 1
        }
        let value = try intInRange(provided, 1, 0x7FFF, "runtime telink_source_address")
        if occupied.contains(value) {
            throw CLIError("join state runtime telink_source_address collides with a fixture address")
        }
        return value
    }

    // MARK: - Field helpers

    private static func elementCountFor(_ fixture: [String: JSONValue], index: Int) throws -> Int {
        guard let value = fixture["element_count"], !isEmpty(value) else { return 1 }
        return try intInRange(value, 1, 255, "fixture element_count")
    }

    private static func isEmpty(_ value: JSONValue?) -> Bool {
        switch value {
        case .none, .some(.null): return true
        case .some(.string(let s)): return s.isEmpty
        default: return false
        }
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let s = value?.stringValue, !s.isEmpty else { return nil }
        return s
    }

    private static func isHexBytes(_ value: String, bytes: Int? = nil) -> Bool {
        guard !value.isEmpty, value.count % 2 == 0, value.allSatisfy({ $0.isHexDigit }) else { return false }
        if let bytes, value.count != bytes * 2 { return false }
        return true
    }

    private static func hexValue(_ value: JSONValue?, bytes: Int, label: String) throws -> String {
        guard let s = value?.stringValue, isHexBytes(s.trimmingCharacters(in: .whitespaces), bytes: bytes) else {
            throw CLIError("join state has invalid \(label)")
        }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func optionalHexValue(_ value: JSONValue?, bytes: Int, label: String) throws -> String? {
        if isEmpty(value) { return nil }
        return try hexValue(value, bytes: bytes, label: label)
    }

    private static func optionalHexBlob(_ value: JSONValue?, label: String) throws -> String {
        if isEmpty(value) { return "" }
        guard let s = value?.stringValue, isHexBytes(s.trimmingCharacters(in: .whitespaces)) else {
            throw CLIError("join state has invalid \(label)")
        }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func normalizeMac(_ value: JSONValue?) throws -> String {
        let raw = value?.stringValue ?? ""
        let hex = raw.filter { $0.isHexDigit }.uppercased()
        if hex.isEmpty { return "" }
        guard hex.count == 12 else { throw CLIError("join state has invalid fixture mac_address") }
        var parts: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            parts.append(String(hex[i..<next]))
            i = next
        }
        return parts.joined(separator: ":")
    }

    private static func intInRange(_ value: JSONValue?, _ lo: Int, _ hi: Int, _ label: String) throws -> Int {
        let parsed: Int?
        switch value {
        case .int(let i): parsed = i
        case .double(let d): parsed = Int(d)
        case .string(let s): parsed = parseIntBase0(s)
        default: parsed = nil
        }
        guard let result = parsed else { throw CLIError("join state has invalid \(label)") }
        guard lo <= result, result <= hi else { throw CLIError("join state has out-of-range \(label)") }
        return result
    }

    private static func parseIntBase0(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] {
            if s.hasPrefix(prefix) { return Int(s.dropFirst(2), radix: radix) }
        }
        return Int(s)
    }
}
