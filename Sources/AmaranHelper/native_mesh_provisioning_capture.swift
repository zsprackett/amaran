import Foundation

enum NativeProvisioneeCaptureSessionState: String {
    case awaitingInvite
    case awaitingStart
    case awaitingProvisionerPublicKey
    case awaitingProvisionerConfirmation
    case awaitingProvisionerRandom
    case awaitingProvisioningData
    case complete
    case failed
}

struct NativeProvisioneeCaptureResult: Equatable {
    let state: NativeProvisioneeCaptureSessionState
    let outgoingPdus: [[UInt8]]
    let completed: Bool
    let failedErrorName: String?
    let capturedData: NativeProvisioningDataPlaintext?
}

struct NativeProvisioneeCaptureSession {
    let deviceKeyPair: NativeProvisioningKeyPair
    let deviceRandom: [UInt8]
    let capabilitiesPdu: [UInt8]

    private(set) var state: NativeProvisioneeCaptureSessionState = .awaitingInvite
    private(set) var capturedData: NativeProvisioningDataPlaintext?
    private(set) var deviceKey: [UInt8]?

    private var invitePdu: [UInt8]?
    private var startPdu: [UInt8]?
    private var provisionerPublicKey: [UInt8]?
    private var provisionerConfirmationPdu: [UInt8]?
    private var confirmationKey: [UInt8]?
    private var provisioningSecrets: NativeProvisioningSecrets?

