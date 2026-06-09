import Foundation

/// Builds and persists a single unsegmented device-key access Proxy PDU,
/// returning the network PDU plus the upper-transport byte count for metadata.
private func buildDeviceAccessReservation(
    context: inout NativeReservationContext,
    accessMessage: [UInt8],
    sourceAddress: Int,
    sequenceNext: Int,
    lastReservedBy: String
) throws -> DeviceAccessProxyPduResult {
    guard let deviceKey = context.deviceKey else {
        throw AmaranHelperError.invalidState("fixture is missing device key")
    }
    let built = try NativeMeshCrypto.deviceAccessProxyPdu(
        context: MeshMessageContext(
            ivIndex: UInt32(context.ivIndex),
            sequence: UInt32(sequenceNext),
            source: UInt16(sourceAddress),
            destination: UInt16(context.destination)
        ),
        ttl: 10,
        netKey: context.netKey,
        deviceKey: deviceKey,
        accessMessage: accessMessage
    )
    try context.persist(
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext + 1,
        lastReservedBy: lastReservedBy
    )
    return built
}

func reserveNativeConfigCompositionGetProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    var context = try NativeReservationContext(statePath: statePath, nodeID: nodeID, requireDeviceKey: true)
    let sourceAddress = try context.runtimeSourceAddress()
    let sequenceNext = try context.sequenceNext()
    let accessMessage = NativeMeshConfig.configCompositionDataGet()
    let built = try buildDeviceAccessReservation(
        context: &context,
        accessMessage: accessMessage,
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext,
        lastReservedBy: "config-composition-get-test"
    )

    let sendMetadata: [String: Any] = [
        "address": context.destination,
        "fixture": fixtureLabel(context.fixture),
        "iv_index": context.ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_next": sequenceNext + 1,
        "opcode": "Config Composition Data Get",
        "config_command": "composition_data_get",
        "page": 0,
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count
    ]

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: sendMetadata
    )
}

func reserveNativeConfigAppKeyGetProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    var context = try NativeReservationContext(statePath: statePath, nodeID: nodeID, requireDeviceKey: true)
    let sourceAddress = try context.runtimeSourceAddress()
    let sequenceNext = try context.sequenceNext()
    let accessMessage = try NativeMeshConfig.configAppKeyGet(netKeyIndex: 0)
    let built = try buildDeviceAccessReservation(
        context: &context,
        accessMessage: accessMessage,
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext,
        lastReservedBy: "config-appkey-get-test"
    )

    let sendMetadata: [String: Any] = [
        "address": context.destination,
        "fixture": fixtureLabel(context.fixture),
        "iv_index": context.ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_next": sequenceNext + 1,
        "opcode": "Config AppKey Get",
        "config_command": "appkey_get",
        "net_key_index": 0,
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count
    ]

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: sendMetadata
    )
}

func reserveNativeConfigAppKeyAddProxyPdus(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPduSequence {
    var context = try NativeReservationContext(statePath: statePath, nodeID: nodeID, requireDeviceKey: true)
    guard let deviceKey = context.deviceKey else {
        throw AmaranHelperError.invalidState("fixture is missing device key")
    }
    let sourceAddress = try context.runtimeSourceAddress()
    let sequenceNext = try context.sequenceNext()
    let accessMessage = try NativeMeshConfig.configAppKeyAdd(
        netKeyIndex: 0,
        appKeyIndex: 0,
        appKey: context.appKey
    )
    let built = try NativeMeshCrypto.segmentedDeviceAccessProxyPdus(
        context: MeshMessageContext(
            ivIndex: UInt32(context.ivIndex),
            sequence: UInt32(sequenceNext),
            source: UInt16(sourceAddress),
            destination: UInt16(context.destination)
        ),
        ttl: 10,
        netKey: context.netKey,
        deviceKey: deviceKey,
        accessMessage: accessMessage
    )
    guard sequenceNext + built.proxyPdus.count <= 0x00ff_ffff else {
        throw AmaranHelperError.invalidState("runtime sequence_next does not have room for segmented config send")
    }

    let nextSequence = sequenceNext + built.proxyPdus.count
    try context.persist(
        sourceAddress: sourceAddress,
        sequenceNext: nextSequence,
        lastReservedBy: "config-appkey-add-test"
    )

    let sendMetadata = appKeyAddMetadata(
        context: context,
        built: built,
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext,
        accessBytes: accessMessage.count
    )

    return NativePreparedProxyPduSequence(
        proxyPdus: built.proxyPdus,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: sendMetadata,
        expectedSegmentAckSeqZero: built.lowerTransport.seqZero,
        expectedSegmentAckSegN: built.lowerTransport.segN
    )
}

func reserveNativeConfigModelAppBindProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    var context = try NativeReservationContext(statePath: statePath, nodeID: nodeID, requireDeviceKey: true)
    guard let compositionHex = jsonString(context.fixture["composition_data"]) else {
        throw AmaranHelperError.invalidState("fixture is missing composition data")
    }
    let composition = try NativeMeshConfig.compositionDataPage0(
        NativeMeshCrypto.bytes(hex: compositionHex)
    )
    guard let target = composition.firstVendorModelBindingTarget else {
        throw AmaranHelperError.invalidState("fixture composition data has no vendor model to bind")
    }
    let elementAddress = context.destination + target.elementIndex
    guard (1...0x7fff).contains(elementAddress) else {
        throw AmaranHelperError.invalidState("computed element address is not a unicast address")
    }

    let sourceAddress = try context.runtimeSourceAddress()
    let sequenceNext = try context.sequenceNext()
    let accessMessage = try NativeMeshConfig.configModelAppBind(
        elementAddress: UInt16(elementAddress),
        appKeyIndex: 0,
        modelIdentifier: .vendor(
            companyIdentifier: target.model.companyIdentifier,
            modelIdentifier: target.model.modelIdentifier
        )
    )
    let built = try buildDeviceAccessReservation(
        context: &context,
        accessMessage: accessMessage,
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext,
        lastReservedBy: "config-model-app-bind-test"
    )

    let sendMetadata = modelAppBindMetadata(
        context: context,
        built: built,
        composition: composition,
        target: target,
        info: ModelAppBindMetadataInput(
            sourceAddress: sourceAddress,
            sequenceNext: sequenceNext,
            elementAddress: elementAddress,
            accessBytes: accessMessage.count
        )
    )

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: sendMetadata
    )
}

