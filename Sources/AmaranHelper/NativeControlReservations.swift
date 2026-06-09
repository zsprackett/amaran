import Foundation

func reserveNativeAccessProxyPdu(
    statePath: String,
    nodeID: String?,
    accessMessage: [UInt8],
    metadata: [String: Any],
    lastReservedBy: String,
    sourceRole: NativeSourceRole = .cliOwned
) throws -> NativePreparedProxyPdu {
    var context = try NativeReservationContext(statePath: statePath, nodeID: nodeID, requireDeviceKey: false)
    guard let fixtures = context.payload["fixtures"] as? [[String: Any]] else {
        throw AmaranHelperError.invalidState("state file is missing fixtures")
    }

    let sourceAddress: Int
    switch sourceRole {
    case .cliOwned:
        sourceAddress = try nativeRuntimeSourceAddress(
            runtime: context.runtime, fixtures: fixtures, destination: context.destination
        )
    case .telinkRuntime:
        sourceAddress = try nativeTelinkSourceAddress(
            runtime: context.runtime, fixtures: fixtures, destination: context.destination
        )
    }

    let sequenceNext = try context.sequenceNext()
    let built = try NativeMeshCrypto.applicationAccessProxyPdu(
        context: MeshMessageContext(
            ivIndex: UInt32(context.ivIndex),
            sequence: UInt32(sequenceNext),
            source: UInt16(sourceAddress),
            destination: UInt16(context.destination)
        ),
        ttl: 10,
        netKey: context.netKey,
        applicationKey: context.appKey,
        accessMessage: accessMessage
    )

    try context.persist(
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext + 1,
        lastReservedBy: lastReservedBy,
        sourceRole: sourceRole
    )

    var sendMetadata = metadata
    sendMetadata["address"] = context.destination
    sendMetadata["fixture"] = fixtureLabel(context.fixture)
    sendMetadata["iv_index"] = context.ivIndex
    sendMetadata["sequence"] = sequenceNext
    sendMetadata["sequence_next"] = sequenceNext + 1
    sendMetadata["source"] = sourceAddress
    sendMetadata["ttl"] = 10

    return NativePreparedProxyPdu(
        proxyPdu: built.network.proxyPdu,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: sendMetadata
    )
}

func reserveNativeSigOnOffProxyPdu(
    statePath: String,
    nodeID: String?,
    turnOn: Bool
) throws -> NativePreparedProxyPdu {
    let sequenceNext = try peekNativeSequenceNext(statePath: statePath)
    let tid = UInt8(UInt32(sequenceNext) & 0xff)
    return try reserveNativeAccessProxyPdu(
        statePath: statePath,
        nodeID: nodeID,
        accessMessage: [0x82, 0x03, turnOn ? 0x01 : 0x00, tid],
        metadata: [
            "opcode": "Generic OnOff Set Unacknowledged",
            "onoff": turnOn
        ],
        lastReservedBy: "sig-onoff-test"
    )
}

func reserveNativeControlProxyPdu(
    statePath: String,
    nodeID: String?,
    command: NativeTelinkControlCommand
) throws -> NativePreparedProxyPdu {
    try reserveNativeAccessProxyPdu(
        statePath: statePath,
        nodeID: nodeID,
        accessMessage: command.accessMessage(),
        metadata: command.metadata(),
        lastReservedBy: "control-test",
        sourceRole: .telinkRuntime
    )
}

func reserveNativeControlProxyPdus(
    statePath: String,
    nodeID: String?,
    commands: [NativeTelinkControlCommand]
) throws -> NativePreparedProxyPduSequence {
    guard !commands.isEmpty else {
        throw AmaranHelperError.invalidState("control sequence requires at least one command")
    }

    let prepared = try commands.map { command in
        try reserveNativeAccessProxyPdu(
            statePath: statePath,
            nodeID: nodeID,
            accessMessage: command.accessMessage(),
            metadata: command.metadata(),
            lastReservedBy: "control-sequence",
            sourceRole: .telinkRuntime
        )
    }

    guard let first = prepared.first else {
        throw AmaranHelperError.invalidState("control sequence requires at least one prepared PDU")
    }

    return NativePreparedProxyPduSequence(
        proxyPdus: prepared.map(\.proxyPdu),
        requiredProxyNetworkId: first.requiredProxyNetworkId,
        decodeMaterial: first.decodeMaterial,
        metadata: controlSequenceMetadata(prepared: prepared, first: first),
        expectedSegmentAckSeqZero: nil,
        expectedSegmentAckSegN: nil
    )
}

