import CryptoKit
import Foundation

enum NativeNoOobProvisioningSessionState: String {
    case idle
    case awaitingCapabilities
    case awaitingDevicePublicKey
    case awaitingDeviceConfirmation
    case awaitingDeviceRandom
    case awaitingComplete
    case complete
    case failed
}

struct NativeNoOobProvisioningSessionResult: Equatable {
    let state: NativeNoOobProvisioningSessionState
    let outgoingPdus: [[UInt8]]
    let completed: Bool
    let failedErrorName: String?
}

struct NativeProvisioningProxyReassemblyResult: Equatable {
    let provisioningPdu: [UInt8]?
    let segmentCount: Int
    let pending: Bool
}

struct NativeProvisioningProxyPduReassembler {
    private(set) var segments: [[UInt8]] = []

    mutating func receive(_ proxyPdu: [UInt8]) throws -> NativeProvisioningProxyReassemblyResult {
        guard let header = proxyPdu.first else {
            throw NativeMeshProvisioningError.invalidLength("Proxy PDU segment must not be empty")
        }
        guard (header & NativeMeshProvisioning.proxyMessageTypeMask) == NativeMeshProvisioning.proxyPduType else {
            throw NativeMeshProvisioningError.invalidParameter("Proxy PDU segment is not provisioning type")
        }

        let sar = header & NativeMeshProvisioning.proxySarMask
        switch sar {
        case NativeMeshProvisioning.proxySarComplete:
            return receiveComplete(proxyPdu)
        case NativeMeshProvisioning.proxySarFirst:
            return try receiveFirst(proxyPdu)
        case NativeMeshProvisioning.proxySarContinuation:
            return try receiveContinuation(proxyPdu)
        case NativeMeshProvisioning.proxySarLast:
            return try receiveLast(proxyPdu)
        default:
            throw NativeMeshProvisioningError.invalidParameter("unknown Proxy PDU SAR")
        }
    }

    private mutating func receiveComplete(_ proxyPdu: [UInt8]) -> NativeProvisioningProxyReassemblyResult {
        segments = []
        return NativeProvisioningProxyReassemblyResult(
            provisioningPdu: Array(proxyPdu.dropFirst()),
            segmentCount: 1,
            pending: false
        )
    }

    private mutating func receiveFirst(_ proxyPdu: [UInt8]) throws -> NativeProvisioningProxyReassemblyResult {
        guard segments.isEmpty else {
            throw NativeMeshProvisioningError.invalidParameter("received first segment while reassembly is pending")
        }
        segments = [proxyPdu]
        return NativeProvisioningProxyReassemblyResult(
            provisioningPdu: nil,
            segmentCount: segments.count,
            pending: true
        )
    }

    private mutating func receiveContinuation(_ proxyPdu: [UInt8]) throws -> NativeProvisioningProxyReassemblyResult {
        guard !segments.isEmpty else {
            throw NativeMeshProvisioningError.invalidParameter(
                "received continuation segment without first segment")
        }
        segments.append(proxyPdu)
        return NativeProvisioningProxyReassemblyResult(
            provisioningPdu: nil,
            segmentCount: segments.count,
            pending: true
        )
    }

    private mutating func receiveLast(_ proxyPdu: [UInt8]) throws -> NativeProvisioningProxyReassemblyResult {
        guard !segments.isEmpty else {
            throw NativeMeshProvisioningError.invalidParameter("received last segment without first segment")
        }
        segments.append(proxyPdu)
        let completedSegments = segments
        segments = []
        return NativeProvisioningProxyReassemblyResult(
            provisioningPdu: try NativeMeshProvisioning.reassembleProxyPdus(completedSegments),
            segmentCount: completedSegments.count,
            pending: false
        )
    }
}

struct NativeNoOobProvisioningSession {
    let provisionerKeyPair: NativeProvisioningKeyPair
    let provisionerRandom: [UInt8]
    let networkKey: [UInt8]
    let keyIndex: Int
    let flags: Int
    let ivIndex: UInt32
    let unicastAddress: UInt16

    private(set) var state: NativeNoOobProvisioningSessionState = .idle
    private(set) var transcript: NativeNoOobProvisioningTranscript?

    private var invitePdu: [UInt8]?
    private var capabilitiesPdu: [UInt8]?
    private var devicePublicKey: [UInt8]?
    private var deviceConfirmationPdu: [UInt8]?
    private var confirmationKey: [UInt8]?

    init(
        provisionerKeyPair: NativeProvisioningKeyPair,
        provisionerRandom: [UInt8],
        networkKey: [UInt8],
        keyIndex: Int,
        flags: Int,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws {
        guard provisionerRandom.count == 16 else {
            throw NativeMeshProvisioningError.invalidLength("provisioner random must be 16 bytes")
        }
        self.provisionerKeyPair = provisionerKeyPair
        self.provisionerRandom = provisionerRandom
        self.networkKey = networkKey
        self.keyIndex = keyIndex
        self.flags = flags
        self.ivIndex = ivIndex
        self.unicastAddress = unicastAddress
        _ = try NativeMeshProvisioning.provisioningData(
            networkKey: networkKey,
            keyIndex: keyIndex,
            flags: flags,
            ivIndex: ivIndex,
            unicastAddress: unicastAddress
        )
    }

    mutating func start(attentionDuration: Int) throws -> [UInt8] {
        guard state == .idle else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning session already started")
        }
        let invite = try NativeMeshProvisioning.provisioningInvite(attentionDuration: attentionDuration)
        invitePdu = invite
        state = .awaitingCapabilities
        return invite
    }

