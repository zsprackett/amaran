import Foundation

extension NativeMeshCryptoTests {
    static func testProvisioningSessions(_ fixtures: NativeMeshTestFixtures) throws {
        let liveStyleProvisioner = try NativeMeshProvisioning.generateProvisionerKeyPair()
        let liveStyleDevice = try NativeMeshProvisioning.generateProvisionerKeyPair()
        let liveStyleTranscript = try NativeMeshProvisioning.noOobProvisioningTranscript(
            pdus: NativeProvisioningHandshakePdus(
                invitePdu: fixtures.sampleInvite,
                capabilitiesPdu: fixtures.sampleCapabilities
            ),
            provisionerKeyPair: liveStyleProvisioner,
            devicePublicKey: liveStyleDevice.publicKey,
            randoms: NativeProvisioningRandoms(
                provisionerRandom: try NativeMeshProvisioning.generateProvisioningRandom(),
                deviceRandom: try NativeMeshProvisioning.generateProvisioningRandom()
            ),
            data: NativeProvisioningDataInput(
                networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
                keyIndex: 0x0123,
                flags: 0x00,
                ivIndex: 0x01020304,
                unicastAddress: 0x1201
            )
        )
        expectEqual(liveStyleTranscript.provisionerPublicKeyPdu.first, 0x03, "PB-GATT live transcript public key PDU")
        expectEqual(
            liveStyleTranscript.encryptedProvisioningData.provisioningDataPdu.first,
            0x07,
            "PB-GATT live transcript provisioning data PDU"
        )
        expectEqual(
            try NativeMeshProvisioning.verifyConfirmationPdu(
                confirmationPdu: liveStyleTranscript.expectedDeviceConfirmationPdu,
                randomPdu: try NativeMeshProvisioning.provisioningRandom(liveStyleTranscript.deviceRandom),
                confirmationKey: liveStyleTranscript.secrets.confirmationKey,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            true,
            "PB-GATT live transcript device confirmation verification"
        )
        try runProvisionerSession(
            fixtures,
            transcript: liveStyleTranscript,
            provisioner: liveStyleProvisioner,
            device: liveStyleDevice
        )
        try runCaptureSession(fixtures, transcript: liveStyleTranscript, device: liveStyleDevice)
        try runFailedSession(fixtures, transcript: liveStyleTranscript, provisioner: liveStyleProvisioner)
    }

    static func runProvisionerSession(
        _ fixtures: NativeMeshTestFixtures,
        transcript liveStyleTranscript: NativeNoOobProvisioningTranscript,
        provisioner liveStyleProvisioner: NativeProvisioningKeyPair,
        device liveStyleDevice: NativeProvisioningKeyPair
    ) throws {
        var session = try NativeNoOobProvisioningSession(
            provisionerKeyPair: liveStyleProvisioner,
            provisionerRandom: liveStyleTranscript.provisionerRandom,
            networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            keyIndex: 0x0123,
            flags: 0x00,
            ivIndex: 0x01020304,
            unicastAddress: 0x1201
        )
        expectEqual(session.state, .idle, "PB-GATT session starts idle")
        expectEqual(try session.start(attentionDuration: 5), fixtures.sampleInvite, "PB-GATT session Invite")
        expectEqual(session.state, .awaitingCapabilities, "PB-GATT session awaits Capabilities")
        let sessionStartResult = try session.receive(fixtures.sampleCapabilities)
        expectEqual(sessionStartResult.state, .awaitingDevicePublicKey, "PB-GATT session awaits Public Key")
        expectEqual(
            sessionStartResult.outgoingPdus,
            [fixtures.sampleStart, liveStyleTranscript.provisionerPublicKeyPdu],
            "PB-GATT session Start/Public Key output"
        )
        let liveStyleDevicePublicKeyPdu = try NativeMeshProvisioning.provisioningPublicKey(liveStyleDevice.publicKey)
        expectEqual(
            try NativeMeshProvisioning.publicKeyValuePdu(liveStyleDevicePublicKeyPdu),
            liveStyleDevice.publicKey,
            "PB-GATT public key PDU payload"
        )
        let sessionConfirmationResult = try session.receive(liveStyleDevicePublicKeyPdu)
        expectEqual(
            sessionConfirmationResult.outgoingPdus,
            [liveStyleTranscript.provisionerConfirmationPdu],
            "PB-GATT session Confirmation output"
        )
        expectEqual(
            sessionConfirmationResult.state,
            .awaitingDeviceConfirmation,
            "PB-GATT session awaits device Confirmation"
        )
        try finishProvisionerSession(&session, transcript: liveStyleTranscript)
    }

    static func finishProvisionerSession(
        _ session: inout NativeNoOobProvisioningSession,
        transcript liveStyleTranscript: NativeNoOobProvisioningTranscript
    ) throws {
        let sessionRandomResult = try session.receive(liveStyleTranscript.expectedDeviceConfirmationPdu)
        expectEqual(
            sessionRandomResult.outgoingPdus,
            [liveStyleTranscript.provisionerRandomPdu],
            "PB-GATT session Random output"
        )
        expectEqual(sessionRandomResult.state, .awaitingDeviceRandom, "PB-GATT session awaits device Random")
        let sessionDataResult = try session.receive(
            try NativeMeshProvisioning.provisioningRandom(liveStyleTranscript.deviceRandom)
        )
        expectEqual(
            sessionDataResult.outgoingPdus,
            [liveStyleTranscript.encryptedProvisioningData.provisioningDataPdu],
            "PB-GATT session Provisioning Data output"
        )
        expectEqual(sessionDataResult.state, .awaitingComplete, "PB-GATT session awaits Complete")
        expectEqual(session.transcript, liveStyleTranscript, "PB-GATT session transcript")
        let sessionCompleteResult = try session.receive([NativeMeshProvisioning.provisioningCompleteType])
        expectEqual(sessionCompleteResult.completed, true, "PB-GATT session completes")
        expectEqual(sessionCompleteResult.state, .complete, "PB-GATT session complete state")
    }

    static func runCaptureSession(
        _ fixtures: NativeMeshTestFixtures,
        transcript liveStyleTranscript: NativeNoOobProvisioningTranscript,
        device liveStyleDevice: NativeProvisioningKeyPair
    ) throws {
        let liveStyleDevicePublicKeyPdu = try NativeMeshProvisioning.provisioningPublicKey(liveStyleDevice.publicKey)
        var captureSession = try NativeProvisioneeCaptureSession(
            deviceKeyPair: liveStyleDevice,
            deviceRandom: liveStyleTranscript.deviceRandom
        )
        expectEqual(captureSession.state, .awaitingInvite, "PB-GATT capture session starts awaiting Invite")
        let captureCapabilities = try captureSession.receive(fixtures.sampleInvite)
        expectEqual(
            captureCapabilities.outgoingPdus,
            [fixtures.sampleCapabilities],
            "PB-GATT capture Capabilities output"
        )
        expectEqual(captureCapabilities.state, .awaitingStart, "PB-GATT capture session awaits Start")
        let captureStart = try captureSession.receive(fixtures.sampleStart)
        expectEqual(captureStart.outgoingPdus, [], "PB-GATT capture Start output")
        expectEqual(captureStart.state, .awaitingProvisionerPublicKey, "PB-GATT capture session awaits Public Key")
        let capturePublicKey = try captureSession.receive(liveStyleTranscript.provisionerPublicKeyPdu)
        expectEqual(capturePublicKey.outgoingPdus, [liveStyleDevicePublicKeyPdu], "PB-GATT capture Public Key output")
        let captureConfirmation = try captureSession.receive(liveStyleTranscript.provisionerConfirmationPdu)
        expectEqual(
            captureConfirmation.outgoingPdus,
            [liveStyleTranscript.expectedDeviceConfirmationPdu],
            "PB-GATT capture Confirmation output"
        )
        let captureRandom = try captureSession.receive(liveStyleTranscript.provisionerRandomPdu)
        expectEqual(
            captureRandom.outgoingPdus,
            [try NativeMeshProvisioning.provisioningRandom(liveStyleTranscript.deviceRandom)],
            "PB-GATT capture Random output"
        )
        let captureData = try captureSession.receive(liveStyleTranscript.encryptedProvisioningData.provisioningDataPdu)
        expectEqual(captureData.completed, true, "PB-GATT capture completes")
        expectEqual(captureData.state, .complete, "PB-GATT capture complete state")
        expectEqual(
            captureData.outgoingPdus,
            [[NativeMeshProvisioning.provisioningCompleteType]],
            "PB-GATT capture Complete output"
        )
        expectEqual(
            captureData.capturedData?.networkKey ?? [],
            Array(liveStyleTranscript.encryptedProvisioningData.provisioningData.prefix(16)),
            "PB-GATT capture NetKey"
        )
        expectEqual(captureData.capturedData?.keyIndex, 0x0123, "PB-GATT capture key index")
        expectEqual(captureData.capturedData?.unicastAddress, 0x1201, "PB-GATT capture unicast")
        expectEqual(captureSession.deviceKey, liveStyleTranscript.secrets.deviceKey, "PB-GATT capture DeviceKey")
    }

    static func runFailedSession(
        _ fixtures: NativeMeshTestFixtures,
        transcript liveStyleTranscript: NativeNoOobProvisioningTranscript,
        provisioner liveStyleProvisioner: NativeProvisioningKeyPair
    ) throws {
        var failedSession = try NativeNoOobProvisioningSession(
            provisionerKeyPair: liveStyleProvisioner,
            provisionerRandom: liveStyleTranscript.provisionerRandom,
            networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            keyIndex: 0x0123,
            flags: 0x00,
            ivIndex: 0x01020304,
            unicastAddress: 0x1201
        )
        _ = try failedSession.start(attentionDuration: 5)
        let failedSessionResult = try failedSession.receive([0x09, 0x04])
        expectEqual(failedSessionResult.state, .failed, "PB-GATT session failed state")
        expectEqual(
            failedSessionResult.failedErrorName,
            "confirmation_failed",
            "PB-GATT session failed reason"
        )
    }

    static func testProvisioningSummaries(_ fixtures: NativeMeshTestFixtures) throws {
        let sampleTranscript = fixtures.sampleTranscript
        let confirmationSummary = NativeMeshProvisioning.provisioningPduSummary(
            sampleTranscript.provisionerConfirmationPdu
        )
        let randomSummary = NativeMeshProvisioning.provisioningPduSummary(sampleTranscript.provisionerRandomPdu)
        let dataSummary = NativeMeshProvisioning.provisioningPduSummary(
            sampleTranscript.encryptedProvisioningData.provisioningDataPdu
        )
        expectEqual(confirmationSummary["confirmation_bytes"] as? Int, 16, "PB-GATT confirmation summary")
        expectEqual(randomSummary["random_bytes"] as? Int, 16, "PB-GATT random summary")
        expectEqual(dataSummary["mic_bytes"] as? Int, 8, "PB-GATT data summary")
        let failedSummary = NativeMeshProvisioning.provisioningPduSummary([0x09, 0x04])["failed"] as? [String: Any]
        expectEqual(failedSummary?["error_name"] as? String, "confirmation_failed", "PB-GATT failed summary")
    }
}
