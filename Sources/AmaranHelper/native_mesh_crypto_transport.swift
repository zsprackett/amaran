import CommonCrypto
import Foundation

extension NativeMeshCrypto {
    static func upperTransportAccessPdu(
        applicationKey: [UInt8],
        context: MeshMessageContext,
        accessMessage: [UInt8],
        transMicLength: Int = 4,
        labelUuid: [UInt8] = []
    ) throws -> UpperTransportAccessResult {
        guard context.sequence <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("sequence number must be a 24-bit value")
        }
        let nonce = applicationNonce(
            aszmic: transMicLength == 8,
            sequence: context.sequence,
            source: context.source,
            destination: context.destination,
            ivIndex: context.ivIndex
        )
        return try upperTransportAccessPdu(
            key: applicationKey,
            nonce: nonce,
            accessMessage: accessMessage,
            transMicLength: transMicLength,
            aad: labelUuid
        )
    }

    static func upperTransportAccessPdu(
        deviceKey: [UInt8],
        context: MeshMessageContext,
        accessMessage: [UInt8],
        transMicLength: Int = 4
    ) throws -> UpperTransportAccessResult {
        guard context.sequence <= 0x00ff_ffff else {
            throw NativeMeshCryptoError.invalidParameter("sequence number must be a 24-bit value")
        }
        let nonce = deviceNonce(
            aszmic: transMicLength == 8,
            sequence: context.sequence,
            source: context.source,
            destination: context.destination,
            ivIndex: context.ivIndex
        )
        return try upperTransportAccessPdu(
            key: deviceKey,
            nonce: nonce,
            accessMessage: accessMessage,
            transMicLength: transMicLength
        )
    }

    static func lowerTransportUnsegmentedAccessPdu(
        akf: Bool,
        aid: UInt8,
        upperTransportPdu: [UInt8]
    ) throws -> LowerTransportAccessResult {
        guard aid <= 0x3f else {
            throw NativeMeshCryptoError.invalidParameter("AID must be a 6-bit value")
        }
        guard (5...15).contains(upperTransportPdu.count) else {
            throw NativeMeshCryptoError.invalidLength("unsegmented Upper Transport Access PDU must be 5 to 15 bytes")
        }

        let header = (akf ? UInt8(0x40) : UInt8(0x00)) | aid
        return LowerTransportAccessResult(header: header, lowerTransportPdu: [header] + upperTransportPdu)
    }

    static func lowerTransportSegmentedAccessPdus(
        akf: Bool,
        aid: UInt8,
        szmic: Bool,
        seqZero: UInt16,
        upperTransportPdu: [UInt8]
    ) throws -> LowerTransportSegmentedAccessResult {
        guard aid <= 0x3f else {
            throw NativeMeshCryptoError.invalidParameter("AID must be a 6-bit value")
        }
        guard seqZero <= 0x1fff else {
            throw NativeMeshCryptoError.invalidParameter("SeqZero must be a 13-bit value")
        }
        guard !upperTransportPdu.isEmpty else {
            throw NativeMeshCryptoError.invalidLength("segmented Upper Transport Access PDU must not be empty")
        }
        guard upperTransportPdu.count <= 384 else {
            throw NativeMeshCryptoError.invalidLength("segmented Upper Transport Access PDU must be at most 384 bytes")
        }

        let segmentPayloadSize = 12
        let segmentCount = (upperTransportPdu.count + segmentPayloadSize - 1) / segmentPayloadSize
        guard (1...32).contains(segmentCount) else {
            throw NativeMeshCryptoError.invalidLength("segmented Upper Transport Access PDU must fit in 32 segments")
        }

        let header = UInt8(0x80) | (akf ? UInt8(0x40) : UInt8(0x00)) | aid
        let segN = UInt8(segmentCount - 1)
        let segments = try (0..<segmentCount).map { index -> LowerTransportSegmentedAccessSegment in
            let start = index * segmentPayloadSize
            let end = min(start + segmentPayloadSize, upperTransportPdu.count)
            let segment = Array(upperTransportPdu[start..<end])
            let segO = UInt8(index)
            let lowerTransportHeader = try segmentedAccessHeader(
                header: header,
                szmic: szmic,
                seqZero: seqZero,
                segO: segO,
                segN: segN
            )
            return LowerTransportSegmentedAccessSegment(
                header: header,
                szmic: szmic,
                seqZero: seqZero,
                segO: segO,
                segN: segN,
                segment: segment,
                lowerTransportPdu: lowerTransportHeader + segment
            )
        }

        return LowerTransportSegmentedAccessResult(
            akf: akf,
            aid: aid,
            szmic: szmic,
            seqZero: seqZero,
            segN: segN,
            segments: segments
        )
    }

    static func lowerTransportSegmentAcknowledgmentPdu(
        obo: Bool = false,
        seqZero: UInt16,
        ackedSegments: UInt32
    ) throws -> [UInt8] {
        guard seqZero <= 0x1fff else {
            throw NativeMeshCryptoError.invalidParameter("SeqZero must be a 13-bit value")
        }
        return [
            0x00,
            (obo ? UInt8(0x80) : UInt8(0x00)) | UInt8((seqZero >> 6) & 0x7f),
            UInt8((seqZero & 0x3f) << 2)
        ] + uintBytes(ackedSegments, count: 4)
    }

    static func vendorAccessMessage(
        opcode: UInt8, companyIdentifier: UInt16, parameters: [UInt8] = []
    ) throws -> [UInt8] {
        guard opcode <= 0x3f else {
            throw NativeMeshCryptoError.invalidParameter("vendor opcode must be a 6-bit value")
        }
        return [0xc0 | opcode] + littleEndianBytes(UInt64(companyIdentifier), count: 2) + parameters
    }

    static func upperTransportAccessPdu(
        key: [UInt8],
        nonce: [UInt8],
        accessMessage: [UInt8],
        transMicLength: Int,
        aad: [UInt8] = []
    ) throws -> UpperTransportAccessResult {
        guard !accessMessage.isEmpty else {
            throw NativeMeshCryptoError.invalidParameter("access message must not be empty")
        }
        guard transMicLength == 4 || transMicLength == 8 else {
            throw NativeMeshCryptoError.invalidLength("TransMIC must be 4 or 8 bytes")
        }
        let maxAccessLength = transMicLength == 4 ? 380 : 376
        guard accessMessage.count <= maxAccessLength else {
            throw NativeMeshCryptoError.invalidLength("access message is too large for TransMIC size")
        }
        if !aad.isEmpty && aad.count != 16 {
            throw NativeMeshCryptoError.invalidLength("Label UUID AAD must be 16 bytes")
        }

        let encrypted = try aesCcmEncrypt(
            key: key,
            nonce: nonce,
            plaintext: accessMessage,
            aad: aad,
            micLength: transMicLength
        )
        return UpperTransportAccessResult(
            nonce: nonce,
            encAccessMessage: encrypted.ciphertext,
            transMic: encrypted.mic,
            upperTransportPdu: encrypted.ciphertext + encrypted.mic
        )
    }

    static func segmentedAccessHeader(
        header: UInt8,
        szmic: Bool,
        seqZero: UInt16,
        segO: UInt8,
        segN: UInt8
    ) throws -> [UInt8] {
        guard (header & 0x80) != 0 else {
            throw NativeMeshCryptoError.invalidParameter("segmented Access header must set SEG")
        }
        guard seqZero <= 0x1fff else {
            throw NativeMeshCryptoError.invalidParameter("SeqZero must be a 13-bit value")
        }
        guard segO <= 0x1f && segN <= 0x1f else {
            throw NativeMeshCryptoError.invalidParameter("SegO and SegN must be 5-bit values")
        }
        guard segO <= segN else {
            throw NativeMeshCryptoError.invalidParameter("SegO must not exceed SegN")
        }
        return [
            header,
            (szmic ? UInt8(0x80) : UInt8(0x00)) | UInt8((seqZero >> 6) & 0x7f),
            UInt8((seqZero & 0x3f) << 2) | UInt8((segO >> 3) & 0x03),
            UInt8((segO & 0x07) << 5) | segN
        ]
    }
}
