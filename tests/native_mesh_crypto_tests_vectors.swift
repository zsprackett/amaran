import Foundation

extension NativeMeshCryptoTests {
    static func testNativeState(_ fixtures: NativeMeshTestFixtures) throws {
        let appKey = fixtures.appKey
        let sampleSecrets = fixtures.sampleSecrets
        let nativeStateFixture = NativeProvisionedFixtureState(
            uuid: "fixture-001",
            macAddress: "a4c138123c21",
            code: "400M5",
            name: nil,
            nodeAddress: 0x1201,
            deviceKey: sampleSecrets.deviceKey,
            deviceUUID: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            compositionData: try NativeMeshCrypto.bytes(hex: "010203"),
            updateTime: "2026-05-18T00:00:00Z"
        )
        let nativeStatePayload = try NativeMeshState.provisionedPayload(
            meshUUID: "mesh-001",
            keys: NativeMeshStateKeys(
                netKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
                appKey: appKey
            ),
            fixture: nativeStateFixture,
            provisionedAt: "2026-05-18T00:00:00Z",
            ivIndex: 0x01020304,
            sequenceNext: 1,
            sourceAddress: 1
        )
        try assertNativeStateBasePayload(nativeStatePayload, sampleSecrets: sampleSecrets)
        try assertNativeStateNoMac(appKey: appKey, sampleSecrets: sampleSecrets)
        try assertNativeStateAppend(basePayload: nativeStatePayload)
    }

    static func assertNativeStateBasePayload(
        _ nativeStatePayload: [String: Any],
        sampleSecrets: NativeProvisioningSecrets
    ) throws {
        try NativeMeshState.validatePayload(nativeStatePayload)
        expectEqual(nativeStatePayload["schema_version"] as? Int, 1, "Native state schema version")
        let nativeStateSource = nativeStatePayload["source"] as? [String: Any]
        expectEqual(nativeStateSource?["type"] as? String, "native_provisioning", "Native state source")
        let nativeStateMesh = nativeStatePayload["mesh"] as? [String: Any]
        expectEqual(nativeStateMesh?["uuid"] as? String, "mesh-001", "Native state mesh UUID")
        try expectHex(
            try NativeMeshCrypto.bytes(hex: nativeStateMesh?["net_key"] as? String ?? ""),
            "00112233445566778899aabbccddeeff",
            "Native state mesh net key"
        )
        let nativeStateFixtures = nativeStatePayload["fixtures"] as? [[String: Any]]
        let nativeStateFirstFixture = nativeStateFixtures?.first
        expectEqual(nativeStateFixtures?.count, 1, "Native state fixture count")
        expectEqual(nativeStateFirstFixture?["mac_address"] as? String, "A4:C1:38:12:3C:21", "Native state MAC")
        expectEqual(nativeStateFirstFixture?["name"] as? String, "400M5-123C21", "Native state generated name")
        expectEqual(nativeStateFirstFixture?["node_address"] as? Int, 0x1201, "Native state node address")
        expectEqual(
            nativeStateFirstFixture?["device_key"] as? String,
            NativeMeshCrypto.hex(sampleSecrets.deviceKey),
            "Native state device key field"
        )
        let nativeStateRuntime = nativeStatePayload["runtime"] as? [String: Any]
        expectEqual(nativeStateRuntime?["iv_index"] as? Int, 0x01020304, "Native state IV index")
        expectEqual(nativeStateRuntime?["source_address"] as? Int, 3, "Native state source address")
        expectEqual(nativeStateRuntime?["telink_source_address"] as? Int, 1, "Native state Telink source address")
        expectEqual(nativeStateRuntime?["sequence_next"] as? Int, 1, "Native state sequence")
        try assertNativeStateRoundTrip(nativeStatePayload)
    }

