import Foundation

extension NativeMeshCryptoTests {
    static func testRfcVectors() throws {
        try testRfcCmacVectors()
        try testRfcCcmVectors()
    }

    static func testRfcCmacVectors() throws {
        let cmacKey = try NativeMeshCrypto.bytes(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let zero = [UInt8](repeating: 0, count: 16)
        try expectHex(
            try NativeMeshCrypto.aes128EncryptBlock(key: cmacKey, block: zero),
            "7df76b0c1ab899b33e42f047b91b546f",
            "RFC4493 AES-128(key, zero)"
        )

        try expectHex(
            try NativeMeshCrypto.aesCmac(key: cmacKey, message: []),
            "bb1d6929e95937287fa37d129b756746",
            "RFC4493 CMAC example 1"
        )
        try expectHex(
            try NativeMeshCrypto.aesCmac(
                key: cmacKey,
                message: NativeMeshCrypto.bytes(hex: "6bc1bee22e409f96e93d7e117393172a")
            ),
            "070a16b46b4d4144f79bdd9dd04a287c",
            "RFC4493 CMAC example 2"
        )
        try expectHex(
            try NativeMeshCrypto.aesCmac(
                key: cmacKey,
                message: NativeMeshCrypto.bytes(
                    hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411"
                )
            ),
            "dfa66747de9ae63030ca32611497c827",
            "RFC4493 CMAC example 3"
        )
        try expectHex(
            try NativeMeshCrypto.aesCmac(
                key: cmacKey,
                message: NativeMeshCrypto.bytes(
                    hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
                        + "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
                )
            ),
            "51f0bebf7e3b9d92fc49741779363cfe",
            "RFC4493 CMAC example 4"
        )
    }

    static func testRfcCcmVectors() throws {
        let ccmResult = try NativeMeshCrypto.aesCcmEncrypt(
            key: NativeMeshCrypto.bytes(hex: "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"),
            nonce: NativeMeshCrypto.bytes(hex: "00000003020100a0a1a2a3a4a5"),
            plaintext: NativeMeshCrypto.bytes(hex: "08090a0b0c0d0e0f101112131415161718191a1b1c1d1e"),
            aad: NativeMeshCrypto.bytes(hex: "0001020304050607"),
            micLength: 8
        )
        try expectHex(
            ccmResult.ciphertext + ccmResult.mic,
            "588c979a61c663d2f066d0c2c0f989806d5f6b61dac38417e8d12cfdf926e0",
            "RFC3610 CCM packet vector 1"
        )
        try expectHex(
            try NativeMeshCrypto.aesCcmDecrypt(
                key: NativeMeshCrypto.bytes(hex: "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"),
                nonce: NativeMeshCrypto.bytes(hex: "00000003020100a0a1a2a3a4a5"),
                ciphertext: ccmResult.ciphertext,
                mic: ccmResult.mic,
                aad: NativeMeshCrypto.bytes(hex: "0001020304050607")
            ),
            "08090a0b0c0d0e0f101112131415161718191a1b1c1d1e",
            "RFC3610 CCM packet vector 1 decrypt"
        )
    }

    static func testKeyDerivation() throws {
        try expectHex(try NativeMeshCrypto.s1("smk2"), "4f90480c1871bfbffd16971f4d8d10b1", "Mesh s1(smk2)")

        let netKey = try NativeMeshCrypto.bytes(hex: "7dd7364cd842ad18c17c2b820c84c3d6")
        let k2Material = try NativeMeshCrypto.k2(n: netKey, p: [0x00])
        expectEqual(k2Material.nid, 0x68, "Mesh k2 NID")
        try expectHex(k2Material.encryptionKey, "0953fa93e7caac9638f58820220a398e", "Mesh k2 EncryptionKey")
        try expectHex(k2Material.privacyKey, "8b84eedec100067d670971dd2aa700cf", "Mesh k2 PrivacyKey")
        try expectHex(try NativeMeshCrypto.k3(n: netKey), "3ecaff672f673370", "Mesh k3 Network ID")

        let appKey = try NativeMeshCrypto.bytes(hex: "63964771734fbd76e3b40519d1d94a48")
        expectEqual(try NativeMeshCrypto.k4(n: appKey), 0x26, "Mesh k4 AID")

        try expectHex(
            try NativeMeshCrypto.vendorAccessMessage(
                opcode: 0x23,
                companyIdentifier: 0x0136,
                parameters: NativeMeshCrypto.bytes(hex: "aabb")
            ),
            "e33601aabb",
            "Mesh vendor access opcode"
        )
    }

    static func testConfigMessages(_ fixtures: NativeMeshTestFixtures) throws {
        let appKey = fixtures.appKey
        let configAppKeyAdd = fixtures.configAppKeyAdd
        try expectHex(
            try NativeMeshConfig.packedKeyIndexes(0x0123, 0x0456),
            "236145",
            "Config packed key indexes"
        )
        try expectHex(
            NativeMeshConfig.configCompositionDataGet(),
            "800800",
            "Config Composition Data Get"
        )
        try expectHex(
            NativeMeshConfig.configNodeReset(),
            "8049",
            "Config Node Reset"
        )
        try expectHex(
            try NativeMeshConfig.configAppKeyGet(netKeyIndex: 0),
            "80010000",
            "Config AppKey Get"
        )
        try expectHex(
            configAppKeyAdd,
            "0023614563964771734fbd76e3b40519d1d94a48",
            "Config AppKey Add"
        )
        try testConfigModelBindAndSegmentation(configAppKeyAdd: configAppKeyAdd)
        try testConfigComposition()
        try testConfigStatus(appKey: appKey)
    }

    static func testConfigModelBindAndSegmentation(configAppKeyAdd: [UInt8]) throws {
        try expectHex(
            try NativeMeshConfig.configModelAppBind(
                elementAddress: 0x1201,
                appKeyIndex: 0x0123,
                modelIdentifier: .sig(0x1000)
            ),
            "803d011223010010",
            "Config SIG Model App Bind"
        )
        try expectHex(
            try NativeMeshConfig.configModelAppBind(
                elementAddress: 0x1201,
                appKeyIndex: 0x0123,
                modelIdentifier: .vendor(companyIdentifier: 0x0136, modelIdentifier: 0x0001)
            ),
            "803d0112230136010100",
            "Config Vendor Model App Bind"
        )
        expectEqual(
            NativeMeshConfig.requiresSegmentedLowerTransport(accessMessage: configAppKeyAdd),
            true,
            "Config AppKey Add requires segmentation"
        )
        expectEqual(
            NativeMeshConfig.requiresSegmentedLowerTransport(
                accessMessage: NativeMeshConfig.configCompositionDataGet()
            ),
            false,
            "Config Composition Data Get is unsegmented"
        )
    }

    static func testConfigComposition() throws {
        let amaranComposition = try NativeMeshConfig.compositionDataPage0(
            NativeMeshCrypto.bytes(
                hex: "0011020102333369000A0000000A0100000200030000"
                    + "1002100410061007100013011311020000"
            )
        )
        expectEqual(amaranComposition.includedPageByte, true, "Composition Data Status page byte")
        expectEqual(amaranComposition.cid, 0x0211, "Composition CID")
        expectEqual(amaranComposition.pid, 0x0201, "Composition PID")
        expectEqual(amaranComposition.vid, 0x3333, "Composition VID")
        expectEqual(amaranComposition.crpl, 0x0069, "Composition CRPL")
        expectEqual(amaranComposition.features, 0x000a, "Composition features")
        expectEqual(amaranComposition.elements.count, 1, "Composition element count")
        expectEqual(amaranComposition.elements[0].location, 0x0000, "Composition primary element location")
        expectEqual(amaranComposition.elements[0].sigModels.count, 10, "Composition SIG model count")
        expectEqual(amaranComposition.elements[0].sigModels[0], 0x0000, "Composition Config Server model")
        expectEqual(amaranComposition.elements[0].sigModels[3], 0x1000, "Composition Generic OnOff Server model")
        expectEqual(amaranComposition.elements[0].vendorModels.count, 1, "Composition vendor model count")
        expectEqual(
            amaranComposition.elements[0].vendorModels[0].companyIdentifier,
            0x0211,
            "Composition vendor company"
        )
        expectEqual(amaranComposition.elements[0].vendorModels[0].modelIdentifier, 0x0000, "Composition vendor model")
        expectEqual(amaranComposition.firstVendorModelBindingTarget?.elementIndex, 0, "Composition bind element index")
        expectEqual(
            amaranComposition.firstVendorModelBindingTarget?.model.companyIdentifier,
            0x0211,
            "Composition bind company"
        )
        try expectHex(
            try NativeMeshConfig.configModelAppBind(
                elementAddress: 0x0002,
                appKeyIndex: 0,
                modelIdentifier: .vendor(companyIdentifier: 0x0211, modelIdentifier: 0x0000)
            ),
            "803d0200000011020000",
            "Config amaran Vendor Model App Bind"
        )
    }

    static func testConfigStatus(appKey: [UInt8]) throws {
        let appKeyStatus = try NativeMeshConfig.configAppKeyStatus(
            NativeMeshCrypto.bytes(hex: "800300236145")
        )
        expectEqual(appKeyStatus.status, 0, "Config AppKey Status status")
        expectEqual(NativeMeshConfig.statusName(appKeyStatus.status), "success", "Config AppKey Status name")
        expectEqual(appKeyStatus.netKeyIndex, 0x0123, "Config AppKey Status NetKeyIndex")
        expectEqual(appKeyStatus.appKeyIndex, 0x0456, "Config AppKey Status AppKeyIndex")
        let appKeyList = try NativeMeshConfig.configAppKeyList(
            NativeMeshCrypto.bytes(hex: "8002000000001000")
        )
        expectEqual(appKeyList.status, 0, "Config AppKey List status")
        expectEqual(appKeyList.netKeyIndex, 0, "Config AppKey List NetKeyIndex")
        expectEqual(appKeyList.appKeyIndexes, [0, 1], "Config AppKey List indexes")
        let compositionStatus = try NativeMeshConfig.configCompositionDataStatus(
            NativeMeshCrypto.bytes(
                hex: "020011020102333369000A0000000A0100000200030000"
                    + "1002100410061007100013011311020000"
            )
        )
        expectEqual(compositionStatus.includedPageByte, true, "Config Composition Data Status page byte")
        expectEqual(compositionStatus.cid, 0x0211, "Config Composition Data Status CID")
        expectEqual(compositionStatus.elements.count, 1, "Config Composition Data Status elements")
        expectEqual(
            compositionStatus.firstVendorModelBindingTarget?.model.companyIdentifier,
            0x0211,
            "Config Composition Data Status vendor company"
        )
        let modelAppStatus = try NativeMeshConfig.configModelAppStatus(
            NativeMeshCrypto.bytes(hex: "803e000200000011020000")
        )
        expectEqual(modelAppStatus.status, 0, "Config Model App Status status")
        expectEqual(modelAppStatus.elementAddress, 0x0002, "Config Model App Status element")
        expectEqual(modelAppStatus.appKeyIndex, 0, "Config Model App Status AppKeyIndex")
        switch modelAppStatus.modelIdentifier {
        case .vendor(let companyIdentifier, let modelIdentifier):
            expectEqual(companyIdentifier, 0x0211, "Config Model App Status company")
            expectEqual(modelIdentifier, 0x0000, "Config Model App Status model")
        case .sig:
            fputs("FAIL Config Model App Status model: expected vendor model\n", stderr)
            Foundation.exit(1)
        }
    }

    static func testTelinkControl() throws {
        try expectHex(
            NativeTelinkControl.onOffPacket(turnOn: false),
            "8c00000000000000008c",
            "Telink 0x26 off packet"
        )
        try expectHex(
            NativeTelinkControl.onOffPacket(turnOn: true),
            "8d00000000000000018c",
            "Telink 0x26 on packet"
        )
        try testTelinkBrightnessAndCct()
        try expectHex(
            try NativeTelinkControlCommand.parse(spec: "cct:5600:20:10:0").accessMessage(),
            "2618000000004001233282",
            "Telink 0x26 CCT access message"
        )
        try expectHex(
            try NativeTelinkControlCommand.parse(spec: "raw:18000000004001233282").accessMessage(),
            "2618000000004001233282",
            "Telink 0x26 raw access message"
        )
        expectThrows("Telink raw rejects bad checksum") {
            _ = try NativeTelinkControl.rawPacket(hex: "00000000002000233282")
        }
        try expectHex(
            NativeTelinkControl.statusRequestPacket(),
            "0e00000000000000000e",
            "Telink 0x26 status request packet"
        )
        try expectHex(
            try NativeTelinkControlCommand.parse(spec: "status").accessMessage(),
            "260e00000000000000000e",
            "Telink 0x26 status access message"
        )
        try testTelinkDecode()
    }

    static func testTelinkBrightnessAndCct() throws {
        try expectHex(
            try NativeTelinkControl.brightnessPacket(telinkIntensity: 200),
            "c100000000000000328f",
            "Telink 0x26 brightness packet"
        )
        try expectHex(
            try NativeTelinkControl.brightnessPacket(telinkIntensity: 201),
            "0100000000000040328f",
            "Telink 0x26 brightness low-bit packet"
        )
        try expectHex(
            try NativeTelinkControl.cctPacket(telinkCct: 560, telinkIntensity: 200, gm: 10, gmFlag: 0),
            "18000000004001233282",
            "Telink 0x26 CCT packet"
        )
        try expectHex(
            try NativeTelinkControl.cctPacket(telinkCct: 470, telinkIntensity: 240, gm: 20, gmFlag: 0),
            "bd0000000080621d3c82",
            "Telink 0x26 Sidus green-magenta packet"
        )
    }

    static func testTelinkDecode() throws {
        let decodedStatus = NativeTelinkControl.decodePacket(
            try NativeMeshCrypto.bytes(hex: "99010000004001233202")
        )
        let cctStatus = decodedStatus?["cct"] as? [String: Any]
        expectEqual(decodedStatus?["check_sum"] as? Int, 153, "Telink status checksum value")
        expectEqual(decodedStatus?["checksum_valid"] as? Bool, true, "Telink status checksum")
        expectEqual(decodedStatus?["command_type"] as? Int, 2, "Telink status command type")
        expectEqual(cctStatus?["intensity"] as? Int, 200, "Telink status intensity")
        expectEqual(cctStatus?["cct_decoded"] as? Int, 560, "Telink status CCT")
        expectEqual(cctStatus?["gm_decoded"] as? Int, 10, "Telink status green-magenta")
        expectEqual(cctStatus?["sleep_mode"] as? Int, 1, "Telink status sleep mode")
        let decodedColorStatus = NativeTelinkControl.decodePacket(
            try NativeMeshCrypto.bytes(hex: "4b000078c8000001000a")
        )
        let colorStatus = decodedColorStatus?["color"] as? [String: Any]
        expectEqual(decodedColorStatus?["check_sum"] as? Int, 75, "Telink color status checksum value")
        expectEqual(decodedColorStatus?["checksum_valid"] as? Bool, true, "Telink color status checksum")
        expectEqual(decodedColorStatus?["command_type"] as? Int, 10, "Telink color status command type")
        expectEqual(colorStatus?["hue_candidate"] as? Int, 120, "Telink color status hue candidate")
        expectEqual(colorStatus?["saturation_candidate"] as? Int, 200, "Telink color status saturation candidate")
        expectEqual(colorStatus?["mode_candidate"] as? Int, 1, "Telink color status mode candidate")
    }
}