private struct ModelAppBindMetadataInput {
    let sourceAddress: Int
    let sequenceNext: Int
    let elementAddress: Int
    let accessBytes: Int
}

private func modelAppBindMetadata(
    context: NativeReservationContext,
    built: DeviceAccessProxyPduResult,
    composition: NativeMeshCompositionDataPage0,
    target: (elementIndex: Int, model: NativeMeshVendorModel),
    info: ModelAppBindMetadataInput
) -> [String: Any] {
    [
        "address": context.destination,
        "fixture": fixtureLabel(context.fixture),
        "iv_index": context.ivIndex,
        "source": info.sourceAddress,
        "ttl": 10,
        "sequence": info.sequenceNext,
        "sequence_next": info.sequenceNext + 1,
        "opcode": "Config Model App Bind",
        "config_command": "model_app_bind",
        "app_key_index": 0,
        "element_address": info.elementAddress,
        "element_index": target.elementIndex,
        "access_bytes": info.accessBytes,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count,
        "composition_cid": String(format: "%04x", composition.cid),
        "model_company_id": String(format: "%04x", target.model.companyIdentifier),
        "model_id": String(format: "%04x", target.model.modelIdentifier)
    ]
}

private func appKeyAddMetadata(
    context: NativeReservationContext,
    built: SegmentedDeviceAccessProxyPduResult,
    sourceAddress: Int,
    sequenceNext: Int,
    accessBytes: Int
) -> [String: Any] {
    [
        "address": context.destination,
        "fixture": fixtureLabel(context.fixture),
        "iv_index": context.ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_last": sequenceNext + built.proxyPdus.count - 1,
        "sequence_next": sequenceNext + built.proxyPdus.count,
        "opcode": "Config AppKey Add",
        "config_command": "appkey_add",
        "net_key_index": 0,
        "app_key_index": 0,
        "access_bytes": accessBytes,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count,
        "segment_count": built.proxyPdus.count,
        "segment_lengths": built.proxyPdus.map(\.count),
        "seq_zero": Int(built.lowerTransport.seqZero),
        "seg_n": Int(built.lowerTransport.segN)
    ]
}

func reserveNativeConfigNodeResetProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    var context = try NativeReservationContext(statePath: statePath, nodeID: nodeID, requireDeviceKey: true)
    let sourceAddress = try context.runtimeSourceAddress()
    let sequenceNext = try context.sequenceNext()
    let accessMessage = NativeMeshConfig.configNodeReset()
    let built = try buildDeviceAccessReservation(
        context: &context,
        accessMessage: accessMessage,
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext,
        lastReservedBy: "config-node-reset-test"
    )

    let sendMetadata: [String: Any] = [
        "address": context.destination,
        "fixture": fixtureLabel(context.fixture),
        "iv_index": context.ivIndex,
        "source": sourceAddress,
        "ttl": 10,
        "sequence": sequenceNext,
        "sequence_next": sequenceNext + 1,
        "opcode": "Config Node Reset",
        "config_command": "node_reset",
        "destructive": true,
        "access_bytes": accessMessage.count,
        "upper_transport_bytes": built.upperTransport.upperTransportPdu.count
    ]

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: sendMetadata
    )
}
