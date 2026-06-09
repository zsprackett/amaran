import CryptoKit
import Foundation

extension NativeMeshProvisioning {
    static func provisioningData(
        networkKey: [UInt8],
        keyIndex: Int,
        flags: Int,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws -> [UInt8] {
        try validateAesKey(networkKey, label: "network key")
        guard (0...0x0fff).contains(keyIndex) else {
            throw NativeMeshProvisioningError.invalidParameter("key index must be a 12-bit value")
        }
        guard (0...0xff).contains(flags) else {
            throw NativeMeshProvisioningError.invalidParameter("flags must be between 0 and 255")
        }
        guard (1...0x7fff).contains(Int(unicastAddress)) else {
            throw NativeMeshProvisioningError.invalidParameter("unicast address must be a non-zero unicast address")
        }

        return networkKey
            + bigEndianBytes(UInt64(keyIndex), count: 2)
            + [UInt8(flags)]
            + bigEndianBytes(UInt64(ivIndex), count: 4)
            + bigEndianBytes(UInt64(unicastAddress), count: 2)
    }

    static func encryptedProvisioningData(
        sessionKey: [UInt8],
        sessionNonce: [UInt8],
        data provisioningDataInput: NativeProvisioningDataInput
    ) throws -> NativeProvisioningDataEncrypted {
        try validateAesKey(sessionKey, label: "session key")
        guard sessionNonce.count == 13 else {
            throw NativeMeshProvisioningError.invalidLength("session nonce must be 13 bytes")
        }
        let data = try provisioningData(
            networkKey: provisioningDataInput.networkKey,
            keyIndex: provisioningDataInput.keyIndex,
            flags: provisioningDataInput.flags,
            ivIndex: provisioningDataInput.ivIndex,
            unicastAddress: provisioningDataInput.unicastAddress
        )
        let encrypted = try NativeMeshCrypto.aesCcmEncrypt(
            key: sessionKey,
            nonce: sessionNonce,
            plaintext: data,
            micLength: 8
        )
        let pdu = [UInt8(0x07)] + encrypted.ciphertext + encrypted.mic
        return NativeProvisioningDataEncrypted(
            provisioningData: data,
            encryptedProvisioningData: encrypted.ciphertext,
            provisioningDataMic: encrypted.mic,
            provisioningDataPdu: pdu
        )
    }

    static func decryptProvisioningData(
        _ pdu: [UInt8],
        sessionKey: [UInt8],
        sessionNonce: [UInt8]
    ) throws -> NativeProvisioningDataPlaintext {
        try validateAesKey(sessionKey, label: "session key")
        guard sessionNonce.count == 13 else {
            throw NativeMeshProvisioningError.invalidLength("session nonce must be 13 bytes")
        }
        guard pdu.count == 34, pdu[0] == provisioningDataType else {
            throw NativeMeshProvisioningError.invalidLength("Provisioning Data PDU must be 34 bytes and type 0x07")
        }
        let encrypted = Array(pdu[1..<26])
        let mic = Array(pdu[26..<34])
        let plaintext = try NativeMeshCrypto.aesCcmDecrypt(
            key: sessionKey,
            nonce: sessionNonce,
            ciphertext: encrypted,
            mic: mic
        )
        guard plaintext.count == 25 else {
            throw NativeMeshProvisioningError.invalidLength("Provisioning Data plaintext must be 25 bytes")
        }
        return NativeProvisioningDataPlaintext(
            networkKey: Array(plaintext[0..<16]),
            keyIndex: Int(bigEndianUInt16(plaintext, offset: 16)),
            flags: Int(plaintext[18]),
            ivIndex: UInt32(plaintext[19]) << 24
                | UInt32(plaintext[20]) << 16
                | UInt32(plaintext[21]) << 8
                | UInt32(plaintext[22]),
            unicastAddress: bigEndianUInt16(plaintext, offset: 23)
        )
    }

    static func noOobProvisioningTranscript(
        pdus: NativeProvisioningHandshakePdus,
        keyAgreement: NativeProvisioningKeyAgreement,
        randoms: NativeProvisioningRandoms,
        data provisioningDataInput: NativeProvisioningDataInput
    ) throws -> NativeNoOobProvisioningTranscript {
        let startPdu = try noOobProvisioningStart(capabilitiesPdu: pdus.capabilitiesPdu)
        let publicKeyPdu = try provisioningPublicKey(keyAgreement.provisionerPublicKey)
        let inputs = try confirmationInputs(
            invitePdu: pdus.invitePdu,
            capabilitiesPdu: pdus.capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: keyAgreement.provisionerPublicKey,
            devicePublicKey: keyAgreement.devicePublicKey
        )
        let salt = try confirmationSalt(confirmationInputs: inputs)
        let confirmations = try noOobConfirmations(
            keyAgreement: keyAgreement,
            randoms: randoms,
            confirmationSalt: salt
        )
        let secrets = try provisioningSecrets(
            ecdhSecret: keyAgreement.ecdhSecret,
            confirmationSalt: salt,
            provisionerRandom: randoms.provisionerRandom,
            deviceRandom: randoms.deviceRandom
        )
        let encryptedData = try encryptedProvisioningData(
            sessionKey: secrets.sessionKey,
            sessionNonce: secrets.sessionNonce,
            data: provisioningDataInput
        )

        return try noOobTranscript(
            pdus: pdus,
            startPdu: startPdu,
            publicKeyPdu: publicKeyPdu,
            keyAgreement: keyAgreement,
            confirmations: confirmations,
            randoms: randoms,
            inputs: inputs,
            secrets: secrets,
            encryptedData: encryptedData
        )
    }

    private static func noOobConfirmations(
        keyAgreement: NativeProvisioningKeyAgreement,
        randoms: NativeProvisioningRandoms,
        confirmationSalt salt: [UInt8]
    ) throws -> (provisioner: [UInt8], device: [UInt8]) {
        let key = try confirmationKey(ecdhSecret: keyAgreement.ecdhSecret, confirmationSalt: salt)
        let authValue = authValueNoOob()
        let provisionerConfirmation = try confirmationValue(
            confirmationKey: key,
            random: randoms.provisionerRandom,
            authValue: authValue
        )
        let deviceConfirmation = try confirmationValue(
            confirmationKey: key,
            random: randoms.deviceRandom,
            authValue: authValue
        )
        return (provisionerConfirmation, deviceConfirmation)
    }

    // swiftlint:disable:next function_parameter_count
    private static func noOobTranscript(
        pdus: NativeProvisioningHandshakePdus,
        startPdu: [UInt8],
        publicKeyPdu: [UInt8],
        keyAgreement: NativeProvisioningKeyAgreement,
        confirmations: (provisioner: [UInt8], device: [UInt8]),
        randoms: NativeProvisioningRandoms,
        inputs: [UInt8],
        secrets: NativeProvisioningSecrets,
        encryptedData: NativeProvisioningDataEncrypted
    ) throws -> NativeNoOobProvisioningTranscript {
        let invitePdu = pdus.invitePdu
        let capabilitiesPdu = pdus.capabilitiesPdu
        let provisionerPublicKey = keyAgreement.provisionerPublicKey
        let devicePublicKey = keyAgreement.devicePublicKey
        let provisionerConfirmation = confirmations.provisioner
        let deviceConfirmation = confirmations.device
        let provisionerRandom = randoms.provisionerRandom
        let deviceRandom = randoms.deviceRandom

        return NativeNoOobProvisioningTranscript(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: provisionerPublicKey,
            devicePublicKey: devicePublicKey,
            provisionerPublicKeyPdu: publicKeyPdu,
            provisionerConfirmation: provisionerConfirmation,
            provisionerConfirmationPdu: try provisioningConfirmation(provisionerConfirmation),
            expectedDeviceConfirmation: deviceConfirmation,
            expectedDeviceConfirmationPdu: try provisioningConfirmation(deviceConfirmation),
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom,
            provisionerRandomPdu: try provisioningRandom(provisionerRandom),
            confirmationInputs: inputs,
            secrets: secrets,
            encryptedProvisioningData: encryptedData
        )
    }

    static func noOobProvisioningTranscript(
        pdus: NativeProvisioningHandshakePdus,
        provisionerKeyPair: NativeProvisioningKeyPair,
        devicePublicKey: [UInt8],
        randoms: NativeProvisioningRandoms,
        data provisioningDataInput: NativeProvisioningDataInput
    ) throws -> NativeNoOobProvisioningTranscript {
        try noOobProvisioningTranscript(
            pdus: pdus,
            keyAgreement: NativeProvisioningKeyAgreement(
                provisionerPublicKey: provisionerKeyPair.publicKey,
                devicePublicKey: devicePublicKey,
                ecdhSecret: try ecdhSecret(
                    privateKey: provisionerKeyPair.privateKey,
                    peerPublicKey: devicePublicKey
                )
            ),
            randoms: randoms,
            data: provisioningDataInput
        )
    }

    static func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { index in
            UInt8((value >> UInt64((count - index - 1) * 8)) & 0xff)
        }
    }
}
