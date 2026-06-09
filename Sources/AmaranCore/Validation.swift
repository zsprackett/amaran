import Foundation

/// Error thrown when a `State` fails validation.
public enum ValidationError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

/// State validation, ported from `NativeMeshState.validatePayload`.
public enum Validation {
    public static let schemaVersion = 1
    public static let maxUnicast = 0x7fff
    public static let maxSequence = 0x00ff_fffe
    public static let maxIVIndex = 0xffff_ffff

    public static func validate(_ state: State) throws {
        guard state.schemaVersion == schemaVersion else {
            throw ValidationError.invalid("unsupported schema_version")
        }

        try validateMesh(state.mesh)
        try validateFixtures(state.fixtures)
        try validateRuntime(state.runtime)
    }

    private static func validateMesh(_ mesh: Mesh) throws {
        guard !mesh.uuid.isEmpty else {
            throw ValidationError.invalid("mesh missing uuid")
        }
        try requireHex(mesh.netKey, bytes: 16, label: "mesh net_key")
        try requireHex(mesh.appKey, bytes: 16, label: "mesh app_key")
    }

    private static func validateFixtures(_ fixtures: [Fixture]) throws {
        guard !fixtures.isEmpty else {
            throw ValidationError.invalid("missing fixtures")
        }

        var occupied = Set<Int>()
        for (index, fixture) in fixtures.enumerated() {
            let position = index + 1
            guard (1...maxUnicast).contains(fixture.nodeAddress) else {
                throw ValidationError.invalid("fixture \(position) has invalid node_address")
            }
            if !fixture.macAddress.isEmpty {
                guard (try? MacAddress.normalize(fixture.macAddress)) != nil else {
                    throw ValidationError.invalid("fixture \(position) has invalid mac_address")
                }
            }
            try optionalHex(fixture.deviceKey, bytes: 16, label: "fixture \(position) device_key")
            try optionalHex(fixture.deviceUUID, bytes: 16, label: "fixture \(position) device_uuid")
            try optionalEvenHex(fixture.compositionData, label: "fixture \(position) composition_data")

            let elementCount: Int
            do {
                elementCount = try Composition.derivedElementCount(
                    compositionHex: fixture.compositionData,
                    declaredElementCount: fixture.elementCount
                )
            } catch {
                throw ValidationError.invalid("fixture \(position) has invalid element_count")
            }

            for offset in 0..<elementCount {
                let address = fixture.nodeAddress + offset
                guard address <= maxUnicast else {
                    throw ValidationError.invalid("fixture \(position) element address exceeds unicast range")
                }
                guard !occupied.contains(address) else {
                    throw ValidationError.invalid("duplicate fixture element address \(address)")
                }
                occupied.insert(address)
            }
        }
    }

    private static func validateRuntime(_ runtime: Runtime) throws {
        guard (0...maxIVIndex).contains(runtime.ivIndex) else {
            throw ValidationError.invalid("runtime has invalid iv_index")
        }
        guard (1...maxUnicast).contains(runtime.sourceAddress) else {
            throw ValidationError.invalid("runtime has invalid source_address")
        }
        guard (1...maxUnicast).contains(runtime.telinkSourceAddress) else {
            throw ValidationError.invalid("runtime has invalid telink_source_address")
        }
        guard (0...maxSequence).contains(runtime.sequenceNext) else {
            throw ValidationError.invalid("runtime has invalid sequence_next")
        }
    }

    private static func requireHex(_ value: String, bytes: Int, label: String) throws {
        guard value.count == bytes * 2, value.allSatisfy({ $0.isHexDigit }) else {
            throw ValidationError.invalid("\(label) must be \(bytes) bytes of hex")
        }
    }

    private static func optionalHex(_ value: String?, bytes: Int, label: String) throws {
        guard let value, !value.isEmpty else { return }
        try requireHex(value, bytes: bytes, label: label)
    }

    private static func optionalEvenHex(_ value: String?, label: String) throws {
        guard let value, !value.isEmpty else { return }
        guard value.count % 2 == 0, value.allSatisfy({ $0.isHexDigit }) else {
            throw ValidationError.invalid("\(label) must be hex")
        }
    }
}
