import Foundation

extension MeshGattProbe {
    func accessMessageSummaryWithState(_ accessMessage: [UInt8]) -> [String: Any] {
        var access = accessMessageSummary(accessMessage)
        if options.storeConfigCompositionData {
            storeCompositionDataIfPresent(accessMessage, accessSummary: &access)
        }
        return access
    }

    func storeCompositionDataIfPresent(_ accessMessage: [UInt8], accessSummary: inout [String: Any]) {
        guard Array(accessMessage.prefix(1)) == NativeMeshConfig.configCompositionDataStatusOpcode else {
            return
        }
        do {
            let composition = try NativeMeshConfig.configCompositionDataStatus(accessMessage)
            let compositionPayload = Array(accessMessage.dropFirst())
            let data = try Data(contentsOf: URL(fileURLWithPath: options.statePath))
            guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AmaranHelperError.invalidState("state file must contain a JSON object")
            }
            guard var fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
                throw AmaranHelperError.invalidState("state file is missing fixtures")
            }
            let targetAddress = options.nativeSendMetadata?["address"].flatMap(jsonInt)
            let fixtureIndex: Int
            if let targetAddress,
               let matched = fixtures.firstIndex(where: { jsonInt($0["node_address"]) == targetAddress }) {
                fixtureIndex = matched
            } else if fixtures.count == 1 {
                fixtureIndex = 0
            } else {
                throw AmaranHelperError.invalidState("multiple fixtures found; cannot store composition data")
            }

            let now = isoTimestamp()
            fixtures[fixtureIndex]["composition_data"] = NativeMeshCrypto.hex(compositionPayload)
            fixtures[fixtureIndex]["update_time"] = now
            payload["fixtures"] = fixtures

            var runtime = payload["runtime"] as? [String: Any] ?? [:]
            runtime["updated_at"] = now
            payload["runtime"] = runtime

            let updated = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: URL(fileURLWithPath: options.statePath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: options.statePath)

