import CommonCrypto
import Foundation

extension NativeMeshCrypto {
    static func decodeNetworkPdu(
        networkPdu: [UInt8],
        ivIndex: UInt32,
        nid: UInt8,
        encryptionKey: [UInt8],
        privacyKey: [UInt8]
    ) throws -> NetworkPduDecoded {
        guard networkPdu.count >= 14 else {
            throw NativeMeshCryptoError.invalidLength("Network PDU is too short")
        }
        guard nid <= 0x7f else {
            throw NativeMeshCryptoError.invalidParameter("NID must be a 7-bit value")
        }

        let iviNid = networkPdu[0]
        let pduNid = iviNid & 0x7f
        guard pduNid == nid else {
            throw NativeMeshCryptoError.authenticationFailed("NID does not match")
        }

        let obfuscated = Array(networkPdu[1..<7])
        let encryptedAndMic = Array(networkPdu[7...])
        guard encryptedAndMic.count >= 8 else {
            throw NativeMeshCryptoError.invalidLength("encrypted network payload is too short")
        }

        let header = try deobfuscatedNetworkHeader(
            obfuscated: obfuscated,
            encryptedAndMic: encryptedAndMic,
            ivIndex: ivIndex,
            privacyKey: privacyKey
        )
        return try decryptNetworkPayload(
            iviNid: iviNid,
            header: header,
            encryptedAndMic: encryptedAndMic,
            ivIndex: ivIndex,
            encryptionKey: encryptionKey
        )
    }

    static func decryptNetworkPayload(
        iviNid: UInt8,
        header: DeobfuscatedNetworkHeader,
        encryptedAndMic: [UInt8],
        ivIndex: UInt32,
        encryptionKey: [UInt8]
    ) throws -> NetworkPduDecoded {
        let ctl = header.ctl
        let ttl = header.ttl
        let sequence = header.sequence
        let source = header.source
        let micLength = ctl == 0 ? 4 : 8
        guard encryptedAndMic.count > micLength + 2 else {
            throw NativeMeshCryptoError.invalidLength("encrypted network payload is too short for NetMIC")
        }

        let ciphertext = Array(encryptedAndMic.dropLast(micLength))
        let netMic = Array(encryptedAndMic.suffix(micLength))
        let nonce = networkNonce(ctl: ctl, ttl: ttl, sequence: sequence, source: source, ivIndex: ivIndex)
        let plaintext = try aesCcmDecrypt(
            key: encryptionKey,
            nonce: nonce,
            ciphertext: ciphertext,
            mic: netMic
        )
        guard plaintext.count >= 3 else {
            throw NativeMeshCryptoError.invalidLength("decrypted network payload is too short")
        }

        return NetworkPduDecoded(
            ivi: (iviNid & 0x80) >> 7,
            nid: iviNid & 0x7f,
            ctl: ctl,
            ttl: ttl,
            sequence: sequence,
            source: source,
            destination: uint16(bytes: Array(plaintext[0..<2])),
            transportPdu: Array(plaintext[2...]),
            netMic: netMic
        )
    }

    static func deobfuscatedNetworkHeader(
        obfuscated: [UInt8],
        encryptedAndMic: [UInt8],
        ivIndex: UInt32,
        privacyKey: [UInt8]
    ) throws -> DeobfuscatedNetworkHeader {
        let privacyPlaintext = [UInt8](repeating: 0, count: 5)
            + uintBytes(UInt64(ivIndex), count: 4)
            + Array(encryptedAndMic.prefix(7))
        let pecb = Array(try aes128EncryptBlock(key: privacyKey, block: privacyPlaintext).prefix(6))
        let ctlTtlSeqSrc = xor(obfuscated, pecb)
        return DeobfuscatedNetworkHeader(
            ctl: (ctlTtlSeqSrc[0] & 0x80) >> 7,
            ttl: ctlTtlSeqSrc[0] & 0x7f,
            sequence: uint32(bytes: Array(ctlTtlSeqSrc[1..<4])),
            source: uint16(bytes: Array(ctlTtlSeqSrc[4..<6]))
        )
    }

