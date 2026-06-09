import Foundation

/// Mutable state-file context loaded by the reservation helpers. Bundles the
/// decoded JSON payload, the selected fixture, derived keys, and the runtime
/// counters needed to build and persist a Proxy PDU reservation.
struct NativeReservationContext {
    let url: URL
    var payload: [String: Any]
    let fixture: [String: Any]
    let destination: Int
    var runtime: [String: Any]
    let ivIndex: Int
    let netKey: [UInt8]
    let appKey: [UInt8]
    let networkKeys: MeshKeyMaterial
    let appAid: UInt8
    var deviceKey: [UInt8]?

    /// Loads and validates the state file, selecting the target fixture and
    /// deriving the cryptographic material common to every reservation.
    init(statePath: String, nodeID: String?, requireDeviceKey: Bool) throws {
        let url = URL(fileURLWithPath: statePath)
        let data = try Data(contentsOf: url)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AmaranHelperError.invalidState("state file must contain a JSON object")
        }
        guard jsonInt(payload["schema_version"]) == 1 else {
            throw AmaranHelperError.invalidState("unsupported state schema version")
        }
        guard let mesh = payload["mesh"] as? [String: Any] else {
            throw AmaranHelperError.invalidState("state file is missing mesh data")
        }
        guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
            throw AmaranHelperError.invalidState("state file is missing fixtures")
        }
        guard let netKeyHex = jsonString(mesh["net_key"]), let appKeyHex = jsonString(mesh["app_key"]) else {
            throw AmaranHelperError.invalidState("state mesh data missing keys")
        }

        let fixture = try selectFixture(fixtures, nodeID: nodeID)
        guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
            throw AmaranHelperError.invalidState("fixture has invalid node address")
        }

        var deviceKey: [UInt8]?
        if requireDeviceKey {
            guard let deviceKeyHex = jsonString(fixture["device_key"]) else {
                throw AmaranHelperError.invalidState("fixture is missing device key")
            }
            deviceKey = try NativeMeshCrypto.bytes(hex: deviceKeyHex)
        }

        let runtime = payload["runtime"] as? [String: Any] ?? [:]
        let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
        let appKey = try NativeMeshCrypto.bytes(hex: appKeyHex)

        self.url = url
        self.payload = payload
        self.fixture = fixture
        self.destination = destination
        self.runtime = runtime
        self.ivIndex = jsonInt(runtime["iv_index"]) ?? 0
        self.netKey = netKey
        self.appKey = appKey
        self.networkKeys = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
        self.appAid = try NativeMeshCrypto.k4(n: appKey)
        self.deviceKey = deviceKey
    }

    /// The runtime CLI-owned source address for this destination.
    func runtimeSourceAddress() throws -> Int {
        guard let fixtures = payload["fixtures"] as? [[String: Any]] else {
            throw AmaranHelperError.invalidState("state file is missing fixtures")
        }
        return try nativeRuntimeSourceAddress(
            runtime: runtime,
            fixtures: fixtures,
            destination: destination
        )
    }

    /// The next sequence number, validated to be within range.
    func sequenceNext() throws -> Int {
        let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
        guard (0...0x00ff_fffe).contains(sequenceNext) else {
            throw AmaranHelperError.invalidState("runtime sequence_next is exhausted or invalid")
        }
        return sequenceNext
    }

    /// Persists the runtime block to disk with restrictive permissions.
    mutating func persist(
        sourceAddress: Int,
        sequenceNext: Int,
        lastReservedBy: String,
        sourceRole: NativeSourceRole = .cliOwned
    ) throws {
        runtime["iv_index"] = ivIndex
        switch sourceRole {
        case .cliOwned:
            runtime["source_address"] = sourceAddress
        case .telinkRuntime:
            runtime["telink_source_address"] = sourceAddress
        }
        runtime["sequence_next"] = sequenceNext
        runtime["updated_at"] = isoTimestamp()
        runtime["last_reserved_by"] = lastReservedBy
        payload["runtime"] = runtime

        let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func makeDecodeMaterial() -> NativeDecodeMaterial {
        NativeDecodeMaterial(
            networkKeys: networkKeys,
            appKey: appKey,
            appAid: appAid,
            deviceKey: deviceKey,
            ivIndex: UInt32(ivIndex)
        )
    }
}

func peekNativeSequenceNext(statePath: String) throws -> Int {
    let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AmaranHelperError.invalidState("state file must contain a JSON object")
    }
    let runtime = payload["runtime"] as? [String: Any] ?? [:]
    return jsonInt(runtime["sequence_next"]) ?? 1
}

