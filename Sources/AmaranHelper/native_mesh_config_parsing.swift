import Foundation

extension NativeMeshConfig {
    static func configAppKeyStatus(_ accessMessage: [UInt8]) throws -> NativeMeshConfigAppKeyStatus {
        guard accessMessage.count == 6 else {
            throw NativeMeshConfigError.invalidLength("Config AppKey Status must be 6 bytes")
        }
        guard Array(accessMessage.prefix(2)) == configAppKeyStatusOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config AppKey Status")
        }
        let indexes = unpackedKeyIndexes(Array(accessMessage[3..<6]))
        return NativeMeshConfigAppKeyStatus(
            status: accessMessage[2],
            netKeyIndex: indexes.0,
            appKeyIndex: indexes.1
        )
    }

    static func configAppKeyList(_ accessMessage: [UInt8]) throws -> NativeMeshConfigAppKeyListStatus {
        guard accessMessage.count >= 5 else {
            throw NativeMeshConfigError.invalidLength("Config AppKey List must include opcode, status, and NetKeyIndex")
        }
        guard Array(accessMessage.prefix(2)) == configAppKeyListOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config AppKey List")
        }
        return try NativeMeshConfigAppKeyListStatus(
            status: accessMessage[2],
            netKeyIndex: unpackedSingleKeyIndex(Array(accessMessage[3..<5])),
            appKeyIndexes: unpackedKeyIndexList(Array(accessMessage.dropFirst(5)))
        )
    }

    static func configCompositionDataStatus(_ accessMessage: [UInt8]) throws -> NativeMeshCompositionDataPage0 {
        guard accessMessage.count >= 12 else {
            throw NativeMeshConfigError.invalidLength(
                "Config Composition Data Status must include opcode, page, and header")
        }
        guard Array(accessMessage.prefix(1)) == configCompositionDataStatusOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config Composition Data Status")
        }
        guard accessMessage[1] == 0x00 else {
            throw NativeMeshConfigError.invalidParameter("only Composition Data Page 0 is supported")
        }
        return try compositionDataPage0(Array(accessMessage.dropFirst()))
    }

    static func configModelAppStatus(_ accessMessage: [UInt8]) throws -> NativeMeshConfigModelAppStatus {
        guard accessMessage.count == 9 || accessMessage.count == 11 else {
            throw NativeMeshConfigError.invalidLength("Config Model App Status must be 9 or 11 bytes")
        }
        guard Array(accessMessage.prefix(2)) == configModelAppStatusOpcode else {
            throw NativeMeshConfigError.invalidParameter("access message is not Config Model App Status")
        }
        let modelIdentifier: NativeMeshModelIdentifier
        if accessMessage.count == 9 {
            modelIdentifier = .sig(littleEndianUInt16(accessMessage, 7))
        } else {
            modelIdentifier = .vendor(
                companyIdentifier: littleEndianUInt16(accessMessage, 7),
                modelIdentifier: littleEndianUInt16(accessMessage, 9)
            )
        }
        return NativeMeshConfigModelAppStatus(
            status: accessMessage[2],
            elementAddress: littleEndianUInt16(accessMessage, 3),
            appKeyIndex: Int(littleEndianUInt16(accessMessage, 5) & 0x0fff),
            modelIdentifier: modelIdentifier
        )
    }

    static let statusNames: [UInt8: String] = [
        0x00: "success",
        0x01: "invalid_address",
        0x02: "invalid_model",
        0x03: "invalid_appkey_index",
        0x04: "invalid_netkey_index",
        0x05: "insufficient_resources",
        0x06: "key_index_already_stored",
        0x07: "invalid_publish_parameters",
        0x08: "not_a_subscribe_model",
        0x09: "storage_failure",
        0x0a: "feature_not_supported",
        0x0b: "cannot_update",
        0x0c: "cannot_remove",
        0x0d: "cannot_bind",
        0x0e: "temporarily_unable_to_change_state",
        0x0f: "cannot_set",
        0x10: "unspecified_error",
        0x11: "invalid_binding"
    ]

    static func statusName(_ status: UInt8) -> String {
        statusNames[status] ?? "unknown"
    }

    static func unpackedKeyIndexes(_ packed: [UInt8]) -> (Int, Int) {
        let first = Int(packed[0]) | ((Int(packed[1]) & 0x0f) << 8)
        let second = ((Int(packed[1]) & 0xf0) >> 4) | (Int(packed[2]) << 4)
        return (first, second)
    }

    static func unpackedSingleKeyIndex(_ packed: [UInt8]) throws -> Int {
        guard packed.count == 2 else {
            throw NativeMeshConfigError.invalidLength("single key index must be 2 bytes")
        }
        let index = Int(packed[0]) | ((Int(packed[1]) & 0x0f) << 8)
        try validateKeyIndex(index, label: "key index")
        return index
    }

    static func unpackedKeyIndexList(_ packed: [UInt8]) throws -> [Int] {
        var result: [Int] = []
        var offset = 0
        while offset < packed.count {
            let remaining = packed.count - offset
            if remaining >= 3 {
                let indexes = unpackedKeyIndexes(Array(packed[offset..<(offset + 3)]))
                try validateKeyIndex(indexes.0, label: "key index")
                try validateKeyIndex(indexes.1, label: "key index")
                result.append(indexes.0)
                result.append(indexes.1)
                offset += 3
            } else if remaining == 2 {
                result.append(try unpackedSingleKeyIndex(Array(packed[offset..<(offset + 2)])))
                offset += 2
            } else {
                throw NativeMeshConfigError.invalidLength("packed key index list is truncated")
            }
        }
        return result
    }

    static func compositionDataPage0(
        _ data: [UInt8],
        includedPageByte: Bool
    ) throws -> NativeMeshCompositionDataPage0 {
        guard data.count >= 10 else {
            throw NativeMeshConfigError.invalidLength("Composition Data Page 0 must include the 10-byte header")
        }

        var index = 0
        let cid = littleEndianUInt16(data, index)
        index += 2
        let pid = littleEndianUInt16(data, index)
        index += 2
        let vid = littleEndianUInt16(data, index)
        index += 2
        let crpl = littleEndianUInt16(data, index)
        index += 2
        let features = littleEndianUInt16(data, index)
        index += 2

        var elements: [NativeMeshCompositionElement] = []
        while index < data.count {
            elements.append(try parseCompositionElement(data, index: &index))
        }

        guard !elements.isEmpty else {
            throw NativeMeshConfigError.invalidLength("Composition Data Page 0 must include at least one element")
        }
        return NativeMeshCompositionDataPage0(
            cid: cid,
            pid: pid,
            vid: vid,
            crpl: crpl,
            features: features,
            elements: elements,
            includedPageByte: includedPageByte
        )
    }

    static func parseCompositionElement(
        _ data: [UInt8],
        index: inout Int
    ) throws -> NativeMeshCompositionElement {
        guard index + 4 <= data.count else {
            throw NativeMeshConfigError.invalidLength("Composition element header is truncated")
        }
        let location = littleEndianUInt16(data, index)
        index += 2
        let sigModelCount = Int(data[index])
        index += 1
        let vendorModelCount = Int(data[index])
        index += 1

        guard index + sigModelCount * 2 + vendorModelCount * 4 <= data.count else {
            throw NativeMeshConfigError.invalidLength("Composition element model list is truncated")
        }

        var sigModels: [UInt16] = []
        for _ in 0..<sigModelCount {
            sigModels.append(littleEndianUInt16(data, index))
            index += 2
        }

        var vendorModels: [NativeMeshVendorModel] = []
        for _ in 0..<vendorModelCount {
            let companyIdentifier = littleEndianUInt16(data, index)
            let modelIdentifier = littleEndianUInt16(data, index + 2)
            vendorModels.append(
                NativeMeshVendorModel(
                    companyIdentifier: companyIdentifier,
                    modelIdentifier: modelIdentifier
                )
            )
            index += 4
        }

        return NativeMeshCompositionElement(
            location: location,
            sigModels: sigModels,
            vendorModels: vendorModels
        )
    }

    static func littleEndianUInt16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }
}
