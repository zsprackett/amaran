import Foundation

extension NativeMeshCryptoTests {
    static func testProvisioningServiceAndPdus(_ fixtures: NativeMeshTestFixtures) throws {
        let provisioning = NativeMeshProvisioning.provisioningServiceDataSummary(
            try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff000212345678")
        )
        expectEqual(provisioning["bytes"] as? Int, 22, "PB-GATT service data length")
        expectEqual(provisioning["device_uuid"] as? String, "00112233445566778899aabbccddeeff", "PB-GATT device UUID")
        expectEqual(provisioning["oob_info"] as? String, "0x0002", "PB-GATT OOB info")
        expectEqual(
            provisioning["oob_info_flags"] as? [String],
            ["electronic_or_uri"],
            "PB-GATT OOB info flags"
        )
        expectEqual(provisioning["uri_hash"] as? String, "12345678", "PB-GATT URI hash")
        try expectHex(
            try NativeMeshProvisioning.provisioningInvite(attentionDuration: 5),
            "0005",
            "PB-GATT Provisioning Invite PDU"
        )
        try expectHex(
            NativeMeshProvisioning.completeProxyPdu(provisioningPdu: [0x00, 0x05]),
            "030005",
            "PB-GATT complete Proxy PDU"
        )
        expectEqual(
            try NativeMeshProvisioning.segmentedProxyPdus(
                provisioningPdu: [0x00, 0x05],
                maxSegmentPayloadBytes: 20
            ),
            [[0x03, 0x00, 0x05]],
            "PB-GATT single-segment Proxy PDU"
        )
        expectEqual(
            NativeMeshProvisioning.provisioningPduSummary([0x00, 0x05])["pdu_type_name"] as? String,
            "provisioning_invite",
            "PB-GATT PDU type name"
        )
        try testProvisioningCapabilities()
        try testProvisioningStart()
        try testProvisioningPublicKeyReassembly(fixtures)
        try testProvisioningEcdh(fixtures)
    }

    static func testProvisioningCapabilities() throws {
        let capabilities = NativeMeshProvisioning.provisioningCapabilitiesSummary(
            try NativeMeshCrypto.bytes(hex: "01020003010104000902000c")
        )
        expectEqual(capabilities?["number_of_elements"] as? Int, 2, "PB-GATT capabilities elements")
        expectEqual(
            capabilities?["algorithm_flags"] as? [String],
            ["fips_p256_elliptic_curve", "fips_p256_hmac_sha256_aes_ccm"],
            "PB-GATT capabilities algorithms"
        )
        expectEqual(capabilities?["public_key_oob"] as? Bool, true, "PB-GATT capabilities public key")
        expectEqual(capabilities?["static_oob_available"] as? Bool, true, "PB-GATT capabilities static OOB")
        expectEqual(capabilities?["output_oob_size"] as? Int, 4, "PB-GATT capabilities output size")
        expectEqual(
            capabilities?["output_oob_actions"] as? [String],
            ["blink", "output_numeric"],
            "PB-GATT capabilities output actions"
        )
        expectEqual(capabilities?["input_oob_size"] as? Int, 2, "PB-GATT capabilities input size")
        expectEqual(
            capabilities?["input_oob_actions"] as? [String],
            ["input_numeric", "input_alphanumeric"],
            "PB-GATT capabilities input actions"
        )
        let capabilitiesSummary = NativeMeshProvisioning.provisioningPduSummary(
            try NativeMeshCrypto.bytes(hex: "01020003010104000902000c")
        )
        let nestedCapabilities = capabilitiesSummary["capabilities"] as? [String: Any]
        expectEqual(
            nestedCapabilities?["pdu_type_name"] as? String,
            "provisioning_capabilities",
            "PB-GATT nested capabilities summary"
        )
    }

    static func testProvisioningStart() throws {
        try expectHex(
            try NativeMeshProvisioning.provisioningStart(
                algorithm: 0,
                publicKey: 0,
                authenticationMethod: 0,
                authenticationAction: 0,
                authenticationSize: 0
            ),
            "020000000000",
            "PB-GATT no-OOB Provisioning Start PDU"
        )
        try expectHex(
            try NativeMeshProvisioning.noOobProvisioningStart(
                capabilitiesPdu: try NativeMeshCrypto.bytes(hex: "010100010000000000000000")
            ),
            "020000000000",
            "PB-GATT no-OOB Provisioning Start selection"
        )
        let startSummary = NativeMeshProvisioning.provisioningPduSummary(
            try NativeMeshCrypto.bytes(hex: "020000000000")
        )
        let nestedStart = startSummary["start"] as? [String: Any]
        expectEqual(nestedStart?["algorithm_name"] as? String, "fips_p256_elliptic_curve", "PB-GATT start algorithm")
        expectEqual(nestedStart?["public_key_name"] as? String, "in_band", "PB-GATT start public key")
        expectEqual(nestedStart?["authentication_method_name"] as? String, "no_oob", "PB-GATT start authentication")
    }

