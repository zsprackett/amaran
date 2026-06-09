import CommonCrypto
import Foundation

extension NativeMeshCrypto {
    static func s1(_ value: String) throws -> [UInt8] {
        try aesCmac(key: zeroKey, message: ascii(value))
    }

    static func k1(n nKey: [UInt8], salt: [UInt8], p pBytes: [UInt8]) throws -> [UInt8] {
        let tKey = try aesCmac(key: salt, message: nKey)
        return try aesCmac(key: tKey, message: pBytes)
    }

    static func k2(n nKey: [UInt8], p pBytes: [UInt8]) throws -> MeshKeyMaterial {
        let salt = try s1("smk2")
        let tKey = try aesCmac(key: salt, message: nKey)
        let round1 = try aesCmac(key: tKey, message: pBytes + [0x01])
        let round2 = try aesCmac(key: tKey, message: round1 + pBytes + [0x02])
        let round3 = try aesCmac(key: tKey, message: round2 + pBytes + [0x03])
        return MeshKeyMaterial(nid: round1[15] & 0x7f, encryptionKey: round2, privacyKey: round3)
    }

    static func k3(n nKey: [UInt8]) throws -> [UInt8] {
        let salt = try s1("smk3")
        let tKey = try aesCmac(key: salt, message: nKey)
        let result = try aesCmac(key: tKey, message: ascii("id64") + [0x01])
        return Array(result.suffix(8))
    }

    static func k4(n nKey: [UInt8]) throws -> UInt8 {
        let salt = try s1("smk4")
        let tKey = try aesCmac(key: salt, message: nKey)
        let result = try aesCmac(key: tKey, message: ascii("id6") + [0x01])
        return result[15] & 0x3f
    }

    static func networkNonce(ctl: UInt8, ttl: UInt8, sequence: UInt32, source: UInt16, ivIndex: UInt32) -> [UInt8] {
        [0x00, ((ctl & 0x01) << 7) | (ttl & 0x7f)]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
            + [0x00, 0x00]
            + uintBytes(UInt64(ivIndex), count: 4)
    }

    static func proxyNonce(sequence: UInt32, source: UInt16, ivIndex: UInt32) -> [UInt8] {
        [0x03, 0x00]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
            + [0x00, 0x00]
            + uintBytes(UInt64(ivIndex), count: 4)
    }

    static func applicationNonce(
        aszmic: Bool = false,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32
    ) -> [UInt8] {
        [0x01, aszmic ? 0x80 : 0x00]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
            + uintBytes(UInt64(destination), count: 2)
            + uintBytes(UInt64(ivIndex), count: 4)
    }

    static func deviceNonce(
        aszmic: Bool = false,
        sequence: UInt32,
        source: UInt16,
        destination: UInt16,
        ivIndex: UInt32
    ) -> [UInt8] {
        [0x02, aszmic ? 0x80 : 0x00]
            + uintBytes(sequence, count: 3)
            + uintBytes(UInt64(source), count: 2)
            + uintBytes(UInt64(destination), count: 2)
            + uintBytes(UInt64(ivIndex), count: 4)
    }
}
