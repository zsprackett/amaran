import CommonCrypto
import Foundation

extension NativeMeshCrypto {
    static func applicationAccessProxyPdu(
        context: MeshMessageContext,
        ttl: UInt8,
        netKey: [UInt8],
        applicationKey: [UInt8],
        accessMessage: [UInt8]
    ) throws -> ApplicationAccessProxyPduResult {
        let networkKeys = try k2(n: netKey, p: [0x00])
        let aid = try k4(n: applicationKey)
        let upperTransport = try upperTransportAccessPdu(
            applicationKey: applicationKey,
            context: context,
            accessMessage: accessMessage
        )
        let lowerTransport = try lowerTransportUnsegmentedAccessPdu(
            akf: true,
            aid: aid,
            upperTransportPdu: upperTransport.upperTransportPdu
        )
        let network = try networkPdu(
            input: NetworkPduInput(context: context, keyMaterial: networkKeys, ctl: 0, ttl: ttl),
            transportPdu: lowerTransport.lowerTransportPdu
        )
        return ApplicationAccessProxyPduResult(
            aid: aid,
            accessMessage: accessMessage,
            upperTransport: upperTransport,
            lowerTransport: lowerTransport,
            network: network
        )
    }

    static func deviceAccessProxyPdu(
        context: MeshMessageContext,
        ttl: UInt8,
        netKey: [UInt8],
        deviceKey: [UInt8],
        accessMessage: [UInt8]
    ) throws -> DeviceAccessProxyPduResult {
        let networkKeys = try k2(n: netKey, p: [0x00])
        let upperTransport = try upperTransportAccessPdu(
            deviceKey: deviceKey,
            context: context,
            accessMessage: accessMessage
        )
        let lowerTransport = try lowerTransportUnsegmentedAccessPdu(
            akf: false,
            aid: 0,
            upperTransportPdu: upperTransport.upperTransportPdu
        )
        let network = try networkPdu(
            input: NetworkPduInput(context: context, keyMaterial: networkKeys, ctl: 0, ttl: ttl),
            transportPdu: lowerTransport.lowerTransportPdu
        )
        return DeviceAccessProxyPduResult(
            accessMessage: accessMessage,
            upperTransport: upperTransport,
            lowerTransport: lowerTransport,
            network: network
        )
    }

    static func segmentedDeviceAccessProxyPdus(
        context: MeshMessageContext,
        ttl: UInt8,
        netKey: [UInt8],
        deviceKey: [UInt8],
        accessMessage: [UInt8],
        transMicLength: Int = 4
    ) throws -> SegmentedDeviceAccessProxyPduResult {
        let networkKeys = try k2(n: netKey, p: [0x00])
        let upperTransport = try upperTransportAccessPdu(
            deviceKey: deviceKey,
            context: context,
            accessMessage: accessMessage,
            transMicLength: transMicLength
        )
        let lowerTransport = try lowerTransportSegmentedAccessPdus(
            akf: false,
            aid: 0,
            szmic: transMicLength == 8,
            seqZero: UInt16(context.sequence & 0x1fff),
            upperTransportPdu: upperTransport.upperTransportPdu
        )
        guard context.sequence + UInt32(lowerTransport.segments.count - 1) <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("segmented sequence range exceeds 24-bit sequence space")
        }

        let networks = try lowerTransport.segments.enumerated().map { index, segment in
            var segmentContext = context
            segmentContext.sequence = context.sequence + UInt32(index)
            return try networkPdu(
                input: NetworkPduInput(context: segmentContext, keyMaterial: networkKeys, ctl: 0, ttl: ttl),
                transportPdu: segment.lowerTransportPdu
            )
        }