    static func assertNativeStateRoundTrip(_ nativeStatePayload: [String: Any]) throws {
        let nativeStateEncoded = try NativeMeshState.encodedPayload(nativeStatePayload)
        let nativeStateDecoded = try JSONSerialization.jsonObject(with: nativeStateEncoded) as? [String: Any]
        try NativeMeshState.validatePayload(nativeStateDecoded ?? [:])
        let nativeStatePath = "\(NSTemporaryDirectory())amaran-state-\(UUID().uuidString).json"
        defer {
            try? FileManager.default.removeItem(atPath: nativeStatePath)
        }
        try NativeMeshState.writePayload(nativeStatePayload, to: nativeStatePath)
        let nativeStateWritten = try Data(contentsOf: URL(fileURLWithPath: nativeStatePath))
        let nativeStateWrittenPayload = try JSONSerialization.jsonObject(with: nativeStateWritten) as? [String: Any]
        try NativeMeshState.validatePayload(nativeStateWrittenPayload ?? [:])
        let nativeStateAttributes = try FileManager.default.attributesOfItem(atPath: nativeStatePath)
        expectEqual(nativeStateAttributes[.posixPermissions] as? Int, 0o600, "Native state file permissions")
    }

    static func assertNativeStateNoMac(appKey: [UInt8], sampleSecrets: NativeProvisioningSecrets) throws {
        let nativeStateNoMacFixture = NativeProvisionedFixtureState(
            uuid: "fixture-002",
            macAddress: nil,
            code: "400M5",
            name: nil,
            nodeAddress: 0x1202,
            deviceKey: sampleSecrets.deviceKey,
            deviceUUID: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
            compositionData: nil,
            updateTime: "2026-05-18T00:00:00Z"
        )
        let nativeStateNoMacPayload = try NativeMeshState.provisionedPayload(
            meshUUID: "mesh-002",
            keys: NativeMeshStateKeys(
                netKey: try NativeMeshCrypto.bytes(hex: "00112233445566778899aabbccddeeff"),
                appKey: appKey
            ),
            fixture: nativeStateNoMacFixture,
            provisionedAt: "2026-05-18T00:00:00Z",
            ivIndex: 0,
            sequenceNext: 1,
            sourceAddress: 1
        )
        try NativeMeshState.validatePayload(nativeStateNoMacPayload)
        let nativeStateNoMacFixtures = nativeStateNoMacPayload["fixtures"] as? [[String: Any]]
        let nativeStateNoMacFirstFixture = nativeStateNoMacFixtures?.first
        expectEqual(nativeStateNoMacFirstFixture?["mac_address"] as? String, "", "Native state no-MAC field")
        expectEqual(
            nativeStateNoMacFirstFixture?["mac_address_source"] as? String,
            "unavailable_corebluetooth",
            "Native state no-MAC source"
        )
        expectEqual(nativeStateNoMacFirstFixture?["name"] as? String, "400M5-DDEEFF", "Native state no-MAC name")
    }

    static func assertNativeStateAppend(basePayload nativeStatePayload: [String: Any]) throws {
        let nativeStateMesh = nativeStatePayload["mesh"] as? [String: Any]
        let nativeStateRuntime = nativeStatePayload["runtime"] as? [String: Any]
        let nativeStateAppendFixture = NativeProvisionedFixtureState(
            uuid: "fixture-append",
            macAddress: nil,
            code: "400M5",
            name: "append-test",
            nodeAddress: 0x1211,
            deviceKey: try NativeMeshCrypto.bytes(hex: "0102030405060708090a0b0c0d0e0f10"),
            deviceUUID: try NativeMeshCrypto.bytes(hex: "ffeeddccbbaa99887766554433221100"),
            compositionData: nil,
            elementCount: 2,
            updateTime: "2026-05-18T00:01:00Z"
        )
        let appendedNativeStatePayload = try NativeMeshState.appendingProvisionedFixturePayload(
            existingPayload: nativeStatePayload,
            fixture: nativeStateAppendFixture,
            provisionedAt: "2026-05-18T00:01:00Z"
        )
        try NativeMeshState.validatePayload(appendedNativeStatePayload)
        let appendedNativeStateSource = appendedNativeStatePayload["source"] as? [String: Any]
        expectEqual(
            appendedNativeStateSource?["type"] as? String,
            "native_provisioning_append",
            "Native state append source"
        )
        let appendedNativeStateMesh = appendedNativeStatePayload["mesh"] as? [String: Any]
        expectEqual(
            appendedNativeStateMesh?["net_key"] as? String,
            nativeStateMesh?["net_key"] as? String,
            "Native state append preserves NetKey"
        )
        let appendedNativeStateRuntime = appendedNativeStatePayload["runtime"] as? [String: Any]
        expectEqual(
            appendedNativeStateRuntime?["sequence_next"] as? Int,
            nativeStateRuntime?["sequence_next"] as? Int,
            "Native state append preserves sequence"
        )
        let appendedNativeStateFixtures = appendedNativeStatePayload["fixtures"] as? [[String: Any]]
        expectEqual(appendedNativeStateFixtures?.count, 2, "Native state append fixture count")
        expectEqual(appendedNativeStateFixtures?[1]["node_address"] as? Int, 0x1211, "Native state append node")
        expectEqual(appendedNativeStateFixtures?[1]["element_count"] as? Int, 2, "Native state append element count")
        try assertNativeStateDuplicateAndRuntimeOnly(
            basePayload: nativeStatePayload,
            appendFixture: nativeStateAppendFixture
        )
    }

