import Foundation
import AmaranCore

public struct InstallFixtureSummary: Codable, Equatable {
    public let name: String
    public let address: Int?
    public let macSuffix: String
    public let code: String?
    enum CodingKeys: String, CodingKey { case name, address, macSuffix = "mac_suffix", code }
}

public struct InstallResult: Codable, Equatable {
    public let installed: Bool
    public let sourcePath: String
    public let targetPath: String
    public let schemaVersion: Int?
    public let fixtureCount: Int
    public let fixtures: [InstallFixtureSummary]
    enum CodingKeys: String, CodingKey {
        case installed
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case schemaVersion = "schema_version"
        case fixtureCount = "fixture_count"
        case fixtures
    }
}

/// `state-install` validation + summary, ported from the zsh
/// `validate_state_payload`. Stricter than `state-join`: every fixture must carry
/// a DeviceKey and device UUID. The source payload is written verbatim.
public enum StateInstall {
    public static func validate(_ payload: JSONValue) throws {
        guard let root = payload.objectValue else {
            throw CLIError("state file must contain a JSON object")
        }
        guard root["schema_version"]?.intValue == 1 else {
            let raw = root["schema_version"].map { describe($0) } ?? "None"
            throw CLIError("unsupported state schema version: \(raw)")
        }
        guard let mesh = root["mesh"]?.objectValue else {
            throw CLIError("state file is missing mesh data")
        }
        guard let fixtures = root["fixtures"]?.arrayValue else {
            throw CLIError("state file is missing fixtures data")
        }
        guard let runtime = root["runtime"]?.objectValue else {
            throw CLIError("state file is missing runtime data")
        }

        for field in ["uuid", "net_key", "app_key"] {
            if !isTruthy(mesh[field]) {
                throw CLIError("state mesh data missing field: \(field)")
            }
        }
        guard isHexBytes(mesh["net_key"]?.stringValue, bytes: 16) else {
            throw CLIError("state mesh data has invalid net_key")
        }
        guard isHexBytes(mesh["app_key"]?.stringValue, bytes: 16) else {
            throw CLIError("state mesh data has invalid app_key")
        }
        guard !fixtures.isEmpty else { throw CLIError("state file has no fixtures") }

        for (offset, item) in fixtures.enumerated() {
            let index = offset + 1
            guard let fixture = item.objectValue else {
                throw CLIError("state fixture #\(index) must be a JSON object")
            }
            for field in ["node_address", "device_key", "device_uuid"] {
                if isEmpty(fixture[field]) {
                    throw CLIError("state fixture #\(index) missing field: \(field)")
                }
            }
            guard let address = fixture["node_address"]?.intValue else {
                throw CLIError("state fixture #\(index) has invalid node_address")
            }
            guard (1...0x7FFF).contains(address) else {
                throw CLIError("state fixture #\(index) has non-unicast node_address")
            }
            guard isHexBytes(fixture["device_key"]?.stringValue, bytes: 16) else {
                throw CLIError("state fixture #\(index) has invalid device_key")
            }
            guard isHexBytes(fixture["device_uuid"]?.stringValue, bytes: 16) else {
                throw CLIError("state fixture #\(index) has invalid device_uuid")
            }
            if let comp = fixture["composition_data"], !isEmpty(comp) {
                guard let s = comp.stringValue, !s.isEmpty, s.count % 2 == 0,
                    s.allSatisfy({ $0.isHexDigit }) else {
                    throw CLIError("state fixture #\(index) has invalid composition_data")
                }
            }
            let mac = (fixture["mac_address"]?.stringValue ?? "").filter { $0.isHexDigit }.uppercased()
            if !mac.isEmpty, mac.count != 12 {
                throw CLIError("state fixture #\(index) has invalid mac_address")
            }
        }

        guard inRange(runtime["iv_index"], 0, 0xFFFF_FFFF) else {
            throw CLIError("state runtime data has invalid iv_index")
        }
        guard inRange(runtime["source_address"], 1, 0x7FFF) else {
            throw CLIError("state runtime data has invalid source_address")
        }
        guard inRange(runtime["telink_source_address"], 1, 0x7FFF) else {
            throw CLIError("state runtime data has invalid telink_source_address")
        }
        guard inRange(runtime["sequence_next"], 0, 0x00FF_FFFE) else {
            throw CLIError("state runtime data has invalid sequence_next")
        }
    }

    public static func summary(payload: JSONValue, sourcePath: String, targetPath: String) -> InstallResult {
        let fixtures = payload["fixtures"]?.arrayValue ?? []
        let summaries = fixtures.map { item -> InstallFixtureSummary in
            InstallFixtureSummary(
                name: label(item),
                address: item["node_address"]?.intValue,
                macSuffix: MacAddress.suffix(item["mac_address"]?.stringValue),
                code: item["code"]?.stringValue)
        }
        return InstallResult(
            installed: true, sourcePath: sourcePath, targetPath: targetPath,
            schemaVersion: payload["schema_version"]?.intValue,
            fixtureCount: fixtures.count, fixtures: summaries)
    }

    public static func humanLines(_ result: InstallResult) -> [String] {
        var lines: [String] = []
        let word = result.fixtureCount == 1 ? "fixture" : "fixtures"
        lines.append("installed \(result.fixtureCount) \(word) to \(result.targetPath)")
        for fixture in result.fixtures {
            let suffix = fixture.macSuffix.isEmpty ? "unknown" : fixture.macSuffix
            lines.append("\(fixture.name)\t\(fixture.address.map(String.init) ?? "")\t...\(suffix)")
        }
        return lines
    }

    // MARK: - Helpers

    private static func label(_ fixture: JSONValue) -> String {
        if let friendly = fixture["friendly_name"]?.stringValue, !friendly.isEmpty { return friendly }
        if let name = fixture["name"]?.stringValue, !name.isEmpty { return name }
        let suffix = MacAddress.suffix(fixture["mac_address"]?.stringValue)
        if let code = fixture["code"]?.stringValue, !code.isEmpty, !suffix.isEmpty {
            return "\(code)-\(suffix)"
        }
        if !suffix.isEmpty { return suffix }
        return "fixture-\(fixture["node_address"]?.intValue.map(String.init) ?? "unknown")"
    }

    private static func isEmpty(_ value: JSONValue?) -> Bool {
        switch value {
        case .none, .some(.null): return true
        case .some(.string(let s)): return s.isEmpty
        default: return false
        }
    }

    private static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .some(.string(let s)): return !s.isEmpty
        case .some(.int(let i)): return i != 0
        case .some(.bool(let b)): return b
        case .none, .some(.null): return false
        default: return true
        }
    }

    private static func isHexBytes(_ value: String?, bytes: Int) -> Bool {
        guard let value else { return false }
        return value.count == bytes * 2 && value.allSatisfy { $0.isHexDigit }
    }

    private static func inRange(_ value: JSONValue?, _ lo: Int, _ hi: Int) -> Bool {
        guard let parsed = value?.intValue else { return false }
        return lo <= parsed && parsed <= hi
    }

    private static func describe(_ value: JSONValue) -> String {
        value.intValue.map(String.init) ?? value.stringValue ?? "None"
    }
}