        return SegmentedDeviceAccessProxyPduResult(
            accessMessage: accessMessage,
            upperTransport: upperTransport,
            lowerTransport: lowerTransport,
            networks: networks
        )
    }

    static func networkPdu(
        input: NetworkPduInput,
        transportPdu: [UInt8]
    ) throws -> NetworkPduResult {
        try encryptedNetworkPdu(
            input: input,
            transportPdu: transportPdu,
            nonce: networkNonce(
                ctl: input.ctl,
                ttl: input.ttl,
                sequence: input.context.sequence,
                source: input.context.source,
                ivIndex: input.context.ivIndex
            ),
            proxyMessageType: 0x00
        )
    }

    static func proxyConfigurationProxyPdu(
        ivIndex: UInt32,
        sequence: UInt32,
        source: UInt16,
        netKey: [UInt8],
        transportPdu: [UInt8]
    ) throws -> NetworkPduResult {
        let networkKeys = try k2(n: netKey, p: [0x00])
        let context = MeshMessageContext(
            ivIndex: ivIndex,
            sequence: sequence,
            source: source,
            destination: 0x0000
        )
        return try encryptedNetworkPdu(
            input: NetworkPduInput(context: context, keyMaterial: networkKeys, ctl: 1, ttl: 0),
            transportPdu: transportPdu,
            nonce: proxyNonce(sequence: sequence, source: source, ivIndex: ivIndex),
            proxyMessageType: 0x02
        )
    }

    static func encryptedNetworkPdu(
        input: NetworkPduInput,
        transportPdu: [UInt8],
        nonce: [UInt8],
        proxyMessageType: UInt8
    ) throws -> NetworkPduResult {
        let ivIndex = input.context.ivIndex
        let sequence = input.context.sequence
        let source = input.context.source
        let destination = input.context.destination
        let nid = input.keyMaterial.nid
        let encryptionKey = input.keyMaterial.encryptionKey
        let privacyKey = input.keyMaterial.privacyKey
        let ctl = input.ctl
        let ttl = input.ttl
        try validateNetworkPduInput(
            input: input,
            transportPdu: transportPdu,
            proxyMessageType: proxyMessageType
        )

        let plaintext = uintBytes(UInt64(destination), count: 2) + transportPdu
        let micLength = ctl == 0 ? 4 : 8
        let networkEncryption = try aesCcmEncrypt(
            key: encryptionKey,
            nonce: nonce,
            plaintext: plaintext,
            micLength: micLength
        )

        let privacyPlaintext = [UInt8](repeating: 0, count: 5)
            + uintBytes(UInt64(ivIndex), count: 4)
            + Array((networkEncryption.ciphertext + networkEncryption.mic).prefix(7))
        let pecb = Array(try aes128EncryptBlock(key: privacyKey, block: privacyPlaintext).prefix(6))
        let ctlTtlSeqSrc = [((ctl & 0x01) << 7) | (ttl & 0x7f)]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
        let obfuscated = xor(ctlTtlSeqSrc, pecb)
        let iviNid = UInt8((ivIndex & 0x01) == 0 ? 0 : 0x80) | (nid & 0x7f)
        let networkPdu = [iviNid] + obfuscated + networkEncryption.ciphertext + networkEncryption.mic
        let proxyPdu = [proxyMessageType] + networkPdu

        return NetworkPduResult(
            nonce: nonce,
            encryptedDstAndTransportPdu: networkEncryption.ciphertext,
            netMic: networkEncryption.mic,
            privacyPlaintext: privacyPlaintext,
            pecb: pecb,
            obfuscatedCtlTtlSeqSrc: obfuscated,
            networkPdu: networkPdu,
            proxyPdu: proxyPdu
        )
    }

    static func validateNetworkPduInput(
        input: NetworkPduInput,
        transportPdu: [UInt8],
        proxyMessageType: UInt8
    ) throws {
        guard input.keyMaterial.nid <= 0x7f else {
            throw NativeMeshCryptoError.invalidParameter("NID must be a 7-bit value")
        }
        guard input.ctl <= 0x01 else {
            throw NativeMeshCryptoError.invalidParameter("CTL must be 0 or 1")
        }
        guard input.ttl <= 0x7f else {
            throw NativeMeshCryptoError.invalidParameter("TTL must be a 7-bit value")
        }
        guard input.context.sequence <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("sequence number must be a 24-bit value")
        }
        guard !transportPdu.isEmpty else {
            throw NativeMeshCryptoError.invalidParameter("transport PDU must not be empty")
        }
        guard proxyMessageType <= 0x3f else {
            throw NativeMeshCryptoError.invalidParameter("Proxy PDU message type must be a 6-bit value")
        }
    }
}
