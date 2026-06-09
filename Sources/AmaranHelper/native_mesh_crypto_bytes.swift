import CommonCrypto
import Foundation

extension NativeMeshCrypto {
    static func uintBytes(_ value: UInt32, count: Int) -> [UInt8] {
        uintBytes(UInt64(value), count: count)
    }

    static func uintBytes(_ value: UInt64, count: Int) -> [UInt8] {
        stride(from: count - 1, through: 0, by: -1).map { UInt8((value >> UInt64($0 * 8)) & 0xff) }
    }

    static func uint16(bytes: [UInt8]) -> UInt16 {
        bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    static func uint32(bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func littleEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> UInt64($0 * 8)) & 0xff) }
    }

    static func appendZeroPadding(_ data: inout [UInt8]) {
        let remainder = data.count % kCCBlockSizeAES128
        if remainder != 0 {
            data += [UInt8](repeating: 0, count: kCCBlockSizeAES128 - remainder)
        }
    }

    static func dbl(_ block: [UInt8]) -> [UInt8] {
        let carry = (block[0] & 0x80) != 0
        var result = leftShiftOneBit(block)
        if carry {
            result[15] ^= 0x87
        }
        return result
    }

    static func leftShiftOneBit(_ block: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: block.count)
        var carry: UInt8 = 0
        for index in stride(from: block.count - 1, through: 0, by: -1) {
            let nextCarry = (block[index] & 0x80) != 0 ? UInt8(1) : UInt8(0)
            result[index] = (block[index] << 1) | carry
            carry = nextCarry
        }
        return result
    }

    static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        zip(lhs, rhs).map { $0 ^ $1 }
    }
}
