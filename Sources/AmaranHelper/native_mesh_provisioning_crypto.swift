import CryptoKit
import Foundation
import Security

extension NativeMeshProvisioning {
    static func ecdhSecret(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: [UInt8]
    ) throws -> [UInt8] {
        try validatePublicKey(peerPublicKey, label: "peer public key")
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: [0x04] + peerPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return sharedSecret.withUnsafeBytes { buffer in
            Array(buffer)
        }
    }

    static func provisioningConfirmation(_ confirmation: [UInt8]) throws -> [UInt8] {
        try validateAesKey(confirmation, label: "confirmation value")
        return [provisioningConfirmationType] + confirmation
    }

    static func provisioningRandom(_ random: [UInt8]) throws -> [UInt8] {
        guard random.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("random value must be 16 bytes")
        }
        return [provisioningRandomType] + random
    }

    static func confirmationValuePdu(_ pdu: [UInt8]) throws -> [UInt8] {
        try provisioningPayload(
            pdu,
            expectedType: provisioningConfirmationType,
            payloadLength: 16,
            label: "Confirmation PDU"
        )
    }

    static func randomValuePdu(_ pdu: [UInt8]) throws -> [UInt8] {
        try provisioningPayload(
            pdu,
            expectedType: provisioningRandomType,
            payloadLength: 16,
            label: "Random PDU"
        )
    }

    static func publicKeyValuePdu(_ pdu: [UInt8]) throws -> [UInt8] {
        try provisioningPayload(
            pdu,
            expectedType: provisioningPublicKeyType,
            payloadLength: 64,
            label: "Public Key PDU"
        )
    }

    static func verifyConfirmationPdu(
        confirmationPdu: [UInt8],
        randomPdu: [UInt8],
        confirmationKey: [UInt8],
        authValue: [UInt8]
    ) throws -> Bool {
        let provided = try confirmationValuePdu(confirmationPdu)
        let random = try randomValuePdu(randomPdu)
        let expected = try confirmationValue(
            confirmationKey: confirmationKey,
            random: random,
            authValue: authValue
        )
        return provided == expected
    }

    static func confirmationInputs(
        invitePdu: [UInt8],
        capabilitiesPdu: [UInt8],
        startPdu: [UInt8],
        provisionerPublicKey: [UInt8],
        devicePublicKey: [UInt8]
    ) throws -> [UInt8] {
        guard invitePdu.count == 2, invitePdu[0] == provisioningInviteType else {
            throw NativeMeshProvisioningError.invalidLength("Invite PDU must be 2 bytes and type 0x00")
        }
        guard capabilitiesPdu.count == 12, capabilitiesPdu[0] == provisioningCapabilitiesType else {
            throw NativeMeshProvisioningError.invalidLength("Capabilities PDU must be 12 bytes and type 0x01")
        }
        guard startPdu.count == 6, startPdu[0] == provisioningStartType else {
            throw NativeMeshProvisioningError.invalidLength("Start PDU must be 6 bytes and type 0x02")
        }
        try validatePublicKey(provisionerPublicKey, label: "provisioner public key")
        try validatePublicKey(devicePublicKey, label: "device public key")

        return Array(invitePdu.dropFirst())
            + Array(capabilitiesPdu.dropFirst())
            + Array(startPdu.dropFirst())
            + provisionerPublicKey
            + devicePublicKey
    }

    static func authValueNoOob() -> [UInt8] {
        [UInt8](repeating: 0, count: 16)
    }

    static func confirmationSalt(confirmationInputs: [UInt8]) throws -> [UInt8] {
        try NativeMeshCrypto.aesCmac(key: NativeMeshCrypto.zeroKey, message: confirmationInputs)
    }

    static func confirmationKey(ecdhSecret: [UInt8], confirmationSalt: [UInt8]) throws -> [UInt8] {
        try validateEcdhSecret(ecdhSecret)
        try validateAesKey(confirmationSalt, label: "confirmation salt")
        return try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: confirmationSalt,
            p: NativeMeshCrypto.ascii("prck")
        )
    }

    static func confirmationValue(confirmationKey: [UInt8], random: [UInt8], authValue: [UInt8]) throws -> [UInt8] {
        try validateAesKey(confirmationKey, label: "confirmation key")
        guard random.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("random value must be 16 bytes")
        }
        guard authValue.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("auth value must be 16 bytes")
        }
        return try NativeMeshCrypto.aesCmac(key: confirmationKey, message: random + authValue)
    }

    static func provisioningSalt(
        confirmationSalt: [UInt8],
        provisionerRandom: [UInt8],
        deviceRandom: [UInt8]
    ) throws -> [UInt8] {
        try validateAesKey(confirmationSalt, label: "confirmation salt")
        guard provisionerRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("provisioner random must be 16 bytes")
        }
        guard deviceRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("device random must be 16 bytes")
        }
        return try NativeMeshCrypto.aesCmac(
            key: NativeMeshCrypto.zeroKey,
            message: confirmationSalt + provisionerRandom + deviceRandom
        )
    }

    static func provisioningSecrets(
        ecdhSecret: [UInt8],
        confirmationSalt: [UInt8],
        provisionerRandom: [UInt8],
        deviceRandom: [UInt8]
    ) throws -> NativeProvisioningSecrets {
        try validateEcdhSecret(ecdhSecret)
        try validateAesKey(confirmationSalt, label: "confirmation salt")
        let salt = try provisioningSalt(
            confirmationSalt: confirmationSalt,
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom
        )
        let sessionKey = try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: salt,
            p: NativeMeshCrypto.ascii("prsk")
        )
        let sessionNonceFull = try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: salt,
            p: NativeMeshCrypto.ascii("prsn")
        )
        let deviceKey = try NativeMeshCrypto.k1(
            n: ecdhSecret,
            salt: salt,
            p: NativeMeshCrypto.ascii("prdk")
        )
        return NativeProvisioningSecrets(
            confirmationSalt: confirmationSalt,
            confirmationKey: try confirmationKey(ecdhSecret: ecdhSecret, confirmationSalt: confirmationSalt),
            provisioningSalt: salt,
            sessionKey: sessionKey,
            sessionNonce: Array(sessionNonceFull.suffix(13)),
            deviceKey: deviceKey
        )
    }

    static func validateAesKey(_ key: [UInt8], label: String) throws {
        guard key.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("\(label) must be 16 bytes")
        }
    }

    static func validateEcdhSecret(_ secret: [UInt8]) throws {
        guard secret.count == 32 else {
            throw NativeMeshProvisioningError.invalidLength("ECDH secret must be 32 bytes")
        }
    }

    static func validatePublicKey(_ publicKey: [UInt8], label: String) throws {
        guard publicKey.count == 64 else {
            throw NativeMeshProvisioningError.invalidLength("\(label) must be 64 bytes")
        }
    }

    static func provisioningPayload(
        _ pdu: [UInt8],
        expectedType: UInt8,
        payloadLength: Int,
        label: String
    ) throws -> [UInt8] {
        guard pdu.count == payloadLength + 1, pdu.first == expectedType else {
            throw NativeMeshProvisioningError.invalidLength(
                "\(label) must be \(payloadLength + 1) bytes and type 0x\(String(format: "%02x", expectedType))"
            )
        }
        return Array(pdu.dropFirst())
    }

    static func publicKeyCoordinates(_ publicKey: P256.KeyAgreement.PublicKey) throws -> [UInt8] {
        let x963 = Array(publicKey.x963Representation)
        guard x963.count == 65, x963.first == 0x04 else {
            throw NativeMeshProvisioningError.invalidLength("P-256 public key must be 65-byte uncompressed X9.63")
        }
        return Array(x963.dropFirst())
    }
}
