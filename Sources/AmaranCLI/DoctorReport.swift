import Foundation
import AmaranCore

// Codable result tree for `amaran doctor`, mirroring the zsh `--json` shape.

public struct DoctorFixtureSummary: Codable, Equatable {
    public let name: String
    public let address: Int
    public let macSuffix: String
    public let code: String
    enum CodingKeys: String, CodingKey { case name, address, macSuffix = "mac_suffix", code }
}

public struct DoctorRuntimeSummary: Codable, Equatable {
    public let sourceAddress: Int
    public let telinkSourceAddress: Int
    public let sequenceNext: Int
    public let lastReservedBy: String?
    enum CodingKeys: String, CodingKey {
        case sourceAddress = "source_address"
        case telinkSourceAddress = "telink_source_address"
        case sequenceNext = "sequence_next"
        case lastReservedBy = "last_reserved_by"
    }
}

public struct DoctorFixtureCheck: Codable, Equatable {
    public let name: String
    public let address: Int
    public let macSuffix: String
    public let hasMacAddress: Bool
    public let hasDeviceKey: Bool
    public let hasDeviceUUID: Bool
    public let configReady: Bool
    public let controlOnly: Bool
    public let hasCompositionData: Bool
    public let compositionDataBytes: Int
    enum CodingKeys: String, CodingKey {
        case name, address
        case macSuffix = "mac_suffix"
        case hasMacAddress = "has_mac_address"
        case hasDeviceKey = "has_device_key"
        case hasDeviceUUID = "has_device_uuid"
        case configReady = "config_ready"
        case controlOnly = "control_only"
        case hasCompositionData = "has_composition_data"
        case compositionDataBytes = "composition_data_bytes"
    }
}

public struct DoctorChecks: Codable, Equatable {
    public let meshHasNetKey: Bool
    public let meshHasAppKey: Bool
    public let runtimeSourceAddressValid: Bool
    public let runtimeTelinkSourceAddressValid: Bool
    public let runtimeSequenceAvailable: Bool
    public let fixtures: [DoctorFixtureCheck]
    enum CodingKeys: String, CodingKey {
        case meshHasNetKey = "mesh_has_net_key"
        case meshHasAppKey = "mesh_has_app_key"
        case runtimeSourceAddressValid = "runtime_source_address_valid"
        case runtimeTelinkSourceAddressValid = "runtime_telink_source_address_valid"
        case runtimeSequenceAvailable = "runtime_sequence_available"
        case fixtures
    }
}

public struct DoctorState: Codable, Equatable {
    public var path: String
    public var exists: Bool
    public var usable: Bool
    public var schemaVersion: Int?
    public var syncedAt: String?
    public var sourceType: String?
    public var fixtureCount: Int?
    public var fixtures: [DoctorFixtureSummary]?
    public var runtime: DoctorRuntimeSummary?
    public var checks: DoctorChecks?
    public var error: String?
    enum CodingKeys: String, CodingKey {
        case path, exists, usable
        case schemaVersion = "schema_version"
        case syncedAt = "synced_at"
        case sourceType = "source_type"
        case fixtureCount = "fixture_count"
        case fixtures, runtime, checks, error
    }
}

public struct DoctorPairing: Codable, Equatable {
    public let available: Bool
    public let createsFirstState: Bool
    public let canAddFixture: Bool
    public let requiresUnprovisionedFixture: Bool
    public let nextStep: String
    enum CodingKeys: String, CodingKey {
        case available
        case createsFirstState = "creates_first_state"
        case canAddFixture = "can_add_fixture"
        case requiresUnprovisionedFixture = "requires_unprovisioned_fixture"
        case nextStep = "next_step"
    }
}

public struct DoctorReadiness: Codable, Equatable {
    public let runtimeControlReady: Bool
    public let stableCommandsDirect: Bool
    public let stateSource: String?
    public let missing: [String]
    public let warnings: [String]
    public let nextStep: String
    public let pairing: DoctorPairing
    enum CodingKeys: String, CodingKey {
        case runtimeControlReady = "runtime_control_ready"
        case stableCommandsDirect = "stable_commands_direct"
        case stateSource = "state_source"
        case missing, warnings
        case nextStep = "next_step"
        case pairing
    }
}

