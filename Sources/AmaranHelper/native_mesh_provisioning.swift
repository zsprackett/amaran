import CryptoKit
import Foundation
import Security

enum NativeMeshProvisioningError: Error, CustomStringConvertible {
    case invalidParameter(String)
    case invalidLength(String)
    case randomGenerationFailed(Int32)

    var description: String {
        switch self {
        case .invalidParameter(let value):
            return "invalid provisioning parameter: \(value)"
        case .invalidLength(let value):
            return "invalid provisioning length: \(value)"
        case .randomGenerationFailed(let status):
            return "provisioning random generation failed: \(status)"
        }
    }
}

struct NativeProvisioningSecrets: Equatable {
    let confirmationSalt: [UInt8]
    let confirmationKey: [UInt8]
    let provisioningSalt: [UInt8]
    let sessionKey: [UInt8]
    let sessionNonce: [UInt8]
    let deviceKey: [UInt8]
}

struct NativeProvisioningDataEncrypted: Equatable {
    let provisioningData: [UInt8]
    let encryptedProvisioningData: [UInt8]
    let provisioningDataMic: [UInt8]
    let provisioningDataPdu: [UInt8]
}

struct NativeProvisioningKeyPair {
    let privateKey: P256.KeyAgreement.PrivateKey
    let publicKey: [UInt8]
}

struct NativeNoOobProvisioningTranscript: Equatable {
    let invitePdu: [UInt8]
    let capabilitiesPdu: [UInt8]
    let startPdu: [UInt8]
    let provisionerPublicKey: [UInt8]
    let devicePublicKey: [UInt8]
    let provisionerPublicKeyPdu: [UInt8]
    let provisionerConfirmation: [UInt8]
    let provisionerConfirmationPdu: [UInt8]
    let expectedDeviceConfirmation: [UInt8]
    let expectedDeviceConfirmationPdu: [UInt8]
    let provisionerRandom: [UInt8]
    let deviceRandom: [UInt8]
    let provisionerRandomPdu: [UInt8]
    let confirmationInputs: [UInt8]
    let secrets: NativeProvisioningSecrets
    let encryptedProvisioningData: NativeProvisioningDataEncrypted
}

struct NativeProvisioningDataPlaintext: Equatable {
    let networkKey: [UInt8]
    let keyIndex: Int
    let flags: Int
    let ivIndex: UInt32
    let unicastAddress: UInt16
}

/// Provisioning Data inputs that are encrypted into the Provisioning Data PDU
/// (NetKey, NetKeyIndex, flags, IV Index, and the assigned unicast address).
struct NativeProvisioningDataInput {
    let networkKey: [UInt8]
    let keyIndex: Int
    let flags: Int
    let ivIndex: UInt32
    let unicastAddress: UInt16
}

/// Provisioning PDUs exchanged before key agreement (Invite and Capabilities).
struct NativeProvisioningHandshakePdus {
    let invitePdu: [UInt8]
    let capabilitiesPdu: [UInt8]
}

/// Provisioner/device public keys plus the derived ECDH shared secret.
struct NativeProvisioningKeyAgreement {
    let provisionerPublicKey: [UInt8]
    let devicePublicKey: [UInt8]
    let ecdhSecret: [UInt8]
}

/// Provisioner and device provisioning random values.
struct NativeProvisioningRandoms {
    let provisionerRandom: [UInt8]
    let deviceRandom: [UInt8]
}

struct NativeMeshProvisioning {
    static let proxyPduType = UInt8(0x03)
    static let proxySarComplete = UInt8(0x00)
    static let proxySarFirst = UInt8(0x40)
    static let proxySarContinuation = UInt8(0x80)
    static let proxySarLast = UInt8(0xc0)
    static let proxyMessageTypeMask = UInt8(0x3f)
    static let proxySarMask = UInt8(0xc0)
    static let provisioningInviteType = UInt8(0x00)
    static let provisioningCapabilitiesType = UInt8(0x01)
    static let provisioningStartType = UInt8(0x02)
    static let provisioningPublicKeyType = UInt8(0x03)
    static let provisioningConfirmationType = UInt8(0x05)
    static let provisioningRandomType = UInt8(0x06)
    static let provisioningDataType = UInt8(0x07)
    static let provisioningCompleteType = UInt8(0x08)
    static let provisioningFailedType = UInt8(0x09)
    static let algorithmFipsP256EllipticCurve = UInt8(0x00)
    static let publicKeyInBand = UInt8(0x00)
    static let publicKeyOob = UInt8(0x01)
    static let authenticationNoOob = UInt8(0x00)
    static let authenticationStaticOob = UInt8(0x01)
    static let authenticationOutputOob = UInt8(0x02)
    static let authenticationInputOob = UInt8(0x03)