    static func testProvisioningPublicKeyReassembly(_ fixtures: NativeMeshTestFixtures) throws {
        let samplePublicKey = fixtures.samplePublicKey
        try expectHex(
            try NativeMeshProvisioning.provisioningPublicKey(samplePublicKey),
            "03000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
                + "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
            "PB-GATT Provisioning Public Key PDU"
        )
        expectEqual(
            NativeMeshProvisioning.provisioningPduSummary([0x03] + samplePublicKey)["public_key_bytes"] as? Int,
            64,
            "PB-GATT public key summary"
        )
        let segmentedPublicKey = try NativeMeshProvisioning.segmentedProxyPdus(
            provisioningPdu: try NativeMeshProvisioning.provisioningPublicKey(samplePublicKey),
            maxSegmentPayloadBytes: 20
        )
        expectEqual(segmentedPublicKey.count, 4, "PB-GATT segmented Public Key segment count")
        expectEqual(segmentedPublicKey.map(\.count), [21, 21, 21, 6], "PB-GATT segmented Public Key sizes")
        expectEqual(segmentedPublicKey.map { $0[0] }, [0x43, 0x83, 0x83, 0xc3], "PB-GATT segmented Public Key SAR")
        try expectHex(
            try NativeMeshProvisioning.reassembleProxyPdus(segmentedPublicKey),
            "03000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
                + "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
            "PB-GATT segmented Public Key reassembly"
        )
        var publicKeyReassembler = NativeProvisioningProxyPduReassembler()
        let firstPublicKeySegment = try publicKeyReassembler.receive(segmentedPublicKey[0])
        expectEqual(firstPublicKeySegment.pending, true, "PB-GATT Public Key reassembly pending")
        expectEqual(firstPublicKeySegment.segmentCount, 1, "PB-GATT Public Key first segment count")
        expectEqual(firstPublicKeySegment.provisioningPdu, nil, "PB-GATT Public Key first segment has no PDU")
        _ = try publicKeyReassembler.receive(segmentedPublicKey[1])
        _ = try publicKeyReassembler.receive(segmentedPublicKey[2])
        let completedPublicKeyReassembly = try publicKeyReassembler.receive(segmentedPublicKey[3])
        expectEqual(completedPublicKeyReassembly.pending, false, "PB-GATT Public Key reassembly complete")
        expectEqual(completedPublicKeyReassembly.segmentCount, 4, "PB-GATT Public Key complete segment count")
        expectEqual(
            completedPublicKeyReassembly.provisioningPdu,
            try NativeMeshProvisioning.provisioningPublicKey(samplePublicKey),
            "PB-GATT incremental Public Key reassembly"
        )
        let completedInviteReassembly = try publicKeyReassembler.receive([0x03, 0x00, 0x05])
        expectEqual(completedInviteReassembly.segmentCount, 1, "PB-GATT complete Invite segment count")
        expectEqual(completedInviteReassembly.provisioningPdu, [0x00, 0x05], "PB-GATT complete Invite reassembly")
    }