    static func decodeLowerTransportUnsegmentedAccessPdu(
        lowerTransportPdu: [UInt8]
    ) throws -> LowerTransportAccessDecoded {
        guard lowerTransportPdu.count >= 6 else {
            throw NativeMeshCryptoError.invalidLength("Lower Transport Access PDU is too short")
        }
        let header = lowerTransportPdu[0]
        guard (header & 0x80) == 0 else {
            throw NativeMeshCryptoError.invalidParameter("segmented access messages are not supported")
        }
        return LowerTransportAccessDecoded(
            akf: (header & 0x40) != 0,
            aid: header & 0x3f,
            upperTransportPdu: Array(lowerTransportPdu.dropFirst())
        )
    }

    static func decodeLowerTransportSegmentedAccessPdu(
        lowerTransportPdu: [UInt8]
    ) throws -> LowerTransportSegmentedAccessDecoded {
        guard (5...16).contains(lowerTransportPdu.count) else {
            throw NativeMeshCryptoError.invalidLength("Segmented Lower Transport Access PDU must be 5 to 16 bytes")
        }
        let header = lowerTransportPdu[0]
        guard (header & 0x80) != 0 else {
            throw NativeMeshCryptoError.invalidParameter("Lower Transport Access PDU is not segmented")
        }

        let seqZero = UInt16(lowerTransportPdu[1] & 0x7f) << 6
            | UInt16((lowerTransportPdu[2] & 0xfc) >> 2)
        let segO = ((lowerTransportPdu[2] & 0x03) << 3) | ((lowerTransportPdu[3] & 0xe0) >> 5)
        let segN = lowerTransportPdu[3] & 0x1f
        guard segO <= segN else {
            throw NativeMeshCryptoError.invalidParameter("SegO must not exceed SegN")
        }
        let segment = Array(lowerTransportPdu.dropFirst(4))
        if segO < segN && segment.count != 12 {
            throw NativeMeshCryptoError.invalidLength("non-final segmented Access PDU segments must carry 12 bytes")
        }
        guard !segment.isEmpty && segment.count <= 12 else {
            throw NativeMeshCryptoError.invalidLength("segmented Access PDU segment must be 1 to 12 bytes")
        }

        return LowerTransportSegmentedAccessDecoded(
            akf: (header & 0x40) != 0,
            aid: header & 0x3f,
            szmic: (lowerTransportPdu[1] & 0x80) != 0,
            seqZero: seqZero,
            segO: segO,
            segN: segN,
            segment: segment
        )
    }

    static func reassembleLowerTransportSegmentedAccessPdus(
        lowerTransportPdus: [[UInt8]]
    ) throws -> LowerTransportSegmentedAccessReassembled {
        guard !lowerTransportPdus.isEmpty else {
            throw NativeMeshCryptoError.invalidLength("segmented Lower Transport PDU list must not be empty")
        }
        let decoded = try lowerTransportPdus.map { try decodeLowerTransportSegmentedAccessPdu(lowerTransportPdu: $0) }
        guard let first = decoded.first else {
            throw NativeMeshCryptoError.invalidLength("segmented Lower Transport PDU list must not be empty")
        }

        var bySegmentOffset: [UInt8: LowerTransportSegmentedAccessDecoded] = [:]
        for segment in decoded {
            guard segment.akf == first.akf,
                  segment.aid == first.aid,
                  segment.szmic == first.szmic,
                  segment.seqZero == first.seqZero,
                  segment.segN == first.segN else {
                throw NativeMeshCryptoError.invalidParameter("segmented Access PDUs do not belong to the same message")
            }
            guard bySegmentOffset[segment.segO] == nil else {
                throw NativeMeshCryptoError.invalidParameter("duplicate segmented Access PDU segment")
            }
            bySegmentOffset[segment.segO] = segment
        }

        let expectedCount = Int(first.segN) + 1
        guard bySegmentOffset.count == expectedCount else {
            throw NativeMeshCryptoError.invalidLength("segmented Access PDU set is incomplete")
        }

        var upperTransportPdu: [UInt8] = []
        for index in 0...first.segN {
            guard let segment = bySegmentOffset[index] else {
                throw NativeMeshCryptoError.invalidLength("segmented Access PDU set is incomplete")
            }
            upperTransportPdu += segment.segment
        }

        return LowerTransportSegmentedAccessReassembled(
            akf: first.akf,
            aid: first.aid,
            szmic: first.szmic,
            seqZero: first.seqZero,
            upperTransportPdu: upperTransportPdu
        )
    }