    static func assertNativeStateDuplicateAndRuntimeOnly(
        basePayload nativeStatePayload: [String: Any],
        appendFixture nativeStateAppendFixture: NativeProvisionedFixtureState
    ) throws {
        expectThrows("Native state duplicate append address") {
            _ = try NativeMeshState.appendingProvisionedFixturePayload(
                existingPayload: nativeStatePayload,
                fixture: NativeProvisionedFixtureState(
                    uuid: "fixture-duplicate",
                    macAddress: nil,
                    code: nil,
                    name: nil,
                    nodeAddress: 0x1201,
                    deviceKey: try NativeMeshCrypto.bytes(hex: "11111111111111111111111111111111"),
                    deviceUUID: try NativeMeshCrypto.bytes(hex: "11111111111111111111111111111111"),
                    compositionData: nil,
                    updateTime: "2026-05-18T00:02:00Z"
                ),
                provisionedAt: "2026-05-18T00:02:00Z"
            )
        }
        var runtimeOnlyNativeStatePayload = nativeStatePayload
        runtimeOnlyNativeStatePayload["source"] = [
            "type": "mesh_join_import",
            "control_only": true
        ]
        var runtimeOnlyFixtures = nativeStatePayload["fixtures"] as? [[String: Any]] ?? []
        runtimeOnlyFixtures[0].removeValue(forKey: "device_key")
        runtimeOnlyFixtures[0].removeValue(forKey: "device_uuid")
        runtimeOnlyFixtures[0]["control_only"] = true
        runtimeOnlyNativeStatePayload["fixtures"] = runtimeOnlyFixtures
        try NativeMeshState.validatePayload(runtimeOnlyNativeStatePayload)
        let appendedRuntimeOnlyPayload = try NativeMeshState.appendingProvisionedFixturePayload(
            existingPayload: runtimeOnlyNativeStatePayload,
            fixture: nativeStateAppendFixture,
            provisionedAt: "2026-05-18T00:03:00Z"
        )
        try NativeMeshState.validatePayload(appendedRuntimeOnlyPayload)
        let appendedRuntimeOnlyFixtures = appendedRuntimeOnlyPayload["fixtures"] as? [[String: Any]]
        expectEqual(appendedRuntimeOnlyFixtures?.count, 2, "Native runtime-only append fixture count")
        expectEqual(
            appendedRuntimeOnlyFixtures?.first?["control_only"] as? Bool,
            true,
            "Native runtime-only fixture marker"
        )
    }

    static func testApplicationAccess(_ fixtures: NativeMeshTestFixtures) throws {
        let netKey = fixtures.netKey
        let appKey = fixtures.appKey
        let keyMaterial = fixtures.k2Material
        let applicationAccess = try NativeMeshCrypto.applicationAccessProxyPdu(
            context: MeshMessageContext(
                ivIndex: 0x12345678,
                sequence: 0x000007,
                source: 0x1201,
                destination: 0xffff
            ),
            ttl: 0x03,
            netKey: netKey,
            applicationKey: appKey,
            accessMessage: NativeMeshCrypto.bytes(hex: "0400000000")
        )
        try assertApplicationAccessEncode(applicationAccess)
        try assertApplicationAccessDecode(applicationAccess, appKey: appKey, keyMaterial: keyMaterial)
        try assertProxyConfigurationAndIdentity(netKey: netKey)
    }

