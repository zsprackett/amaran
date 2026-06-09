import Foundation

extension NativeMeshState {
    static func fixtureName(
        code: String?,
        macAddress: String?,
        deviceUUIDHex: String,
        nodeAddress: UInt16
    ) -> String {
        let suffix = macAddress?.filter { $0 != ":" }.suffix(6) ?? deviceUUIDHex.uppercased().suffix(6)
        if let code, !code.isEmpty {
            return "\(code)-\(suffix)"
        }
        return suffix.isEmpty ? "fixture-\(nodeAddress)" : String(suffix)
    }

    static func fixturePayload(_ fixture: NativeProvisionedFixtureState) throws -> [String: Any] {
        try validateAesKey(fixture.deviceKey, label: "device key")
        guard fixture.deviceUUID.count == 16 else {
            throw NativeMeshStateError.invalidLength("device UUID must be 16 bytes")
        }
        guard !fixture.uuid.isEmpty else {
            throw NativeMeshStateError.invalidParameter("fixture UUID is required")
        }
        guard (1...0x7fff).contains(Int(fixture.nodeAddress)) else {
            throw NativeMeshStateError.invalidParameter("fixture node address must be a non-zero unicast address")
        }
        if let elementCount = fixture.elementCount, !(1...255).contains(elementCount) {
            throw NativeMeshStateError.invalidParameter("fixture element_count must be 1..255")
        }

        let macAddress = try normalizedOptionalMacAddress(fixture.macAddress)
        let deviceUUIDHex = NativeMeshCrypto.hex(fixture.deviceUUID)
        var payload: [String: Any] = [
            "uuid": fixture.uuid,
            "mac_address": macAddress ?? "",
            "code": fixture.code ?? "",
            "device_key": NativeMeshCrypto.hex(fixture.deviceKey),
            "device_uuid": deviceUUIDHex,
            "composition_data": NativeMeshCrypto.hex(fixture.compositionData ?? []),
            "fast_provision_supported": 0,
            "control_hw_version": "",
            "name": fixture.name ?? fixtureName(
                code: fixture.code,
                macAddress: macAddress,
                deviceUUIDHex: deviceUUIDHex,
                nodeAddress: fixture.nodeAddress
            ),
            "node_address": Int(fixture.nodeAddress),
            "update_time": fixture.updateTime,
            "state": 0,
            "control_software_version": "",
            "driver_software_version": "",
            "driver_hardware_version": "",
            "ble_software_version": "",
            "ble_hardware_version": ""
        ]
        if let elementCount = fixture.elementCount {
            payload["element_count"] = elementCount
        }
        if macAddress == nil {
            payload["mac_address_source"] = "unavailable_corebluetooth"
        }
        return payload
    }

    static func validateAesKey(_ key: [UInt8], label: String) throws {
        guard key.count == 16 else {
            throw NativeMeshStateError.invalidLength("\(label) must be 16 bytes")
        }
    }

    static func validateHexString(_ value: String?, bytes: Int, label: String) throws {
        guard let value, value.count == bytes * 2, value.allSatisfy({ $0.isHexDigit }) else {
            throw NativeMeshStateError.invalidPayload("\(label) must be \(bytes) bytes of hex")
        }
    }

    static func validateOptionalHexString(_ value: String?, label: String) throws {
        guard let value, !value.isEmpty else {
            return
        }
        guard value.count % 2 == 0, value.allSatisfy({ $0.isHexDigit }) else {
            throw NativeMeshStateError.invalidPayload("\(label) must be hex")
        }
    }

    static func validateOptionalHexString(_ value: String?, bytes: Int, label: String) throws {
        guard let value, !value.isEmpty else {
            return
        }
        try validateHexString(value, bytes: bytes, label: label)
    }

    static func fixtureElementCount(_ fixture: [String: Any]) throws -> Int {
        if let compositionHex = fixture["composition_data"] as? String, !compositionHex.isEmpty {
            let compositionBytes = try NativeMeshCrypto.bytes(hex: compositionHex)
            if let composition = try? NativeMeshConfig.compositionDataPage0(compositionBytes) {
                return max(1, composition.elements.count)
            }
        }
        if let elementCount = intValue(fixture["element_count"]) {
            guard (1...255).contains(elementCount) else {
                throw NativeMeshStateError.invalidPayload("fixture element_count must be 1..255")
            }
            return elementCount
        }
        return 1
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}