    init(
        deviceKeyPair: NativeProvisioningKeyPair,
        deviceRandom: [UInt8],
        elementCount: Int = 1
    ) throws {
        guard deviceRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("device random must be 16 bytes")
        }
        self.deviceKeyPair = deviceKeyPair
        self.deviceRandom = deviceRandom
        self.capabilitiesPdu = try NativeMeshProvisioning.provisioningCapabilities(elementCount: elementCount)
    }

    mutating func receive(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let pduType = pdu.first else {
            throw NativeMeshProvisioningError.invalidLength("incoming provisioning PDU is empty")
        }
        if pduType == NativeMeshProvisioning.provisioningFailedType {
            state = .failed
            let errorCode = pdu.dropFirst().first ?? 0
            return result(
                outgoingPdus: [],
                failedErrorName: NativeMeshProvisioning.provisioningFailedErrorName(errorCode)
            )
        }

        switch state {
        case .awaitingInvite:
            return try handleInvite(pdu)
        case .awaitingStart:
            return try handleStart(pdu)
        case .awaitingProvisionerPublicKey:
            return try handleProvisionerPublicKey(pdu)
        case .awaitingProvisionerConfirmation:
            return try handleProvisionerConfirmation(pdu)
        case .awaitingProvisionerRandom:
            return try handleProvisionerRandom(pdu)
        case .awaitingProvisioningData:
            return try handleProvisioningData(pdu)
        case .complete:
            throw NativeMeshProvisioningError.invalidParameter("provisionee session already completed")
        case .failed:
            throw NativeMeshProvisioningError.invalidParameter("provisionee session already failed")
        }
    }

    private mutating func handleInvite(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard pdu.count == 2, pdu[0] == NativeMeshProvisioning.provisioningInviteType else {
            throw NativeMeshProvisioningError.invalidParameter("expected Provisioning Invite PDU")
        }
        invitePdu = pdu
        state = .awaitingStart
        return result(outgoingPdus: [capabilitiesPdu], failedErrorName: nil)
    }

    private mutating func handleStart(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let start = NativeMeshProvisioning.provisioningStartSummary(pdu) else {
            throw NativeMeshProvisioningError.invalidParameter("expected Provisioning Start PDU")
        }
        guard start["algorithm_name"] as? String == "fips_p256_elliptic_curve" else {
            throw NativeMeshProvisioningError.invalidParameter("unsupported provisioning algorithm")
        }
        guard start["public_key_name"] as? String == "in_band" else {
            throw NativeMeshProvisioningError.invalidParameter("out-of-band public key is not supported")
        }
        guard start["authentication_method_name"] as? String == "no_oob" else {
            throw NativeMeshProvisioningError.invalidParameter("only no-OOB provisioning capture is supported")
        }
        startPdu = pdu
        state = .awaitingProvisionerPublicKey
        return result(outgoingPdus: [], failedErrorName: nil)
    }

    private mutating func handleProvisionerPublicKey(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let invitePdu, let startPdu else {
            throw NativeMeshProvisioningError.invalidParameter("provisionee session is missing invite/start state")
        }
        let publicKey = try NativeMeshProvisioning.publicKeyValuePdu(pdu)
        let inputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: publicKey,
            devicePublicKey: deviceKeyPair.publicKey
        )
        let ecdhSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: deviceKeyPair.privateKey,
            peerPublicKey: publicKey
        )
        let salt = try NativeMeshProvisioning.confirmationSalt(confirmationInputs: inputs)
        let key = try NativeMeshProvisioning.confirmationKey(ecdhSecret: ecdhSecret, confirmationSalt: salt)
        provisionerPublicKey = publicKey
        confirmationKey = key
        state = .awaitingProvisionerConfirmation
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningPublicKey(deviceKeyPair.publicKey)],
            failedErrorName: nil
        )
    }

    private mutating func handleProvisionerConfirmation(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        _ = try NativeMeshProvisioning.confirmationValuePdu(pdu)
        provisionerConfirmationPdu = pdu
        guard let confirmationKey else {
            throw NativeMeshProvisioningError.invalidParameter("confirmation key is missing")
        }
        let confirmation = try NativeMeshProvisioning.confirmationValue(
            confirmationKey: confirmationKey,
            random: deviceRandom,
            authValue: NativeMeshProvisioning.authValueNoOob()
        )
        state = .awaitingProvisionerRandom
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningConfirmation(confirmation)],
            failedErrorName: nil
        )
    }

    private mutating func handleProvisionerRandom(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let provisionerConfirmationPdu, let confirmationKey, let invitePdu, let startPdu,
            let provisionerPublicKey else {
            throw NativeMeshProvisioningError.invalidParameter("provisionee session is missing confirmation state")
        }
        let provisionerRandom = try NativeMeshProvisioning.randomValuePdu(pdu)
        let provisionerRandomPdu = try NativeMeshProvisioning.provisioningRandom(provisionerRandom)
        guard try NativeMeshProvisioning.verifyConfirmationPdu(
            confirmationPdu: provisionerConfirmationPdu,
            randomPdu: provisionerRandomPdu,
            confirmationKey: confirmationKey,
            authValue: NativeMeshProvisioning.authValueNoOob()
        ) else {
            throw NativeMeshProvisioningError.invalidParameter(
                "provisioner confirmation did not match provisioner random")
        }
        let inputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: provisionerPublicKey,
            devicePublicKey: deviceKeyPair.publicKey
        )
        let confirmationSalt = try NativeMeshProvisioning.confirmationSalt(confirmationInputs: inputs)
        let ecdhSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: deviceKeyPair.privateKey,
            peerPublicKey: provisionerPublicKey
        )
        let secrets = try NativeMeshProvisioning.provisioningSecrets(
            ecdhSecret: ecdhSecret,
            confirmationSalt: confirmationSalt,
            provisionerRandom: provisionerRandom,
            deviceRandom: deviceRandom
        )
        provisioningSecrets = secrets
        deviceKey = secrets.deviceKey
        state = .awaitingProvisioningData
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningRandom(deviceRandom)],
            failedErrorName: nil
        )
    }

    private mutating func handleProvisioningData(_ pdu: [UInt8]) throws -> NativeProvisioneeCaptureResult {
        guard let provisioningSecrets else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning secrets are missing")
        }
        let plaintext = try NativeMeshProvisioning.decryptProvisioningData(
            pdu,
            sessionKey: provisioningSecrets.sessionKey,
            sessionNonce: provisioningSecrets.sessionNonce
        )
        capturedData = plaintext
        state = .complete
        return result(
            outgoingPdus: [[NativeMeshProvisioning.provisioningCompleteType]],
            failedErrorName: nil
        )
    }

    private func result(
        outgoingPdus: [[UInt8]],
        failedErrorName: String?
    ) -> NativeProvisioneeCaptureResult {
        NativeProvisioneeCaptureResult(
            state: state,
            outgoingPdus: outgoingPdus,
            completed: state == .complete,
            failedErrorName: failedErrorName,
            capturedData: capturedData
        )
    }
}