public struct DoctorData: Codable, Equatable {
    public let state: DoctorState
    public let readiness: DoctorReadiness
}

public enum DoctorReport {
    public static func inspect(statePath: String, home: String = NSHomeDirectory()) -> DoctorData {
        let state = describeState(statePath: statePath, home: home)
        return DoctorData(state: state, readiness: describeReadiness(state))
    }

    // MARK: - State

    private static func describeState(statePath: String, home: String) -> DoctorState {
        let expanded = (statePath as NSString).expandingTildeInPath
        let display = displayPath(expanded, home: home)
        var result = DoctorState(path: display, exists: FileManager.default.fileExists(atPath: expanded),
                                 usable: false)
        guard result.exists else { return result }

        let loaded: State
        do {
            loaded = try StateStore.load(expanded)
        } catch {
            result.error = String(describing: error)
            return result
        }
        guard loaded.schemaVersion == 1 else {
            result.error = "unsupported state schema version: \(loaded.schemaVersion)"
            return result
        }

        result.usable = true
        result.schemaVersion = loaded.schemaVersion
        result.syncedAt = loaded.syncedAt
        result.sourceType = loaded.source.type
        result.fixtureCount = loaded.fixtures.count
        result.fixtures = loaded.fixtures.map {
            DoctorFixtureSummary(name: Capabilities.label($0), address: $0.nodeAddress,
                                 macSuffix: MacAddress.suffix($0.macAddress), code: $0.code)
        }
        result.runtime = DoctorRuntimeSummary(
            sourceAddress: loaded.runtime.sourceAddress,
            telinkSourceAddress: loaded.runtime.telinkSourceAddress,
            sequenceNext: loaded.runtime.sequenceNext,
            lastReservedBy: loaded.runtime.lastReservedBy)
        result.checks = DoctorChecks(
            meshHasNetKey: isHexBytes(loaded.mesh.netKey, byteCount: 16),
            meshHasAppKey: isHexBytes(loaded.mesh.appKey, byteCount: 16),
            runtimeSourceAddressValid: (1...0x7fff).contains(loaded.runtime.sourceAddress),
            runtimeTelinkSourceAddressValid: (1...0x7fff).contains(loaded.runtime.telinkSourceAddress),
            runtimeSequenceAvailable: (0...0x00ff_fffe).contains(loaded.runtime.sequenceNext),
            fixtures: loaded.fixtures.map(fixtureCheck))
        return result
    }

    private static func fixtureCheck(_ fixture: Fixture) -> DoctorFixtureCheck {
        let suffix = MacAddress.suffix(fixture.macAddress)
        let compositionBytes = isHexBytes(fixture.compositionData) ? fixture.compositionData.count / 2 : 0
        let hasDeviceKey = isHexBytes(fixture.deviceKey, byteCount: 16)
        return DoctorFixtureCheck(
            name: Capabilities.label(fixture),
            address: fixture.nodeAddress,
            macSuffix: suffix,
            hasMacAddress: !suffix.isEmpty,
            hasDeviceKey: hasDeviceKey,
            hasDeviceUUID: isHexBytes(fixture.deviceUUID, byteCount: 16),
            configReady: hasDeviceKey,
            controlOnly: (fixture.controlOnly ?? false) || !hasDeviceKey,
            hasCompositionData: compositionBytes > 0,
            compositionDataBytes: compositionBytes)
    }

    // MARK: - Readiness

    private static func describeReadiness(_ state: DoctorState) -> DoctorReadiness {
        let missing = missingRequirements(state)
        let warnings = readinessWarnings(state)

        let runtimeReady = missing.isEmpty
        let nextStep = runtimeReady
            ? "runtime commands are ready"
            : "run ./bin/amaran pair with an unprovisioned fixture, "
                + "or install a valid local state file with ./bin/amaran state-install"

        return DoctorReadiness(
            runtimeControlReady: runtimeReady,
            stableCommandsDirect: runtimeReady,
            stateSource: state.sourceType,
            missing: missing,
            warnings: warnings,
            nextStep: nextStep,
            pairing: DoctorPairing(
                available: true,
                createsFirstState: !state.exists,
                canAddFixture: state.usable,
                requiresUnprovisionedFixture: true,
                nextStep: pairingNextStep(state)))
    }

