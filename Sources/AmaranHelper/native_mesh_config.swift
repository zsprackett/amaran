import Foundation

enum NativeMeshConfigError: Error, CustomStringConvertible {
    case invalidLength(String)
    case invalidParameter(String)

    var description: String {
        switch self {
        case .invalidLength(let value):
            return "invalid native config length: \(value)"
        case .invalidParameter(let value):
            return "invalid native config parameter: \(value)"
        }
    }
}

enum NativeMeshModelIdentifier: Equatable {
    case sig(UInt16)
    case vendor(companyIdentifier: UInt16, modelIdentifier: UInt16)
}

struct NativeMeshVendorModel: Equatable {
    let companyIdentifier: UInt16
    let modelIdentifier: UInt16
}

struct NativeMeshCompositionElement: Equatable {
    let location: UInt16
    let sigModels: [UInt16]
    let vendorModels: [NativeMeshVendorModel]
}

struct NativeMeshCompositionDataPage0: Equatable {
    let cid: UInt16
    let pid: UInt16
    let vid: UInt16
    let crpl: UInt16
    let features: UInt16
    let elements: [NativeMeshCompositionElement]
    let includedPageByte: Bool

    var firstVendorModelBindingTarget: (elementIndex: Int, model: NativeMeshVendorModel)? {
        for (index, element) in elements.enumerated() {
            if let model = element.vendorModels.first {
                return (index, model)
            }
        }
        return nil
    }
}

struct NativeMeshConfigAppKeyStatus: Equatable {
    let status: UInt8
    let netKeyIndex: Int
    let appKeyIndex: Int
}

struct NativeMeshConfigAppKeyListStatus: Equatable {
    let status: UInt8
    let netKeyIndex: Int
    let appKeyIndexes: [Int]
}

struct NativeMeshConfigModelAppStatus: Equatable {
    let status: UInt8
    let elementAddress: UInt16
    let appKeyIndex: Int
    let modelIdentifier: NativeMeshModelIdentifier
}

struct NativeMeshConfig {
    static let configAppKeyAddOpcode = [UInt8(0x00)]
    static let configAppKeyGetOpcode = [UInt8(0x80), UInt8(0x01)]
    static let configAppKeyListOpcode = [UInt8(0x80), UInt8(0x02)]
    static let configAppKeyStatusOpcode = [UInt8(0x80), UInt8(0x03)]
    static let configCompositionDataStatusOpcode = [UInt8(0x02)]
    static let configCompositionDataGetOpcode = [UInt8(0x80), UInt8(0x08)]
    static let configModelAppBindOpcode = [UInt8(0x80), UInt8(0x3d)]
    static let configModelAppStatusOpcode = [UInt8(0x80), UInt8(0x3e)]
    static let configNodeResetOpcode = [UInt8(0x80), UInt8(0x49)]
    static let configNodeResetStatusOpcode = [UInt8(0x80), UInt8(0x4a)]

    static func configCompositionDataGet(page: UInt8 = 0) -> [UInt8] {
        configCompositionDataGetOpcode + [page]
    }

    static func configNodeReset() -> [UInt8] {
        configNodeResetOpcode
    }

    static func configAppKeyAdd(
        netKeyIndex: Int,
        appKeyIndex: Int,
        appKey: [UInt8]
    ) throws -> [UInt8] {
        guard appKey.count == 16 else {
            throw NativeMeshConfigError.invalidLength("AppKey must be 16 bytes")
        }
        return try configAppKeyAddOpcode + packedKeyIndexes(netKeyIndex, appKeyIndex) + appKey
    }

    static func configAppKeyGet(netKeyIndex: Int) throws -> [UInt8] {
        try validateKeyIndex(netKeyIndex, label: "NetKey Index")
        return configAppKeyGetOpcode + littleEndianBytes(UInt64(netKeyIndex), count: 2)
    }

    static func configModelAppBind(
        elementAddress: UInt16,
        appKeyIndex: Int,
        modelIdentifier: NativeMeshModelIdentifier
    ) throws -> [UInt8] {
        guard (1...0x7fff).contains(Int(elementAddress)) else {
            throw NativeMeshConfigError.invalidParameter("element address must be a non-zero unicast address")
        }
        try validateKeyIndex(appKeyIndex, label: "AppKey Index")

        let modelBytes: [UInt8]
        switch modelIdentifier {
        case .sig(let modelIdentifier):
            modelBytes = littleEndianBytes(UInt64(modelIdentifier), count: 2)
        case .vendor(let companyIdentifier, let modelIdentifier):
            modelBytes = littleEndianBytes(UInt64(companyIdentifier), count: 2)
                + littleEndianBytes(UInt64(modelIdentifier), count: 2)
        }

        return configModelAppBindOpcode
            + littleEndianBytes(UInt64(elementAddress), count: 2)
            + littleEndianBytes(UInt64(appKeyIndex), count: 2)
            + modelBytes
    }

    static func packedKeyIndexes(_ first: Int, _ second: Int) throws -> [UInt8] {
        try validateKeyIndex(first, label: "first key index")
        try validateKeyIndex(second, label: "second key index")
        return [
            UInt8(first & 0xff),
            UInt8(((first >> 8) & 0x0f) | ((second & 0x0f) << 4)),
            UInt8((second >> 4) & 0xff)
        ]
    }

    static func requiresSegmentedLowerTransport(accessMessage: [UInt8], transMicLength: Int = 4) -> Bool {
        accessMessage.count + transMicLength > 15
    }

    static func compositionDataPage0(_ data: [UInt8]) throws -> NativeMeshCompositionDataPage0 {
        do {
            return try compositionDataPage0(data, includedPageByte: false)
        } catch {
            if data.first == 0x00 {
                return try compositionDataPage0(Array(data.dropFirst()), includedPageByte: true)
            }
            throw error
        }
    }

    static func validateKeyIndex(_ value: Int, label: String) throws {
        guard (0...0x0fff).contains(value) else {
            throw NativeMeshConfigError.invalidParameter("\(label) must be a 12-bit value")
        }
    }

    private static func littleEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { index in
            UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }
}