private func controlSequenceMetadata(
    prepared: [NativePreparedProxyPdu],
    first: NativePreparedProxyPdu
) -> [String: Any] {
    var metadata: [String: Any] = [
        "control_command": "sequence",
        "control_count": prepared.count,
        "control_commands": prepared.map(\.metadata)
    ]
    for key in ["address", "fixture", "iv_index", "source", "ttl"] {
        if let value = first.metadata[key] {
            metadata[key] = value
        }
    }
    if let firstSequence = first.metadata["sequence"] {
        metadata["sequence"] = firstSequence
    }
    if let lastSequenceNext = prepared.last?.metadata["sequence_next"] {
        metadata["sequence_next"] = lastSequenceNext
    }
    return metadata
}

func reserveNativeStatusProxyPdu(
    statePath: String,
    nodeID: String?
) throws -> NativePreparedProxyPdu {
    try reserveNativeAccessProxyPdu(
        statePath: statePath,
        nodeID: nodeID,
        accessMessage: NativeTelinkControlCommand.status.accessMessage(),
        metadata: NativeTelinkControlCommand.status.metadata(),
        lastReservedBy: "status-test",
        sourceRole: .telinkRuntime
    )
}

func reserveNativeStatusProxyPdus(
    statePath: String,
    addresses: [Int]
) throws -> NativePreparedProxyPduSequence {
    guard !addresses.isEmpty else {
        throw AmaranHelperError.invalidState("status batch requires at least one address")
    }
    guard addresses.allSatisfy({ (1...0x7fff).contains($0) }) else {
        throw AmaranHelperError.invalidState("status batch contains a non-unicast address")
    }

    var context = try NativeReservationContext(statePath: statePath, nodeID: nil, requireDeviceKey: false)
    guard let fixtures = context.payload["fixtures"] as? [[String: Any]] else {
        throw AmaranHelperError.invalidState("state file is missing fixtures")
    }
    let sourceAddress = try nativeTelinkSourceAddress(
        runtime: context.runtime,
        fixtures: fixtures,
        avoiding: Set(addresses)
    )
    let sequenceNext = try context.sequenceNext()
    let nextSequence = sequenceNext + addresses.count
    guard nextSequence <= 0x00ff_ffff else {
        throw AmaranHelperError.invalidState("runtime sequence_next does not have room for discover batch")
    }

    let proxyPdus = try statusBatchProxyPdus(
        context: context, addresses: addresses, sourceAddress: sourceAddress, sequenceNext: sequenceNext
    )

    try context.persist(
        sourceAddress: sourceAddress,
        sequenceNext: nextSequence,
        lastReservedBy: "discover-status-batch",
        sourceRole: .telinkRuntime
    )

    return NativePreparedProxyPduSequence(
        proxyPdus: proxyPdus,
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: statusBatchMetadata(
            context: context, addresses: addresses, sourceAddress: sourceAddress,
            sequenceNext: sequenceNext, nextSequence: nextSequence
        ),
        expectedSegmentAckSeqZero: nil,
        expectedSegmentAckSegN: nil
    )
}

private func statusBatchProxyPdus(
    context: NativeReservationContext,
    addresses: [Int],
    sourceAddress: Int,
    sequenceNext: Int
) throws -> [[UInt8]] {
    let accessMessage = try NativeTelinkControlCommand.status.accessMessage()
    return try addresses.enumerated().map { offset, address in
        try NativeMeshCrypto.applicationAccessProxyPdu(
            context: MeshMessageContext(
                ivIndex: UInt32(context.ivIndex),
                sequence: UInt32(sequenceNext + offset),
                source: UInt16(sourceAddress),
                destination: UInt16(address)
            ),
            ttl: 10,
            netKey: context.netKey,
            applicationKey: context.appKey,
            accessMessage: accessMessage
        ).network.proxyPdu
    }
}

private func statusBatchMetadata(
    context: NativeReservationContext,
    addresses: [Int],
    sourceAddress: Int,
    sequenceNext: Int,
    nextSequence: Int
) -> [String: Any] {
    [
        "control_command": "status_batch",
        "address_count": addresses.count,
        "addresses": addresses,
        "iv_index": context.ivIndex,
        "sequence": sequenceNext,
        "sequence_last": sequenceNext + addresses.count - 1,
        "sequence_next": nextSequence,
        "source": sourceAddress,
        "ttl": 10
    ]
}