    private static func missingRequirements(_ state: DoctorState) -> [String] {
        guard state.usable else { return ["usable local state"] }
        let checks = state.checks
        let fixtureChecks = checks?.fixtures ?? []
        var missing: [String] = []
        if (state.fixtureCount ?? 0) < 1 { missing.append("at least one fixture") }
        if checks?.meshHasNetKey != true { missing.append("mesh NetKey in local state") }
        if checks?.meshHasAppKey != true { missing.append("mesh AppKey in local state") }
        if checks?.runtimeSourceAddressValid != true { missing.append("valid Config source address") }
        if checks?.runtimeTelinkSourceAddressValid != true { missing.append("valid Telink runtime source address") }
        if checks?.runtimeSequenceAvailable != true { missing.append("available sequence number") }
        if fixtureChecks.isEmpty { missing.append("fixture metadata") }
        return missing
    }

    private static func readinessWarnings(_ state: DoctorState) -> [String] {
        guard state.usable else { return [] }
        let fixtureChecks = state.checks?.fixtures ?? []
        guard !fixtureChecks.isEmpty else { return [] }
        var warnings: [String] = []
        if fixtureChecks.contains(where: { !$0.hasDeviceKey }) {
            warnings.append("fixture DeviceKey metadata missing; "
                + "Config diagnostics and node reset are unavailable for those fixtures")
        }
        if fixtureChecks.contains(where: { !$0.hasDeviceUUID }) {
            warnings.append("fixture device UUID metadata missing for imported fixtures")
        }
        if fixtureChecks.contains(where: { !$0.hasCompositionData }) {
            warnings.append("composition data missing until configure-test fetches it")
        }
        return warnings
    }

    private static func pairingNextStep(_ state: DoctorState) -> String {
        if state.usable {
            return "run ./bin/amaran pair --add --dry-run to scan before "
                + "adding another fixture to this studio state"
        } else if state.exists {
            return "repair/install valid local state before using pair --add"
        } else {
            return "run ./bin/amaran pair --dry-run before provisioning a factory-reset or unprovisioned fixture"
        }
    }

    // MARK: - Human output

    public static func humanLines(_ data: DoctorData) -> [String] {
        var lines: [String] = []
        let state = data.state
        var status = state.usable ? "usable" : "missing"
        if state.exists && !state.usable { status = "invalid" }
        lines.append("state \(status): \(state.path)")
        if let count = state.fixtureCount { lines.append("fixtures \(count)") }
        if let runtime = state.runtime {
            lines.append("runtime source \(runtime.sourceAddress), "
                + "telink_source \(runtime.telinkSourceAddress), sequence_next \(runtime.sequenceNext)")
        }
        lines.append("runtime \(data.readiness.runtimeControlReady ? "ready" : "not_ready")")
        if !data.readiness.runtimeControlReady, !data.readiness.missing.isEmpty {
            lines.append("missing " + data.readiness.missing.joined(separator: ", "))
        }
        if data.readiness.pairing.canAddFixture {
            lines.append("pairing add_ready")
        } else if state.exists {
            lines.append("pairing blocked_by_invalid_state")
        } else {
            lines.append("pairing create_ready")
        }
        lines.append("pairing_next \(data.readiness.pairing.nextStep)")
        for warning in data.readiness.warnings { lines.append("warning \(warning)") }
        lines.append("next \(data.readiness.nextStep)")
        return lines
    }

    // MARK: - Helpers

    private static func isHexBytes(_ value: String?, byteCount: Int? = nil) -> Bool {
        guard let value, !value.isEmpty, value.count % 2 == 0,
            value.allSatisfy({ $0.isHexDigit }) else { return false }
        if let byteCount, value.count != byteCount * 2 { return false }
        return true
    }

    private static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
