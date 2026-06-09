import Foundation

extension NativeMeshCryptoTests {
    static func testDeviceAndSegmentedAccess(_ fixtures: NativeMeshTestFixtures) throws {
        let netKey = fixtures.netKey
        let keyMaterial = fixtures.k2Material
        let configAppKeyAdd = fixtures.configAppKeyAdd
        let configDeviceKey = try NativeMeshCrypto.bytes(hex: "9d6dd0e96eb25dc19a40ed9914f8f03f")
        try assertDeviceUnsegmentedAccess(netKey: netKey, keyMaterial: keyMaterial, configDeviceKey: configDeviceKey)
        try assertSegmentedConfigAccess(
            netKey: netKey,
            keyMaterial: keyMaterial,
            configDeviceKey: configDeviceKey,
            configAppKeyAdd: configAppKeyAdd
        )
        try assertSegmentAcknowledgment(keyMaterial: keyMaterial)
    }

    static func assertDeviceUnsegmentedAccess(
        netKey: [UInt8],
        keyMaterial: MeshKeyMaterial,
        configDeviceKey: [UInt8]
    ) throws {
        try assertDeviceUpperTransport()
        let configAccess = try NativeMeshCrypto.deviceAccessProxyPdu(
            context: MeshMessageContext(
                ivIndex: 0x12345678,
                sequence: 0x00000a,
                source: 0x0001,
                destination: 0x1201
            ),
            ttl: 0x03,
            netKey: netKey,
            deviceKey: configDeviceKey,
            accessMessage: NativeMeshConfig.configCompositionDataGet()
        )
        expectEqual(configAccess.lowerTransport.header, 0x00, "Mesh device access lower header")
        let decodedConfigNetwork = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: configAccess.network.networkPdu,
            ivIndex: 0x12345678,
            nid: keyMaterial.nid,
            encryptionKey: keyMaterial.encryptionKey,
            privacyKey: keyMaterial.privacyKey
        )
        let decodedConfigLower = try NativeMeshCrypto.decodeLowerTransportUnsegmentedAccessPdu(
            lowerTransportPdu: decodedConfigNetwork.transportPdu
        )
        expectEqual(decodedConfigLower.akf, false, "Mesh device access decoded AKF")
        expectEqual(decodedConfigLower.aid, 0, "Mesh device access decoded AID")
        let decodedConfigUpper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
            deviceKey: configDeviceKey,
            context: MeshMessageContext(
                ivIndex: 0x12345678,
                sequence: decodedConfigNetwork.sequence,
                source: decodedConfigNetwork.source,
                destination: decodedConfigNetwork.destination
            ),
            upperTransportPdu: decodedConfigLower.upperTransportPdu
        )
        try expectHex(decodedConfigUpper.accessMessage, "800800", "Mesh device access decoded config message")
    }

    static func assertDeviceUpperTransport() throws {
        let deviceUpperTransport = try NativeMeshCrypto.upperTransportAccessPdu(
            deviceKey: NativeMeshCrypto.bytes(hex: "9d6dd0e96eb25dc19a40ed9914f8f03f"),
            context: MeshMessageContext(
                ivIndex: 0x12345678,
                sequence: 0x3129ab,
                source: 0x0003,
                destination: 0x1201
            ),
            accessMessage: NativeMeshCrypto.bytes(hex: "0056341263964771734fbd76e3b40519d1d94a48")
        )
        try expectHex(deviceUpperTransport.nonce, "02003129ab0003120112345678", "Mesh device nonce")
        try expectHex(
            deviceUpperTransport.encAccessMessage,
            "ee9dddfd2169326d23f3afdfcfdc18c52fdef772",
            "Mesh device EncAccessMessage"
        )
        try expectHex(deviceUpperTransport.transMic, "e0e17308", "Mesh device TransMIC")
        try expectHex(
            deviceUpperTransport.upperTransportPdu,
            "ee9dddfd2169326d23f3afdfcfdc18c52fdef772e0e17308",
            "Mesh device UpperTransportPDU"
        )
    }

    static func assertSegmentedConfigAccess(
        netKey: [UInt8],
        keyMaterial: MeshKeyMaterial,
        configDeviceKey: [UInt8],
        configAppKeyAdd: [UInt8]
    ) throws {
        expectThrows("Config AppKey Add needs segmented lower transport") {
            _ = try NativeMeshCrypto.deviceAccessProxyPdu(
                context: MeshMessageContext(
                    ivIndex: 0x12345678,
                    sequence: 0x00000b,
                    source: 0x0001,
                    destination: 0x1201
                ),
                ttl: 0x03,
                netKey: netKey,
                deviceKey: configDeviceKey,
                accessMessage: configAppKeyAdd
            )
        }
        let segmentedConfigAccess = try NativeMeshCrypto.segmentedDeviceAccessProxyPdus(
            context: MeshMessageContext(
                ivIndex: 0x12345678,
                sequence: 0x00000b,
                source: 0x0001,
                destination: 0x1201
            ),
            ttl: 0x03,
            netKey: netKey,
            deviceKey: configDeviceKey,
            accessMessage: configAppKeyAdd
        )
        expectEqual(segmentedConfigAccess.lowerTransport.seqZero, 0x000b, "Config segmented SeqZero")
        expectEqual(segmentedConfigAccess.lowerTransport.segN, 1, "Config segmented SegN")
        expectEqual(segmentedConfigAccess.lowerTransport.segments.count, 2, "Config segmented count")
        expectEqual(
            segmentedConfigAccess.lowerTransport.lowerTransportPdus.map(\.count),
            [16, 16],
            "Config segmented lower PDU lengths"
        )
        try expectHex(
            Array(segmentedConfigAccess.lowerTransport.segments[0].lowerTransportPdu.prefix(4)),
            "80002c01",
            "Config segmented first header"
        )
        try expectHex(
            Array(segmentedConfigAccess.lowerTransport.segments[1].lowerTransportPdu.prefix(4)),
            "80002c21",
            "Config segmented second header"
        )
        try assertSegmentedConfigReassembly(
            segmentedConfigAccess: segmentedConfigAccess,
            keyMaterial: keyMaterial,
            configDeviceKey: configDeviceKey,
            configAppKeyAdd: configAppKeyAdd
        )
    }

    static func assertSegmentedConfigReassembly(
        segmentedConfigAccess: SegmentedDeviceAccessProxyPduResult,
        keyMaterial: MeshKeyMaterial,
        configDeviceKey: [UInt8],
        configAppKeyAdd: [UInt8]
    ) throws {
        let decodedSegmentNetworks = try segmentedConfigAccess.networks.map {
            try NativeMeshCrypto.decodeNetworkPdu(
                networkPdu: $0.networkPdu,
                ivIndex: 0x12345678,
                nid: keyMaterial.nid,
                encryptionKey: keyMaterial.encryptionKey,
                privacyKey: keyMaterial.privacyKey
            )
        }
        expectEqual(decodedSegmentNetworks.map(\.sequence), [0x00000b, 0x00000c], "Config segmented network SEQs")
        let reassembledConfigLower = try NativeMeshCrypto.reassembleLowerTransportSegmentedAccessPdus(
            lowerTransportPdus: decodedSegmentNetworks.map(\.transportPdu)
        )
        expectEqual(reassembledConfigLower.akf, false, "Config segmented reassembled AKF")
        expectEqual(reassembledConfigLower.aid, 0, "Config segmented reassembled AID")
        expectEqual(reassembledConfigLower.seqZero, 0x000b, "Config segmented reassembled SeqZero")
        try expectHex(
            reassembledConfigLower.upperTransportPdu,
            NativeMeshCrypto.hex(segmentedConfigAccess.upperTransport.upperTransportPdu),
            "Config segmented reassembled UpperTransportPDU"
        )
        let decodedSegmentedConfigUpper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
            deviceKey: configDeviceKey,
            context: MeshMessageContext(
                ivIndex: 0x12345678,
                sequence: 0x00000b,
                source: 0x0001,
                destination: 0x1201
            ),
            upperTransportPdu: reassembledConfigLower.upperTransportPdu
        )
        try expectHex(
            decodedSegmentedConfigUpper.accessMessage,
            NativeMeshCrypto.hex(configAppKeyAdd),
            "Config segmented decoded access message"
        )
    }

    static func assertSegmentAcknowledgment(keyMaterial: MeshKeyMaterial) throws {
        let segmentAck = try NativeMeshCrypto.lowerTransportSegmentAcknowledgmentPdu(
            seqZero: 0x000b,
            ackedSegments: 0x00000003
        )
        try expectHex(segmentAck, "00002c00000003", "Config Segment Acknowledgment PDU")
        let decodedSegmentAck = try NativeMeshCrypto.decodeLowerTransportSegmentAcknowledgment(
            lowerTransportPdu: segmentAck
        )
        expectEqual(decodedSegmentAck.obo, false, "Config Segment Acknowledgment OBO")
        expectEqual(decodedSegmentAck.seqZero, 0x000b, "Config Segment Acknowledgment SeqZero")
        expectEqual(decodedSegmentAck.acknowledges(segment: 0), true, "Config Segment Acknowledgment segment 0")
        expectEqual(decodedSegmentAck.acknowledges(segment: 1), true, "Config Segment Acknowledgment segment 1")
        expectEqual(decodedSegmentAck.acknowledges(segment: 2), false, "Config Segment Acknowledgment segment 2")
        expectEqual(decodedSegmentAck.acknowledgesAll(segN: 1), true, "Config Segment Acknowledgment complete")
        expectEqual(decodedSegmentAck.acknowledgesAll(segN: 2), false, "Config Segment Acknowledgment incomplete")
        let segmentAckNetwork = try NativeMeshCrypto.networkPdu(
            input: NetworkPduInput(
                context: MeshMessageContext(
                    ivIndex: 0x12345678,
                    sequence: 0x00000d,
                    source: 0x0001,
                    destination: 0x1201
                ),
                keyMaterial: keyMaterial,
                ctl: 1,
                ttl: 0
            ),
            transportPdu: segmentAck
        )
        let decodedSegmentAckNetwork = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: segmentAckNetwork.networkPdu,
            ivIndex: 0x12345678,
            nid: keyMaterial.nid,
            encryptionKey: keyMaterial.encryptionKey,
            privacyKey: keyMaterial.privacyKey
        )
        expectEqual(decodedSegmentAckNetwork.ctl, 1, "Config Segment Acknowledgment network CTL")
        expectEqual(decodedSegmentAckNetwork.ttl, 0, "Config Segment Acknowledgment network TTL")
        try expectHex(
            decodedSegmentAckNetwork.transportPdu,
            "00002c00000003",
            "Config Segment Acknowledgment network lower PDU"
        )
    }

    static func testNetworkPdu(_ fixtures: NativeMeshTestFixtures) throws {
        let keyMaterial = fixtures.k2Material
        let networkPdu = try NativeMeshCrypto.networkPdu(
            input: NetworkPduInput(
                context: MeshMessageContext(
                    ivIndex: 0x12345677,
                    sequence: 0x07080c,
                    source: 0x1234,
                    destination: 0x9736
                ),
                keyMaterial: keyMaterial,
                ctl: 0,
                ttl: 3
            ),
            transportPdu: NativeMeshCrypto.bytes(hex: "662456db5e3100eef65daa7a38")
        )
        try expectHex(networkPdu.nonce, "000307080c1234000012345677", "Mesh network nonce")
        try expectHex(
            networkPdu.encryptedDstAndTransportPdu,
            "7a9d696d3dd16a75489696f0b70c71",
            "Mesh network encrypted payload"
        )
        try expectHex(networkPdu.netMic, "1b881385", "Mesh network NetMIC")
        try expectHex(
            networkPdu.privacyPlaintext,
            "0000000000123456777a9d696d3dd16a",
            "Mesh network privacy plaintext"
        )
        try expectHex(networkPdu.pecb, "74a385d9ec19", "Mesh network PECB")
        try expectHex(networkPdu.obfuscatedCtlTtlSeqSrc, "77a48dd5fe2d", "Mesh network obfuscated header")
        try expectHex(
            networkPdu.networkPdu,
            "e877a48dd5fe2d7a9d696d3dd16a75489696f0b70c711b881385",
            "Mesh network PDU"
        )
        try expectHex(
            networkPdu.proxyPdu,
            "00e877a48dd5fe2d7a9d696d3dd16a75489696f0b70c711b881385",
            "Mesh proxy PDU"
        )
        try assertNetworkPduDecode(networkPdu.networkPdu, keyMaterial: keyMaterial)
    }

    static func assertNetworkPduDecode(_ networkPduBytes: [UInt8], keyMaterial: MeshKeyMaterial) throws {
        let decodedNetworkPdu = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: networkPduBytes,
            ivIndex: 0x12345677,
            nid: keyMaterial.nid,
            encryptionKey: keyMaterial.encryptionKey,
            privacyKey: keyMaterial.privacyKey
        )
        expectEqual(decodedNetworkPdu.ctl, 0, "Mesh network decoded CTL")
        expectEqual(decodedNetworkPdu.ttl, 3, "Mesh network decoded TTL")
        expectEqual(decodedNetworkPdu.sequence, 0x07080c, "Mesh network decoded SEQ")
        expectEqual(decodedNetworkPdu.source, 0x1234, "Mesh network decoded SRC")
        expectEqual(decodedNetworkPdu.destination, 0x9736, "Mesh network decoded DST")
        try expectHex(decodedNetworkPdu.transportPdu, "662456db5e3100eef65daa7a38", "Mesh network decoded transport")
    }
}
