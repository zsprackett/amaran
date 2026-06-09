import Foundation

struct MeshKeyMaterial: Equatable {
    let nid: UInt8
    let encryptionKey: [UInt8]
    let privacyKey: [UInt8]
}

/// Shared addressing/context fields that mirror the Bluetooth Mesh PDU spec
/// (IV Index, Sequence, SRC and DST). Bundled to keep crypto signatures small.
struct MeshMessageContext: Equatable {
    var ivIndex: UInt32
    var sequence: UInt32
    var source: UInt16
    var destination: UInt16
}

/// Network-layer encryption inputs: addressing context, key material, and the
/// CTL/TTL control header bits.
struct NetworkPduInput {
    var context: MeshMessageContext
    var keyMaterial: MeshKeyMaterial
    var ctl: UInt8
    var ttl: UInt8
}

struct AesCcmResult: Equatable {
    let ciphertext: [UInt8]
    let mic: [UInt8]
}

struct NetworkPduResult: Equatable {
    let nonce: [UInt8]
    let encryptedDstAndTransportPdu: [UInt8]
    let netMic: [UInt8]
    let privacyPlaintext: [UInt8]
    let pecb: [UInt8]
    let obfuscatedCtlTtlSeqSrc: [UInt8]
    let networkPdu: [UInt8]
    let proxyPdu: [UInt8]
}

struct UpperTransportAccessResult: Equatable {
    let nonce: [UInt8]
    let encAccessMessage: [UInt8]
    let transMic: [UInt8]
    let upperTransportPdu: [UInt8]
}

struct LowerTransportAccessResult: Equatable {
    let header: UInt8
    let lowerTransportPdu: [UInt8]
}

struct LowerTransportSegmentedAccessSegment: Equatable {
    let header: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segO: UInt8
    let segN: UInt8
    let segment: [UInt8]
    let lowerTransportPdu: [UInt8]
}

struct LowerTransportSegmentedAccessResult: Equatable {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segN: UInt8
    let segments: [LowerTransportSegmentedAccessSegment]

    var lowerTransportPdus: [[UInt8]] {
        segments.map(\.lowerTransportPdu)
    }
}

struct LowerTransportSegmentedAccessDecoded: Equatable {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let segO: UInt8
    let segN: UInt8
    let segment: [UInt8]
}

struct LowerTransportSegmentedAccessReassembled: Equatable {
    let akf: Bool
    let aid: UInt8
    let szmic: Bool
    let seqZero: UInt16
    let upperTransportPdu: [UInt8]
}

struct LowerTransportSegmentAckDecoded: Equatable {
    let obo: Bool
    let seqZero: UInt16
    let ackedSegments: UInt32

    func acknowledges(segment: UInt8) -> Bool {
        guard segment < 32 else { return false }
        return (ackedSegments & (UInt32(1) << UInt32(segment))) != 0
    }

    func acknowledgesAll(segN: UInt8) -> Bool {
        guard segN < 32 else { return false }
        let expected = segN == 31 ? UInt32.max : (UInt32(1) << UInt32(segN + 1)) - 1
        return (ackedSegments & expected) == expected
    }
}

struct ApplicationAccessProxyPduResult: Equatable {
    let aid: UInt8
    let accessMessage: [UInt8]
    let upperTransport: UpperTransportAccessResult
    let lowerTransport: LowerTransportAccessResult
    let network: NetworkPduResult
}

struct DeviceAccessProxyPduResult: Equatable {
    let accessMessage: [UInt8]
    let upperTransport: UpperTransportAccessResult
    let lowerTransport: LowerTransportAccessResult
    let network: NetworkPduResult
}

struct SegmentedDeviceAccessProxyPduResult: Equatable {
    let accessMessage: [UInt8]
    let upperTransport: UpperTransportAccessResult
    let lowerTransport: LowerTransportSegmentedAccessResult
    let networks: [NetworkPduResult]

    var proxyPdus: [[UInt8]] {
        networks.map(\.proxyPdu)
    }
}

struct DeobfuscatedNetworkHeader: Equatable {
    let ctl: UInt8
    let ttl: UInt8
    let sequence: UInt32
    let source: UInt16
}

struct NetworkPduDecoded: Equatable {
    let ivi: UInt8
    let nid: UInt8
    let ctl: UInt8
    let ttl: UInt8
    let sequence: UInt32
    let source: UInt16
    let destination: UInt16
    let transportPdu: [UInt8]
    let netMic: [UInt8]
}

struct LowerTransportAccessDecoded: Equatable {
    let akf: Bool
    let aid: UInt8
    let upperTransportPdu: [UInt8]
}

struct UpperTransportAccessDecoded: Equatable {
    let nonce: [UInt8]
    let accessMessage: [UInt8]
    let transMic: [UInt8]
}
