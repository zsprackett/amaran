import Foundation

struct NativePreparedProxyPdu {
    let proxyPdu: [UInt8]
    let requiredProxyNetworkId: [UInt8]
    let decodeMaterial: NativeDecodeMaterial
    let metadata: [String: Any]
}

struct NativePreparedProxyPduSequence {
    let proxyPdus: [[UInt8]]
    let requiredProxyNetworkId: [UInt8]
    let decodeMaterial: NativeDecodeMaterial
    let metadata: [String: Any]
    let expectedSegmentAckSeqZero: UInt16?
    let expectedSegmentAckSegN: UInt8?
}

func segmentProxyProtocolPdu(_ proxyPdu: [UInt8], maxWriteLength: Int) throws -> [[UInt8]] {
    guard maxWriteLength >= 2 else {
        throw AmaranHelperError.invalidState("proxy write maximum length must leave room for a header and payload")
    }
    guard let header = proxyPdu.first else {
        throw AmaranHelperError.invalidState("Proxy PDU must not be empty")
    }
    guard proxyPdu.count > maxWriteLength else {
        return [proxyPdu]
    }

    let messageType = header & NativeMeshProvisioning.proxyMessageTypeMask
    let payload = Array(proxyPdu.dropFirst())
    let payloadCapacity = maxWriteLength - 1
    var segments: [[UInt8]] = []
    var offset = 0
    while offset < payload.count {
        let next = min(offset + payloadCapacity, payload.count)
        let sar: UInt8
        if offset == 0 {
            sar = NativeMeshProvisioning.proxySarFirst
        } else if next == payload.count {
            sar = NativeMeshProvisioning.proxySarLast
        } else {
            sar = NativeMeshProvisioning.proxySarContinuation
        }
        segments.append([sar | messageType] + Array(payload[offset..<next]))
        offset = next
    }
    return segments
}

struct IncomingSegmentedAccessAccumulator {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segN: UInt8
    var segments: [UInt8: (sequence: UInt32, lowerTransportPdu: [UInt8])]

    init(decoded: LowerTransportSegmentedAccessDecoded, sequence: UInt32, lowerTransportPdu: [UInt8]) {
        self.akf = decoded.akf
        self.aid = decoded.aid
        self.szmic = decoded.szmic
        self.seqZero = decoded.seqZero
        self.segN = decoded.segN
        self.segments = [
            decoded.segO: (sequence: sequence, lowerTransportPdu: lowerTransportPdu)
        ]
    }

    mutating func add(
        decoded: LowerTransportSegmentedAccessDecoded,
        sequence: UInt32,
        lowerTransportPdu: [UInt8]
    ) throws {
        guard decoded.akf == akf,
              decoded.aid == aid,
              decoded.szmic == szmic,
              decoded.seqZero == seqZero,
              decoded.segN == segN else {
            throw AmaranHelperError.invalidState("segmented access PDU does not match pending reassembly")
        }
        segments[decoded.segO] = (sequence: sequence, lowerTransportPdu: lowerTransportPdu)
    }

    var isComplete: Bool {
        segments.count == Int(segN) + 1
    }

    var segmentZeroSequence: UInt32? {
        segments[0]?.sequence
    }

    var orderedLowerTransportPdus: [[UInt8]] {
        (UInt8(0)...segN).compactMap { segments[$0]?.lowerTransportPdu }
    }
}

struct NativeDecodeMaterial {
    let networkKeys: MeshKeyMaterial
    let appKey: [UInt8]
    let appAid: UInt8
    let deviceKey: [UInt8]?
    let ivIndex: UInt32
}

/// Lower Transport access header bits used when decoding an Upper Transport
/// Access PDU (AKF, AID, and the SZMIC flag controlling TransMIC length).
struct LowerTransportAccessHeader {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
}

struct NativeProvisioningRun {
    let attentionDuration: Int
    let statePath: String
    let appendsToExistingState: Bool
    let meshUUID: String
    let netKey: [UInt8]
    let appKey: [UInt8]
    let keyIndex: Int
    let flags: Int
    let ivIndex: UInt32
    let unicastAddress: UInt16
    let sourceAddress: UInt16
    let provisionerKeyPair: NativeProvisioningKeyPair
    let provisionerRandom: [UInt8]
}

struct NativeJoinCaptureRun {
    let captureStatePath: String
    let localName: String
    let deviceUUID: [UInt8]
    let elementCount: Int
    let deviceKeyPair: NativeProvisioningKeyPair
    let deviceRandom: [UInt8]
}

/// Result of preparing a mesh-proxy monitor session. Replaces a 4-tuple that
/// tripped SwiftLint's large_tuple rule.
struct NativeMeshMonitorPreparation {
    let requiredProxyNetworkId: [UInt8]
    let decodeMaterial: NativeDecodeMaterial
    let metadata: [String: Any]
    let filterProxyPdu: [UInt8]
}
