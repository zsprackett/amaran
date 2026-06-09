import Foundation
import AmaranCore

/// A mesh JSON file pulled from a backup or extracted container.
public struct SidusMeshFile: Equatable {
    public let domain: String
    public let relativePath: String
    public let data: Data
    public init(domain: String, relativePath: String, data: Data) {
        self.domain = domain
        self.relativePath = relativePath
        self.data = data
    }
}

/// A parsed Sidus mesh candidate (one mesh JSON with usable keys + fixtures).
public struct SidusCandidate {
    public let domain: String
    public let relativePath: String
    public let meshName: String
    public let meshUUID: String
    public let netKey: String
    public let appKey: String
    public let fixtures: [Fixture]
    public let score: Score

    public struct Score: Comparable {
        public let fixtureCount: Int
        public let macCount: Int
        public let deviceKeyCount: Int
        public static func < (lhs: Score, rhs: Score) -> Bool {
            (lhs.fixtureCount, lhs.macCount, lhs.deviceKeyCount)
                < (rhs.fixtureCount, rhs.macCount, rhs.deviceKeyCount)
        }
    }
}

public struct SidusImportFixtureSummary: Codable, Equatable {
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

public struct SidusImportResult: Codable, Equatable {
    public let imported: Bool
    public let targetPath: String
    public let fixtureCount: Int
    public let fixtures: [SidusImportFixtureSummary]
    public let controlOnly: Bool
    enum CodingKeys: String, CodingKey {
        case imported
        case targetPath = "target_path"
        case fixtureCount = "fixture_count"
        case fixtures
        case controlOnly = "control_only"
    }
}

/// Pure Sidus import logic, ported from `scripts/sidus-backup-import`: parse mesh
/// JSON, pick the best candidate, choose runtime addresses, and build state.
public enum SidusImport {
    public static func candidate(from file: SidusMeshFile, now: String) -> SidusCandidate? {
        guard let mesh = decodeJSON(file.data)?.objectValue,
            let netKeys = mesh["netKeys"]?.arrayValue, !netKeys.isEmpty,
            let appKeys = mesh["appKeys"]?.arrayValue, !appKeys.isEmpty,
            mesh["nodes"]?.arrayValue != nil
        else { return nil }

        let netKey = normalizeHex(netKeys[0]["key"], bytes: 16)
        let appKey = normalizeHex(appKeys[0]["key"], bytes: 16)
        guard !netKey.isEmpty, !appKey.isEmpty else { return nil }

        var fixtures: [Fixture] = []
        for node in mesh["nodes"]?.arrayValue ?? [] {
            guard let node = node.objectValue else { continue }
            let name = (node["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard let address = parseAddress(node["unicastAddress"]),
                address > 0, address <= 0x7FFF,
                address != 1, name != "ItonMeshProvisioner"
            else { continue }

            let elementCount = max(1, node["elements"]?.arrayValue?.count ?? 0)
            let deviceKey = normalizeHex(node["deviceKey"], bytes: 16)
            let deviceUUID = deviceUUIDFromNode(node)
            fixtures.append(Fixture(
                uuid: nonEmpty(node["UUID"]) ?? nonEmpty(node["uuid"]) ?? "sidus-\(address)",
                macAddress: normalizeMac(node["MAC"]),
                code: codeFromName(name),
                name: name,
                nodeAddress: address,
                deviceKey: deviceKey.isEmpty ? nil : deviceKey,
                deviceUUID: deviceUUID.isEmpty ? nil : deviceUUID,
                compositionData: "",
                elementCount: elementCount,
                updateTime: now,
                controlOnly: deviceKey.isEmpty))
        }
        guard !fixtures.isEmpty else { return nil }
        fixtures.sort { $0.nodeAddress < $1.nodeAddress }

        let score = SidusCandidate.Score(
            fixtureCount: fixtures.count,
            macCount: fixtures.filter { !$0.macAddress.isEmpty }.count,
            deviceKeyCount: fixtures.filter { $0.deviceKey != nil }.count)
        return SidusCandidate(
            domain: file.domain, relativePath: file.relativePath,
            meshName: mesh["meshName"]?.stringValue ?? "",
            meshUUID: nonEmpty(mesh["meshUUID"]) ?? nonEmpty(mesh["meshName"]) ?? "sidus-mesh",
            netKey: netKey, appKey: appKey, fixtures: fixtures, score: score)
    }

    public static func select(_ candidates: [SidusCandidate], selector: String) throws -> SidusCandidate {
        guard !candidates.isEmpty else {
            throw CLIError("no Sidus mesh JSON files with NetKey/AppKey metadata were found")
        }
        var pool = candidates
        if !selector.isEmpty {
            let needle = selector.lowercased()
            pool = candidates.filter {
                $0.meshName.lowercased().contains(needle)
                    || $0.meshUUID.lowercased().contains(needle)
                    || $0.relativePath.lowercased().contains(needle)
            }
            guard !pool.isEmpty else { throw CLIError("no Sidus mesh matched --mesh '\(selector)'") }
        }
        return pool.max { $0.score < $1.score }!
    }

    public static func chooseSourceAddresses(_ fixtures: [Fixture]) -> (source: Int, telink: Int) {
        var occupied = Set<Int>()
        for fixture in fixtures {
            let count = max(1, fixture.elementCount ?? 1)
            for offset in 0..<count { occupied.insert(fixture.nodeAddress + offset) }
        }
        let source = occupied.contains(3) ? firstFree(from: 4, excluding: occupied) : 3
        var withSource = occupied
        withSource.insert(source)
        let telink = withSource.contains(1) ? firstFree(from: 4, excluding: withSource) : 1
        return (source, telink)
    }

    public static func buildState(_ candidate: SidusCandidate, now: String) -> State {
        let (source, telink) = chooseSourceAddresses(candidate.fixtures)
        return State(
            schemaVersion: 1,
            syncedAt: now,
            source: Source(type: "sidus_ios_backup_import", extra: [
                "imported_at": .string(now),
                "mesh_name": .string(candidate.meshName),
                "mesh_uuid": .string(candidate.meshUUID),
                "mesh_file": .string(candidate.relativePath)
            ]),
            mesh: Mesh(uuid: candidate.meshUUID, netKey: candidate.netKey,
                       appKey: candidate.appKey, updateTime: now),
            fixtures: candidate.fixtures,
            runtime: Runtime(ivIndex: 0, sourceAddress: source, telinkSourceAddress: telink,
                             sequenceNext: 1, updatedAt: now, lastReservedBy: "sidus-import"),
            scenes: [:])
    }

    public static func result(state: State, targetPath: String) -> SidusImportResult {
        let summaries = state.fixtures.map {
            SidusImportFixtureSummary(
                name: Capabilities.label($0), address: $0.nodeAddress,
                macSuffix: MacAddress.suffix($0.macAddress), code: $0.code,
                controlOnly: $0.controlOnly ?? false)
        }
        return SidusImportResult(
            imported: true, targetPath: targetPath, fixtureCount: state.fixtures.count,
            fixtures: summaries, controlOnly: state.fixtures.contains { $0.controlOnly == true })
    }

    public static func humanLines(_ result: SidusImportResult) -> [String] {
        var lines: [String] = []
        let word = result.fixtureCount == 1 ? "fixture" : "fixtures"
        lines.append("imported Sidus mesh with \(result.fixtureCount) \(word) to \(result.targetPath)")
        for fixture in result.fixtures {
            let suffix = fixture.macSuffix.isEmpty ? "unknown" : fixture.macSuffix
            let mode = fixture.controlOnly ? "control-only" : "full"
            lines.append("\(fixture.name)\t\(fixture.address)\t...\(suffix)\t\(mode)")
        }
        return lines
    }

    // MARK: - Helpers

    private static func firstFree(from start: Int, excluding occupied: Set<Int>) -> Int {
        var candidate = start
        while candidate < 0x8000 {
            if !occupied.contains(candidate) { return candidate }
            candidate += 1
        }
        return start
    }

    private static func decodeJSON(_ data: Data) -> JSONValue? {
        // Strip a UTF-8 BOM (utf-8-sig) before decoding.
        var bytes = data
        if bytes.count >= 3, bytes[bytes.startIndex] == 0xEF,
            bytes[bytes.startIndex + 1] == 0xBB, bytes[bytes.startIndex + 2] == 0xBF {
            bytes = bytes.subdata(in: (bytes.startIndex + 3)..<bytes.endIndex)
        }
        return try? JSONDecoder().decode(JSONValue.self, from: bytes)
    }

    private static func nonEmpty(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue, !string.isEmpty else { return nil }
        return string
    }

    private static func normalizeHex(_ value: JSONValue?, bytes: Int?) -> String {
        let raw = value?.stringValue ?? value?.intValue.map(String.init) ?? ""
        let hex = raw.filter { $0.isHexDigit }.lowercased()
        if let bytes, hex.count != bytes * 2 { return "" }
        return hex
    }

    private static func normalizeMac(_ value: JSONValue?) -> String {
        let hex = (value?.stringValue ?? "").filter { $0.isHexDigit }.uppercased()
        guard hex.count == 12 else { return "" }
        return MacAddress.display(hex)
    }

    private static func parseAddress(_ value: JSONValue?) -> Int? {
        if let intValue = value?.intValue { return intValue }
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        return Int(text, radix: 16) ?? Int(text, radix: 10)
    }

    private static func codeFromName(_ name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return "" }
        let prefix = String(name[name.startIndex..<dash])
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !prefix.isEmpty, prefix.allSatisfy({ allowed.contains($0) }) else { return "" }
        return prefix
    }

    private static func deviceUUIDFromNode(_ node: [String: JSONValue]) -> String {
        for key in ["UUID", "uuid", "deviceUUID", "device_uuid"] {
            let hex = normalizeHex(node[key], bytes: 16)
            if !hex.isEmpty { return hex }
        }
        return ""
    }
}