    static func assertApplicationAccessEncode(_ applicationAccess: ApplicationAccessProxyPduResult) throws {
        expectEqual(applicationAccess.aid, 0x26, "Mesh access AID")
        try expectHex(applicationAccess.upperTransport.nonce, "01000000071201ffff12345678", "Mesh application nonce")
        try expectHex(applicationAccess.upperTransport.encAccessMessage, "5a8bde6d91", "Mesh EncAccessMessage")
        try expectHex(applicationAccess.upperTransport.transMic, "06ea078a", "Mesh TransMIC")
        try expectHex(
            applicationAccess.upperTransport.upperTransportPdu,
            "5a8bde6d9106ea078a",
            "Mesh UpperTransportPDU"
        )
        expectEqual(applicationAccess.lowerTransport.header, 0x66, "Mesh lower transport access header")
        try expectHex(
            applicationAccess.lowerTransport.lowerTransportPdu,
            "665a8bde6d9106ea078a",
            "Mesh LowerTransportPDU"
        )
        try expectHex(applicationAccess.network.nonce, "00030000071201000012345678", "Mesh access Network nonce")
        try expectHex(
            applicationAccess.network.networkPdu,
            "6848cba437860e5673728a627fb938535508e21a6baf57",
            "Mesh access NetworkPDU"
        )
        try expectHex(
            applicationAccess.network.proxyPdu,
            "006848cba437860e5673728a627fb938535508e21a6baf57",
            "Mesh access ProxyPDU"
        )
    }

    static func assertApplicationAccessDecode(
        _ applicationAccess: ApplicationAccessProxyPduResult,
        appKey: [UInt8],
        keyMaterial: MeshKeyMaterial
    ) throws {
        let decodedApplicationNetwork = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: applicationAccess.network.networkPdu,
            ivIndex: 0x12345678,
            nid: keyMaterial.nid,
            encryptionKey: keyMaterial.encryptionKey,
            privacyKey: keyMaterial.privacyKey
        )
        expectEqual(decodedApplicationNetwork.ctl, 0, "Mesh access decoded CTL")
        expectEqual(decodedApplicationNetwork.ttl, 0x03, "Mesh access decoded TTL")
        expectEqual(decodedApplicationNetwork.sequence, 0x000007, "Mesh access decoded SEQ")
        expectEqual(decodedApplicationNetwork.source, 0x1201, "Mesh access decoded SRC")
        expectEqual(decodedApplicationNetwork.destination, 0xffff, "Mesh access decoded DST")
        try expectHex(decodedApplicationNetwork.transportPdu, "665a8bde6d9106ea078a", "Mesh access decoded transport")
        let decodedLowerTransport = try NativeMeshCrypto.decodeLowerTransportUnsegmentedAccessPdu(
            lowerTransportPdu: decodedApplicationNetwork.transportPdu
        )
        expectEqual(decodedLowerTransport.akf, true, "Mesh lower transport decoded AKF")
        expectEqual(decodedLowerTransport.aid, 0x26, "Mesh lower transport decoded AID")
        let decodedUpperTransport = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
            applicationKey: appKey,
            context: MeshMessageContext(
                ivIndex: 0x12345678,
                sequence: decodedApplicationNetwork.sequence,
                source: decodedApplicationNetwork.source,
                destination: decodedApplicationNetwork.destination
            ),
            upperTransportPdu: decodedLowerTransport.upperTransportPdu
        )
        try expectHex(decodedUpperTransport.accessMessage, "0400000000", "Mesh decoded access message")
    }

    static func assertProxyConfigurationAndIdentity(netKey: [UInt8]) throws {
        let proxyConfiguration = try NativeMeshCrypto.proxyConfigurationProxyPdu(
            ivIndex: 0x12345678,
            sequence: 0x000001,
            source: 0x0001,
            netKey: try NativeMeshCrypto.bytes(hex: "d1aafb2a1a3c281cbdb0e960edfad852"),
            transportPdu: [0x00, 0x00]
        )
        try expectHex(
            proxyConfiguration.nonce,
            "03000000010001000012345678",
            "Mesh proxy configuration nonce"
        )
        try expectHex(
            proxyConfiguration.proxyPdu,
            "0210386bd60efbbb8b8c28512e792d3711f4b526",
            "Mesh proxy configuration Set Filter Type vector"
        )
        let identitySalt = try NativeMeshCrypto.s1("nkik")
        let identityKey = try NativeMeshCrypto.k1(
            n: netKey,
            salt: identitySalt,
            p: NativeMeshCrypto.ascii("id128") + [0x01]
        )
        try expectHex(identityKey, "84396c435ac48560b5965385253e210c", "Mesh IdentityKey")
    }
}