func reserveNativeRuntimeSequence(
    statePath: String,
    lastReservedBy: String
) throws -> (sequence: Int, sequenceNext: Int) {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AmaranHelperError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw AmaranHelperError.invalidState("unsupported state schema version")
    }

    var runtime = payload["runtime"] as? [String: Any] ?? [:]
    let sequenceNext = jsonInt(runtime["sequence_next"]) ?? 1
    guard (0...0x00ff_fffe).contains(sequenceNext) else {
        throw AmaranHelperError.invalidState("runtime sequence_next is exhausted or invalid")
    }

    runtime["sequence_next"] = sequenceNext + 1
    runtime["updated_at"] = isoTimestamp()
    runtime["last_reserved_by"] = lastReservedBy
    payload["runtime"] = runtime

    let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statePath)

    return (sequenceNext, sequenceNext + 1)
}

func makeNativeProvisioningRun(
    attentionDuration: Int,
    statePath: String,
    addToExistingState: Bool = false,
    unicastAddress: UInt16 = 2,
    sourceAddress: UInt16 = 3
) throws -> NativeProvisioningRun {
    guard (0...255).contains(attentionDuration) else {
        throw AmaranHelperError.invalidState("attention duration must be 0..255")
    }
    if addToExistingState {
        return try makeAppendingProvisioningRun(attentionDuration: attentionDuration, statePath: statePath)
    }

    guard (1...0x7fff).contains(Int(unicastAddress)) else {
        throw AmaranHelperError.invalidState("provisioned node address must be a unicast address")
    }
    guard (1...0x7fff).contains(Int(sourceAddress)), sourceAddress != unicastAddress else {
        throw AmaranHelperError.invalidState("provisioner source address must be a different unicast address")
    }
    guard !FileManager.default.fileExists(atPath: statePath) else {
        throw AmaranHelperError.invalidState(
            "state file already exists; use add mode or set AMARAN_CLI_STATE_PATH before provisioning"
        )
    }
    return NativeProvisioningRun(
        attentionDuration: attentionDuration,
        statePath: statePath,
        appendsToExistingState: false,
        meshUUID: UUID().uuidString,
        netKey: try NativeMeshProvisioning.generateProvisioningRandom(),
        appKey: try NativeMeshProvisioning.generateProvisioningRandom(),
        keyIndex: 0,
        flags: 0,
        ivIndex: 0,
        unicastAddress: unicastAddress,
        sourceAddress: sourceAddress,
        provisionerKeyPair: try NativeMeshProvisioning.generateProvisionerKeyPair(),
        provisionerRandom: try NativeMeshProvisioning.generateProvisioningRandom()
    )
}

private func makeAppendingProvisioningRun(
    attentionDuration: Int,
    statePath: String
) throws -> NativeProvisioningRun {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: statePath))
    } catch {
        throw AmaranHelperError.invalidState("existing state file is required before adding a fixture")
    }
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AmaranHelperError.invalidState("state file must contain a JSON object")
    }
    do {
        try NativeMeshState.validatePayload(payload)
    } catch {
        throw AmaranHelperError.invalidState("existing state is not usable for fixture add: \(error)")
    }
    guard let mesh = payload["mesh"] as? [String: Any],
          let fixtures = payload["fixtures"] as? [[String: Any]],
          let runtime = payload["runtime"] as? [String: Any],
          let meshUUID = jsonString(mesh["uuid"]),
          let netKeyHex = jsonString(mesh["net_key"]),
          let appKeyHex = jsonString(mesh["app_key"]) else {
        throw AmaranHelperError.invalidState("existing state is missing mesh data")
    }
    guard let ivIndex = jsonInt(runtime["iv_index"]), (0...0xffff_ffff).contains(ivIndex) else {
        throw AmaranHelperError.invalidState("existing state runtime has invalid iv_index")
    }
    let nextAddress = try nextProvisioningUnicastAddress(fixtures: fixtures, runtime: runtime)
    let selectedSourceAddress = try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: Int(nextAddress)
    )

    return NativeProvisioningRun(
        attentionDuration: attentionDuration,
        statePath: statePath,
        appendsToExistingState: true,
        meshUUID: meshUUID,
        netKey: try NativeMeshCrypto.bytes(hex: netKeyHex),
        appKey: try NativeMeshCrypto.bytes(hex: appKeyHex),
        keyIndex: 0,
        flags: 0,
        ivIndex: UInt32(ivIndex),
        unicastAddress: nextAddress,
        sourceAddress: UInt16(selectedSourceAddress),
        provisionerKeyPair: try NativeMeshProvisioning.generateProvisionerKeyPair(),
        provisionerRandom: try NativeMeshProvisioning.generateProvisioningRandom()
    )
}
