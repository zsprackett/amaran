import Foundation

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        fputs("FAIL \(label): \(actual) != \(expected)\n", stderr)
        Foundation.exit(1)
    }
}

func expectHex(_ actual: [UInt8], _ expected: String, _ label: String) throws {
    expectEqual(NativeMeshCrypto.hex(actual), expected, label)
}

func expectThrows(_ label: String, _ block: () throws -> Void) {
    do {
        try block()
        fputs("FAIL \(label): expected throw\n", stderr)
        Foundation.exit(1)
    } catch {
    }
}

/// Deterministic shared test vectors used across multiple test groups. Computed
/// once and threaded through the test helpers so assertions run in a stable order.
struct NativeMeshTestFixtures {
    let netKey: [UInt8]
    let k2Material: MeshKeyMaterial
    let appKey: [UInt8]
    let configAppKeyAdd: [UInt8]
    let sampleInvite: [UInt8]
    let sampleCapabilities: [UInt8]
    let sampleStart: [UInt8]
    let samplePublicKey: [UInt8]
    let sampleDevicePublicKey: [UInt8]
    let sampleEcdhSecret: [UInt8]
    let sampleProvisionerRandom: [UInt8]
    let sampleDeviceRandom: [UInt8]
    let sampleConfirmationSalt: [UInt8]
    let sampleSecrets: NativeProvisioningSecrets
    let sampleTranscript: NativeNoOobProvisioningTranscript

    static func make() throws -> NativeMeshTestFixtures {
        let netKey = try NativeMeshCrypto.bytes(hex: "7dd7364cd842ad18c17c2b820c84c3d6")
        let k2Material = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
        let appKey = try NativeMeshCrypto.bytes(hex: "63964771734fbd76e3b40519d1d94a48")
        let configAppKeyAdd = try NativeMeshConfig.configAppKeyAdd(
            netKeyIndex: 0x0123,
            appKeyIndex: 0x0456,
            appKey: appKey
        )
        let sampleInvite = try NativeMeshProvisioning.provisioningInvite(attentionDuration: 5)
        let sampleCapabilities = try NativeMeshCrypto.bytes(hex: "010100010000000000000000")
        let sampleStart = try NativeMeshProvisioning.noOobProvisioningStart(capabilitiesPdu: sampleCapabilities)
        let samplePublicKey = Array(0..<64).map(UInt8.init)
        let sampleDevicePublicKey = Array(64..<128).map(UInt8.init)
        let sampleEcdhSecret = try NativeMeshCrypto.bytes(
            hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )
        let sampleProvisionerRandom = try NativeMeshCrypto.bytes(hex: "202122232425262728292a2b2c2d2e2f")
        let sampleDeviceRandom = try NativeMeshCrypto.bytes(hex: "303132333435363738393a3b3c3d3e3f")
        let pdus = NativeProvisioningHandshakePdus(invitePdu: sampleInvite, capabilitiesPdu: sampleCapabilities)
        let keyAgreement = NativeProvisioningKeyAgreement(
            provisionerPublicKey: samplePublicKey,
            devicePublicKey: sampleDevicePublicKey,
            ecdhSecret: sampleEcdhSecret
        )
        let randoms = NativeProvisioningRandoms(
            provisionerRandom: sampleProvisionerRandom,
            deviceRandom: sampleDeviceRandom
        )
        let derived = try makeSecrets(pdus: pdus, startPdu: sampleStart, keyAgreement: keyAgreement, randoms: randoms)
        let sampleConfirmationSalt = derived.salt
        let sampleSecrets = derived.secrets
        let sampleTranscript = try makeTranscript(pdus: pdus, keyAgreement: keyAgreement, randoms: randoms)
        return NativeMeshTestFixtures(
            netKey: netKey,
            k2Material: k2Material,
            appKey: appKey,
            configAppKeyAdd: configAppKeyAdd,
            sampleInvite: sampleInvite,
            sampleCapabilities: sampleCapabilities,
            sampleStart: sampleStart,
            samplePublicKey: samplePublicKey,
            sampleDevicePublicKey: sampleDevicePublicKey,
            sampleEcdhSecret: sampleEcdhSecret,
            sampleProvisionerRandom: sampleProvisionerRandom,
            sampleDeviceRandom: sampleDeviceRandom,
            sampleConfirmationSalt: sampleConfirmationSalt,
            sampleSecrets: sampleSecrets,
            sampleTranscript: sampleTranscript
        )
    }

    static func makeSecrets(
        pdus: NativeProvisioningHandshakePdus,
        startPdu: [UInt8],
        keyAgreement: NativeProvisioningKeyAgreement,
        randoms: NativeProvisioningRandoms
    ) throws -> (salt: [UInt8], secrets: NativeProvisioningSecrets) {
        let confirmationInputs = try NativeMeshProvisioning.confirmationInputs(
            invitePdu: pdus.invitePdu,
            capabilitiesPdu: pdus.capabilitiesPdu,
            startPdu: startPdu,
            provisionerPublicKey: keyAgreement.provisionerPublicKey,
            devicePublicKey: keyAgreement.devicePublicKey
        )
        let confirmationSalt = try NativeMeshProvisioning.confirmationSalt(
            confirmationInputs: confirmationInputs
        )
        let secrets = try NativeMeshProvisioning.provisioningSecrets(
            ecdhSecret: keyAgreement.ecdhSecret,
            confirmationSalt: confirmationSalt,
            provisionerRandom: randoms.provisionerRandom,
            deviceRandom: randoms.deviceRandom
        )
        return (confirmationSalt, secrets)
    }

    static func makeTranscript(
        pdus: NativeProvisioningHandshakePdus,
        keyAgreement: NativeProvisioningKeyAgreement,
        randoms: NativeProvisioningRandoms
    ) throws -> NativeNoOobProvisioningTranscript {
        try NativeMeshProvisioning.noOobProvisioningTranscript(
            pdus: pdus,
            keyAgreement: keyAgreement,
            randoms: randoms,
            data: NativeProvisioningDataInput(
                networkKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
                keyIndex: 0x0123,
                flags: 0x00,
                ivIndex: 0x01020304,
                unicastAddress: 0x1201
            )
        )
    }
}

@main
struct NativeMeshCryptoTests {
    static func main() {
        do {
            try run()
            print("native mesh crypto tests passed")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run() throws {
        let fixtures = try NativeMeshTestFixtures.make()
        try testRfcVectors()
        try testKeyDerivation()
        try testConfigMessages(fixtures)
        try testTelinkControl()
        try testProvisioningServiceAndPdus(fixtures)
        try testProvisioningConfirmation(fixtures)
        try testProvisioningTranscript(fixtures)
        try testProvisioningSessions(fixtures)
        try testProvisioningSummaries(fixtures)
        try testNativeState(fixtures)
        try testApplicationAccess(fixtures)
        try testDeviceAndSegmentedAccess(fixtures)
        try testNetworkPdu(fixtures)
    }
}