    static func oobInfoFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "other"),
            (0x0002, "electronic_or_uri"),
            (0x0004, "machine_readable_2d_code"),
            (0x0008, "bar_code"),
            (0x0010, "nfc"),
            (0x0020, "number"),
            (0x0040, "string"),
            (0x0800, "on_box"),
            (0x1000, "inside_box"),
            (0x2000, "on_piece_of_paper"),
            (0x4000, "inside_manual"),
            (0x8000, "on_device")
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func provisioningServiceDataSummary(_ bytes: [UInt8]) -> [String: Any] {
        var result: [String: Any] = [
            "bytes": bytes.count
        ]

        guard bytes.count >= 16 else {
            result["format"] = "short"
            return result
        }

        result["device_uuid"] = NativeMeshCrypto.hex(Array(bytes[0..<16]))

        if bytes.count >= 18 {
            let oobInfo = (UInt16(bytes[16]) << 8) | UInt16(bytes[17])
            result["oob_info"] = String(format: "0x%04x", oobInfo)
            result["oob_info_value"] = Int(oobInfo)
            result["oob_info_flags"] = oobInfoFlags(oobInfo)
        }

        if bytes.count >= 22 {
            result["uri_hash"] = NativeMeshCrypto.hex(Array(bytes[18..<22]))
        }

        if bytes.count != 18 && bytes.count != 22 {
            result["format"] = "unexpected"
        }
        return result
    }

    static func provisioningInvite(attentionDuration: Int) throws -> [UInt8] {
        guard (0...255).contains(attentionDuration) else {
            throw NativeMeshProvisioningError.invalidParameter("attention duration must be between 0 and 255")
        }
        return [provisioningInviteType, UInt8(attentionDuration)]
    }

    static func provisioningCapabilities(elementCount: Int = 1) throws -> [UInt8] {
        guard (1...255).contains(elementCount) else {
            throw NativeMeshProvisioningError.invalidParameter("element count must be 1..255")
        }
        return [
            provisioningCapabilitiesType,
            UInt8(elementCount),
            0x00, 0x01,
            publicKeyInBand,
            0x00,
            0x00,
            0x00, 0x00,
            0x00,
            0x00, 0x00
        ]
    }

    static func completeProxyPdu(provisioningPdu: [UInt8]) -> [UInt8] {
        [proxyPduType] + provisioningPdu
    }

    static func segmentedProxyPdus(
        provisioningPdu: [UInt8],
        maxSegmentPayloadBytes: Int
    ) throws -> [[UInt8]] {
        guard maxSegmentPayloadBytes > 0 else {
            throw NativeMeshProvisioningError.invalidParameter("max segment payload bytes must be positive")
        }
        guard !provisioningPdu.isEmpty else {
            throw NativeMeshProvisioningError.invalidLength("Provisioning PDU must not be empty")
        }
        guard provisioningPdu.count > maxSegmentPayloadBytes else {
            return [completeProxyPdu(provisioningPdu: provisioningPdu)]
        }

        var segments: [[UInt8]] = []
        var offset = 0
        while offset < provisioningPdu.count {
            let next = min(offset + maxSegmentPayloadBytes, provisioningPdu.count)
            let payload = Array(provisioningPdu[offset..<next])
            let sar: UInt8
            if offset == 0 {
                sar = proxySarFirst
            } else if next == provisioningPdu.count {
                sar = proxySarLast
            } else {
                sar = proxySarContinuation
            }
            segments.append([sar | proxyPduType] + payload)
            offset = next
        }
        return segments
    }

    static func reassembleProxyPdus(_ proxyPdus: [[UInt8]]) throws -> [UInt8] {
        guard !proxyPdus.isEmpty else {
            throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment list must not be empty")
        }
        if proxyPdus.count == 1 {
            guard let header = proxyPdus[0].first else {
                throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment must not be empty")
            }
            guard (header & proxySarMask) == proxySarComplete, (header & proxyMessageTypeMask) == proxyPduType else {
                throw NativeMeshProvisioningError.invalidParameter(
                    "single Proxy PDU must be complete provisioning type")
            }
            return Array(proxyPdus[0].dropFirst())
        }

        var result: [UInt8] = []
        for (index, segment) in proxyPdus.enumerated() {
            try validateProxySegmentSar(segment, index: index, count: proxyPdus.count)
            result += Array(segment.dropFirst())
        }
        return result
    }

    private static func validateProxySegmentSar(_ segment: [UInt8], index: Int, count: Int) throws {
        guard let header = segment.first else {
            throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment must not be empty")
        }
        guard (header & proxyMessageTypeMask) == proxyPduType else {
            throw NativeMeshProvisioningError.invalidParameter("Proxy PDU segment is not provisioning type")
        }
        let sar = header & proxySarMask
        if index == 0 {
            guard sar == proxySarFirst else {
                throw NativeMeshProvisioningError.invalidParameter("first Proxy PDU segment has invalid SAR")
            }
        } else if index == count - 1 {
            guard sar == proxySarLast else {
                throw NativeMeshProvisioningError.invalidParameter("last Proxy PDU segment has invalid SAR")
            }
        } else {
            guard sar == proxySarContinuation else {
                throw NativeMeshProvisioningError.invalidParameter("continuation Proxy PDU segment has invalid SAR")
            }
        }
    }

    static func provisioningStart(
        algorithm: Int,
        publicKey: Int,
        authenticationMethod: Int,
        authenticationAction: Int,
        authenticationSize: Int
    ) throws -> [UInt8] {
        guard (0...255).contains(algorithm) else {
            throw NativeMeshProvisioningError.invalidParameter("algorithm must be between 0 and 255")
        }
        guard publicKey == Int(publicKeyInBand) || publicKey == Int(publicKeyOob) else {
            throw NativeMeshProvisioningError.invalidParameter("public key must be 0 or 1")
        }
        guard (Int(authenticationNoOob)...Int(authenticationInputOob)).contains(authenticationMethod) else {
            throw NativeMeshProvisioningError.invalidParameter("authentication method must be between 0 and 3")
        }
        guard (0...255).contains(authenticationAction) else {
            throw NativeMeshProvisioningError.invalidParameter("authentication action must be between 0 and 255")
        }
        guard (0...255).contains(authenticationSize) else {
            throw NativeMeshProvisioningError.invalidParameter("authentication size must be between 0 and 255")
        }

        return [
            provisioningStartType,
            UInt8(algorithm),
            UInt8(publicKey),
            UInt8(authenticationMethod),
            UInt8(authenticationAction),
            UInt8(authenticationSize)
        ]
    }

    static func noOobProvisioningStart(capabilitiesPdu: [UInt8]) throws -> [UInt8] {
        guard capabilitiesPdu.count == 12, capabilitiesPdu[0] == provisioningCapabilitiesType else {
            throw NativeMeshProvisioningError.invalidParameter("capabilities PDU must be 12 bytes and type 0x01")
        }
        let algorithms = bigEndianUInt16(capabilitiesPdu, offset: 2)
        guard (algorithms & 0x0001) != 0 else {
            throw NativeMeshProvisioningError.invalidParameter("capabilities do not support FIPS P-256 Elliptic Curve")
        }
        return try provisioningStart(
            algorithm: Int(algorithmFipsP256EllipticCurve),
            publicKey: Int(publicKeyInBand),
            authenticationMethod: Int(authenticationNoOob),
            authenticationAction: 0,
            authenticationSize: 0
        )
    }

    static func generateProvisioningRandom() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NativeMeshProvisioningError.randomGenerationFailed(status)
        }
        return bytes
    }

    static func provisioningPublicKey(_ publicKeyXY: [UInt8]) throws -> [UInt8] {
        guard publicKeyXY.count == 64 else {
            throw NativeMeshProvisioningError.invalidParameter("public key must be 64 bytes of X and Y coordinates")
        }
        return [provisioningPublicKeyType] + publicKeyXY
    }

    static func generateProvisionerKeyPair() throws -> NativeProvisioningKeyPair {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return NativeProvisioningKeyPair(
            privateKey: privateKey,
            publicKey: try publicKeyCoordinates(privateKey.publicKey)
        )
    }

    static func bigEndianUInt16(_ bytes: [UInt8], offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}