    static func testProvisioningEcdh(_ fixtures: NativeMeshTestFixtures) throws {
        let provisionerKeyPair = try NativeMeshProvisioning.generateProvisionerKeyPair()
        let deviceKeyPair = try NativeMeshProvisioning.generateProvisionerKeyPair()
        expectEqual(provisionerKeyPair.publicKey.count, 64, "PB-GATT provisioner public key length")
        expectEqual(deviceKeyPair.publicKey.count, 64, "PB-GATT device public key length")
        try expectHex(
            try NativeMeshProvisioning.provisioningPublicKey(provisionerKeyPair.publicKey).prefix(1).map { $0 },
            "03",
            "PB-GATT generated public key PDU type"
        )
        let provisionerSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: provisionerKeyPair.privateKey,
            peerPublicKey: deviceKeyPair.publicKey
        )
        let deviceSecret = try NativeMeshProvisioning.ecdhSecret(
            privateKey: deviceKeyPair.privateKey,
            peerPublicKey: provisionerKeyPair.publicKey
        )
        expectEqual(provisionerSecret.count, 32, "PB-GATT ECDH secret length")
        expectEqual(provisionerSecret, deviceSecret, "PB-GATT ECDH shared secret agreement")
        expectEqual(provisionerSecret == [UInt8](repeating: 0, count: 32), false, "PB-GATT ECDH secret is nonzero")
        expectEqual(
            try NativeMeshProvisioning.provisioningCapabilities(elementCount: 1),
            fixtures.sampleCapabilities,
            "PB-GATT generated no-OOB capabilities"
        )
    }

    static func testProvisioningConfirmation(_ fixtures: NativeMeshTestFixtures) throws {
        let sampleConfirmationInputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: fixtures.sampleInvite,
            capabilitiesPdu: fixtures.sampleCapabilities,
            startPdu: fixtures.sampleStart,
            provisionerPublicKey: fixtures.samplePublicKey,
            devicePublicKey: fixtures.sampleDevicePublicKey
        )
        try expectHex(
            sampleConfirmationInputs,
            "0501000100000000000000000000000000000102030405060708090a0b0c0d0e0f"
                + "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"
                + "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"
                + "505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f"
                + "707172737475767778797a7b7c7d7e7f",
            "PB-GATT confirmation inputs"
        )
        let sampleConfirmationSalt = try NativeMeshProvisioning.confirmationSalt(
            confirmationInputs: sampleConfirmationInputs
        )
        try expectHex(sampleConfirmationSalt, "81c16d5e7d46f07e670f29f2185f5482", "PB-GATT confirmation salt")
        let sampleConfirmationKey = try NativeMeshProvisioning.confirmationKey(
            ecdhSecret: fixtures.sampleEcdhSecret,
            confirmationSalt: sampleConfirmationSalt
        )
        try expectHex(sampleConfirmationKey, "d94e889c79b2ed38c11d5af37e9babc3", "PB-GATT confirmation key")
        try testProvisioningConfirmationValues(fixtures, confirmationKey: sampleConfirmationKey)
    }

    static func testProvisioningConfirmationValues(
        _ fixtures: NativeMeshTestFixtures,
        confirmationKey sampleConfirmationKey: [UInt8]
    ) throws {
        try expectHex(
            try NativeMeshProvisioning.confirmationValue(
                confirmationKey: sampleConfirmationKey,
                random: fixtures.sampleProvisionerRandom,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            "b61a5036306042842d3384a5ef32ac1c",
            "PB-GATT no-OOB confirmation value"
        )
        try expectHex(
            try NativeMeshProvisioning.provisioningConfirmation(
                try NativeMeshProvisioning.confirmationValue(
                    confirmationKey: sampleConfirmationKey,
                    random: fixtures.sampleProvisionerRandom,
                    authValue: NativeMeshProvisioning.authValueNoOob()
                )
            ),
            "05b61a5036306042842d3384a5ef32ac1c",
            "PB-GATT Provisioning Confirmation PDU"
        )
        try expectHex(
            try NativeMeshProvisioning.provisioningRandom(fixtures.sampleProvisionerRandom),
            "06202122232425262728292a2b2c2d2e2f",
            "PB-GATT Provisioning Random PDU"
        )
        let sampleSecrets = fixtures.sampleSecrets
        try expectHex(sampleSecrets.provisioningSalt, "667dc0b6183dea931f3882a4f4f4b5c2", "PB-GATT provisioning salt")
        try expectHex(sampleSecrets.sessionKey, "bd0a2c3efdedeb3ca71ae352873b0293", "PB-GATT session key")
        try expectHex(sampleSecrets.sessionNonce, "cb44f0b3a500250e79fbd4c075", "PB-GATT session nonce")
        try expectHex(sampleSecrets.deviceKey, "0b9dc768a7a5debf33f536ccb83edefa", "PB-GATT device key")
    }

    static func testProvisioningTranscript(_ fixtures: NativeMeshTestFixtures) throws {
        let sampleSecrets = fixtures.sampleSecrets
        let sampleEncryptedProvisioningData = try NativeMeshProvisioning.encryptedProvisioningData(
            sessionKey: sampleSecrets.sessionKey,
            sessionNonce: sampleSecrets.sessionNonce,
            data: NativeProvisioningDataInput(
                networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
                keyIndex: 0x0123,
                flags: 0x00,
                ivIndex: 0x01020304,
                unicastAddress: 0x1201
            )
        )
        try expectHex(
            sampleEncryptedProvisioningData.provisioningData,
            "00112233445566778899aabbccddeeff012300010203041201",
            "PB-GATT provisioning data plaintext"
        )
        try expectHex(
            sampleEncryptedProvisioningData.encryptedProvisioningData,
            "6ea5b884e4ef3a18531053a6820eedf7f0a287d34b020bda37",
            "PB-GATT encrypted provisioning data"
        )
        try expectHex(
            sampleEncryptedProvisioningData.provisioningDataMic,
            "679a315aadd64afa",
            "PB-GATT provisioning data MIC"
        )
        try expectHex(
            sampleEncryptedProvisioningData.provisioningDataPdu,
            "076ea5b884e4ef3a18531053a6820eedf7f0a287d34b020bda37679a315aadd64afa",
            "PB-GATT provisioning data PDU"
        )
        let sampleDecryptedProvisioningData = try NativeMeshProvisioning.decryptProvisioningData(
            sampleEncryptedProvisioningData.provisioningDataPdu,
            sessionKey: sampleSecrets.sessionKey,
            sessionNonce: sampleSecrets.sessionNonce
        )
        try expectHex(
            sampleDecryptedProvisioningData.networkKey,
            "00112233445566778899aabbccddeeff",
            "PB-GATT decrypt provisioning data NetKey"
        )
        expectEqual(sampleDecryptedProvisioningData.keyIndex, 0x0123, "PB-GATT decrypt provisioning data key index")
        expectEqual(sampleDecryptedProvisioningData.flags, 0x00, "PB-GATT decrypt provisioning data flags")
        expectEqual(sampleDecryptedProvisioningData.ivIndex, 0x01020304, "PB-GATT decrypt provisioning data IV index")
        expectEqual(sampleDecryptedProvisioningData.unicastAddress, 0x1201, "PB-GATT decrypt provisioning data unicast")
        try verifyTranscript(fixtures, sampleEncryptedProvisioningData: sampleEncryptedProvisioningData)
    }

    static func verifyTranscript(
        _ fixtures: NativeMeshTestFixtures,
        sampleEncryptedProvisioningData: NativeProvisioningDataEncrypted
    ) throws {
        let sampleTranscript = fixtures.sampleTranscript
        expectEqual(sampleTranscript.startPdu, fixtures.sampleStart, "PB-GATT transcript Start PDU")
        let sampleConfirmationInputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: fixtures.sampleInvite,
            capabilitiesPdu: fixtures.sampleCapabilities,
            startPdu: fixtures.sampleStart,
            provisionerPublicKey: fixtures.samplePublicKey,
            devicePublicKey: fixtures.sampleDevicePublicKey
        )
        expectEqual(sampleTranscript.confirmationInputs, sampleConfirmationInputs, "PB-GATT transcript inputs")
        expectEqual(sampleTranscript.secrets, fixtures.sampleSecrets, "PB-GATT transcript secrets")
        try expectHex(
            sampleTranscript.provisionerConfirmationPdu,
            "05b61a5036306042842d3384a5ef32ac1c",
            "PB-GATT transcript confirmation PDU"
        )
        expectEqual(
            sampleTranscript.encryptedProvisioningData,
            sampleEncryptedProvisioningData,
            "PB-GATT transcript encrypted provisioning data"
        )
        let sampleDeviceRandomPdu = try NativeMeshProvisioning.provisioningRandom(fixtures.sampleDeviceRandom)
        expectEqual(
            try NativeMeshProvisioning.verifyConfirmationPdu(
                confirmationPdu: sampleTranscript.expectedDeviceConfirmationPdu,
                randomPdu: sampleDeviceRandomPdu,
                confirmationKey: sampleTranscript.secrets.confirmationKey,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            true,
            "PB-GATT transcript device confirmation verification"
        )
        var wrongDeviceConfirmation = sampleTranscript.expectedDeviceConfirmationPdu
        wrongDeviceConfirmation[1] ^= 0x01
        expectEqual(
            try NativeMeshProvisioning.verifyConfirmationPdu(
                confirmationPdu: wrongDeviceConfirmation,
                randomPdu: sampleDeviceRandomPdu,
                confirmationKey: sampleTranscript.secrets.confirmationKey,
                authValue: NativeMeshProvisioning.authValueNoOob()
            ),
            false,
            "PB-GATT transcript rejects wrong device confirmation"
        )
    }
}