    static func decodeLowerTransportSegmentAcknowledgment(
        lowerTransportPdu: [UInt8]
    ) throws -> LowerTransportSegmentAckDecoded {
        guard lowerTransportPdu.count == 7 else {
            throw NativeMeshCryptoError.invalidLength("Segment Acknowledgment PDU must be 7 bytes")
        }
        guard lowerTransportPdu[0] == 0x00 else {
            throw NativeMeshCryptoError.invalidParameter("Lower Transport PDU is not a Segment Acknowledgment")
        }
        guard (lowerTransportPdu[2] & 0x03) == 0 else {
            throw NativeMeshCryptoError.invalidParameter("Segment Acknowledgment RFU bits must be zero")
        }

        let seqZero = UInt16(lowerTransportPdu[1] & 0x7f) << 6
            | UInt16((lowerTransportPdu[2] & 0xfc) >> 2)
        return LowerTransportSegmentAckDecoded(
            obo: (lowerTransportPdu[1] & 0x80) != 0,
            seqZero: seqZero,
            ackedSegments: uint32(bytes: Array(lowerTransportPdu[3..<7]))
        )
    }

    static func decodeUpperTransportAccessPdu(
        applicationKey: [UInt8],
        context: MeshMessageContext,
        upperTransportPdu: [UInt8],
        transMicLength: Int = 4,
        labelUuid: [UInt8] = []
    ) throws -> UpperTransportAccessDecoded {
        let nonce = applicationNonce(
            aszmic: transMicLength == 8,
            sequence: context.sequence,
            source: context.source,
            destination: context.destination,
            ivIndex: context.ivIndex
        )
        return try decodeUpperTransportAccessPdu(
            key: applicationKey,
            nonce: nonce,
            upperTransportPdu: upperTransportPdu,
            transMicLength: transMicLength,
            aad: labelUuid
        )
    }

    static func decodeUpperTransportAccessPdu(
        deviceKey: [UInt8],
        context: MeshMessageContext,
        upperTransportPdu: [UInt8],
        transMicLength: Int = 4
    ) throws -> UpperTransportAccessDecoded {
        let nonce = deviceNonce(
            aszmic: transMicLength == 8,
            sequence: context.sequence,
            source: context.source,
            destination: context.destination,
            ivIndex: context.ivIndex
        )
        return try decodeUpperTransportAccessPdu(
            key: deviceKey,
            nonce: nonce,
            upperTransportPdu: upperTransportPdu,
            transMicLength: transMicLength
        )
    }

    static func decodeUpperTransportAccessPdu(
        key: [UInt8],
        nonce: [UInt8],
        upperTransportPdu: [UInt8],
        transMicLength: Int,
        aad: [UInt8] = []
    ) throws -> UpperTransportAccessDecoded {
        guard upperTransportPdu.count > transMicLength else {
            throw NativeMeshCryptoError.invalidLength("Upper Transport Access PDU is too short")
        }
        let encryptedAccessMessage = Array(upperTransportPdu.dropLast(transMicLength))
        let transMic = Array(upperTransportPdu.suffix(transMicLength))
        let accessMessage = try aesCcmDecrypt(
            key: key,
            nonce: nonce,
            ciphertext: encryptedAccessMessage,
            mic: transMic,
            aad: aad
        )
        return UpperTransportAccessDecoded(nonce: nonce, accessMessage: accessMessage, transMic: transMic)
    }
}