            var summary = compositionDataSummary(composition)
            summary["stored"] = true
            summary["state_path"] = options.statePath
            storedCompositionDataSummary = summary
            accessSummary["state_update"] = summary
        } catch {
            accessSummary["state_update"] = [
                "stored": false,
                "error": String(describing: error)
            ]
        }
    }

    func accessMessageSummary(_ accessMessage: [UInt8]) -> [String: Any] {
        guard let opcodeLength = accessOpcodeLength(accessMessage) else {
            return ["decode_error": "invalid access opcode", "bytes": accessMessage.count]
        }
        let opcode = Array(accessMessage.prefix(opcodeLength))
        let parameters = Array(accessMessage.dropFirst(opcodeLength))
        var result: [String: Any] = [
            "opcode": NativeMeshCrypto.hex(opcode),
            "opcode_type": opcodeLength == 3 ? "vendor" : "sig",
            "parameters_bytes": max(0, accessMessage.count - opcodeLength)
        ]
        if options.includeRawAccess {
            result["access_message_hex"] = NativeMeshCrypto.hex(accessMessage)
            result["parameters_hex"] = NativeMeshCrypto.hex(parameters)
        }
        if let config = configMessageSummary(accessMessage) {
            result["config"] = config
        }
        if opcodeLength == 3 {
            result["vendor_opcode"] = opcode[0] & 0x3f
            result["company_id"] = String(format: "%04x", UInt16(opcode[1]) | (UInt16(opcode[2]) << 8))
        } else if opcodeLength == 1 && opcode[0] == NativeTelinkControl.accessOpcode {
            if let telink = NativeTelinkControl.decodePacket(parameters) {
                result["telink"] = telink
            }
        }
        return result
    }

    func configMessageSummary(_ accessMessage: [UInt8]) -> [String: Any]? {
        if Array(accessMessage.prefix(1)) == NativeMeshConfig.configCompositionDataStatusOpcode {
            return compositionDataStatusSummary(accessMessage)
        }
        if Array(accessMessage.prefix(2)) == NativeMeshConfig.configAppKeyListOpcode {
            return appKeyListSummary(accessMessage)
        }
        if Array(accessMessage.prefix(2)) == NativeMeshConfig.configAppKeyStatusOpcode {
            return appKeyStatusSummary(accessMessage)
        }
        if Array(accessMessage.prefix(2)) == NativeMeshConfig.configModelAppStatusOpcode {
            return modelAppStatusSummary(accessMessage)
        }
        if accessMessage == NativeMeshConfig.configNodeResetStatusOpcode {
            return [
                "message": "node_reset_status",
                "destructive": true
            ]
        }
        return nil
    }

    private func compositionDataStatusSummary(_ accessMessage: [UInt8]) -> [String: Any] {
        do {
            let composition = try NativeMeshConfig.configCompositionDataStatus(accessMessage)
            var result = compositionDataSummary(composition)
            result["message"] = "composition_data_status"
            result["page"] = 0
            result["composition_data_bytes"] = max(0, accessMessage.count - 1)
            return result
        } catch {
            return [
                "message": "composition_data_status",
                "decode_error": String(describing: error)
            ]
        }
    }

    private func appKeyListSummary(_ accessMessage: [UInt8]) -> [String: Any] {
        do {
            let status = try NativeMeshConfig.configAppKeyList(accessMessage)
            return [
                "message": "appkey_list",
                "status": status.status,
                "status_name": NativeMeshConfig.statusName(status.status),
                "net_key_index": status.netKeyIndex,
                "app_key_indexes": status.appKeyIndexes,
                "app_key_count": status.appKeyIndexes.count
            ]
        } catch {
            return [
                "message": "appkey_list",
                "decode_error": String(describing: error)
            ]
        }
    }

    private func appKeyStatusSummary(_ accessMessage: [UInt8]) -> [String: Any] {
        do {
            let status = try NativeMeshConfig.configAppKeyStatus(accessMessage)
            return [
                "message": "appkey_status",
                "status": Int(status.status),
                "status_name": NativeMeshConfig.statusName(status.status),
                "net_key_index": status.netKeyIndex,
                "app_key_index": status.appKeyIndex
            ]
        } catch {
            return [
                "message": "appkey_status",
                "decode_error": String(describing: error)
            ]
        }
    }

    private func modelAppStatusSummary(_ accessMessage: [UInt8]) -> [String: Any] {
        do {
            let status = try NativeMeshConfig.configModelAppStatus(accessMessage)
            var result: [String: Any] = [
                "message": "model_app_status",
                "status": Int(status.status),
                "status_name": NativeMeshConfig.statusName(status.status),
                "element_address": Int(status.elementAddress),
                "app_key_index": status.appKeyIndex
            ]
            switch status.modelIdentifier {
            case .sig(let modelIdentifier):
                result["model_type"] = "sig"
                result["model_id"] = String(format: "%04x", modelIdentifier)
            case .vendor(let companyIdentifier, let modelIdentifier):
                result["model_type"] = "vendor"
                result["model_company_id"] = String(format: "%04x", companyIdentifier)
                result["model_id"] = String(format: "%04x", modelIdentifier)
            }
            return result
        } catch {
            return [
                "message": "model_app_status",
                "decode_error": String(describing: error)
            ]
        }
    }

    func compositionDataSummary(_ composition: NativeMeshCompositionDataPage0) -> [String: Any] {
        let sigModelCount = composition.elements.reduce(0) { $0 + $1.sigModels.count }
        let vendorModelCount = composition.elements.reduce(0) { $0 + $1.vendorModels.count }
        var result: [String: Any] = [
            "cid": String(format: "%04x", composition.cid),
            "pid": String(format: "%04x", composition.pid),
            "vid": String(format: "%04x", composition.vid),
            "crpl": Int(composition.crpl),
            "features": Int(composition.features),
            "element_count": composition.elements.count,
            "sig_model_count": sigModelCount,
            "vendor_model_count": vendorModelCount
        ]
        if let target = composition.firstVendorModelBindingTarget {
            result["first_vendor_element_index"] = target.elementIndex
            result["first_vendor_company_id"] = String(format: "%04x", target.model.companyIdentifier)
            result["first_vendor_model_id"] = String(format: "%04x", target.model.modelIdentifier)
        }
        return result
    }
}