    mutating func receive(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
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
        case .awaitingCapabilities:
            return try handleCapabilities(pdu)
        case .awaitingDevicePublicKey:
            return try handleDevicePublicKey(pdu)
        case .awaitingDeviceConfirmation:
            return try handleDeviceConfirmation(pdu)
        case .awaitingDeviceRandom:
            return try handleDeviceRandom(pdu)
        case .awaitingComplete:
            return try handleComplete(pdu)
        case .idle:
            throw NativeMeshProvisioningError.invalidParameter("provisioning session has not started")
        case .complete:
            throw NativeMeshProvisioningError.invalidParameter("provisioning session already completed")
        case .failed:
            throw NativeMeshProvisioningError.invalidParameter("provisioning session already failed")
        }
    }

    private mutating func handleCapabilities(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard invitePdu != nil else {
            throw NativeMeshProvisioningError.invalidParameter("Invite PDU is missing")
        }
        let startPdu = try NativeMeshProvisioning.noOobProvisioningStart(capabilitiesPdu: pdu)
        capabilitiesPdu = pdu
        state = .awaitingDevicePublicKey
        return result(
            outgoingPdus: [
                startPdu,
                try NativeMeshProvisioning.provisioningPublicKey(provisionerKeyPair.publicKey)
            ],
            failedErrorName: nil
        )
    }

    private mutating func handleDevicePublicKey(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard let invitePdu, let capabilitiesPdu else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning session is missing Capabilities")
        }
        let publicKey = try NativeMeshProvisioning.publicKeyValuePdu(pdu)
        let startPdu = try NativeMeshProvisioning.noOobProvisioningStart(capabilitiesPdu: capabilitiesPdu)
        let inputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: invitePdu,
            capabilitiesPdu: capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: provisionerKeyPair.publicKey,
            devicePublicKey: publicKey
        )
        let ecdhSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: provisionerKeyPair.privateKey,
            peerPublicKey: publicKey
        )
        let confirmationSalt = try NativeMeshProvisioning.confirmationSalt(confirmationInputs: inputs)
        let key = try NativeMeshProvisioning.confirmationKey(
            ecdhSecret: ecdhSecret,
            confirmationSalt: confirmationSalt
        )
        let confirmation = try NativeMeshProvisioning.confirmationValue(
            confirmationKey: key,
            random: provisionerRandom,
            authValue: NativeMeshProvisioning.authValueNoOob()
        )
        devicePublicKey = publicKey
        confirmationKey = key
        state = .awaitingDeviceConfirmation
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningConfirmation(confirmation)],
            failedErrorName: nil
        )
    }

    private mutating func handleDeviceConfirmation(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        _ = try NativeMeshProvisioning.confirmationValuePdu(pdu)
        deviceConfirmationPdu = pdu
        state = .awaitingDeviceRandom
        return result(
            outgoingPdus: [try NativeMeshProvisioning.provisioningRandom(provisionerRandom)],
            failedErrorName: nil
        )
    }

    private mutating func handleDeviceRandom(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard let invitePdu, let capabilitiesPdu, let devicePublicKey, let deviceConfirmationPdu,
            let confirmationKey else {
            throw NativeMeshProvisioningError.invalidParameter("provisioning session is missing confirmation state")
        }
        let deviceRandom = try NativeMeshProvisioning.randomValuePdu(pdu)
        let randomPdu = try NativeMeshProvisioning.provisioningRandom(deviceRandom)
        guard try NativeMeshProvisioning.verifyConfirmationPdu(
            confirmationPdu: deviceConfirmationPdu,
            randomPdu: randomPdu,
            confirmationKey: confirmationKey,
            authValue: NativeMeshProvisioning.authValueNoOob()
        ) else {
            throw NativeMeshProvisioningError.invalidParameter("device confirmation did not match device random")
        }

        let builtTranscript = try NativeMeshProvisioning.noOobProvisioningTranscript(
            pdus: NativeProvisioningHandshakePdus(
                invitePdu: invitePdu,
                capabilitiesPdu: capabilitiesPdu
            ),
            provisionerKeyPair: provisionerKeyPair,
            devicePublicKey: devicePublicKey,
            randoms: NativeProvisioningRandoms(
                provisionerRandom: provisionerRandom,
                deviceRandom: deviceRandom
            ),
            data: NativeProvisioningDataInput(
                networkKey: networkKey,
                keyIndex: keyIndex,
                flags: flags,
                ivIndex: ivIndex,
                unicastAddress: unicastAddress
            )
        )
        transcript = builtTranscript
        state = .awaitingComplete
        return result(
            outgoingPdus: [builtTranscript.encryptedProvisioningData.provisioningDataPdu],
            failedErrorName: nil
        )
    }

    private mutating func handleComplete(_ pdu: [UInt8]) throws -> NativeNoOobProvisioningSessionResult {
        guard pdu == [NativeMeshProvisioning.provisioningCompleteType] else {
            throw NativeMeshProvisioningError.invalidParameter("expected Provisioning Complete PDU")
        }
        state = .complete
        return result(outgoingPdus: [], failedErrorName: nil)
    }

    private func result(
        outgoingPdus: [[UInt8]],
        failedErrorName: String?
    ) -> NativeNoOobProvisioningSessionResult {
        NativeNoOobProvisioningSessionResult(
            state: state,
            outgoingPdus: outgoingPdus,
            completed: state == .complete,
            failedErrorName: failedErrorName
        )
    }
}
