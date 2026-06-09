import CommonCrypto
import Foundation

enum NativeMeshCryptoError: Error, CustomStringConvertible {
    case invalidHex(String)
    case invalidLength(String)
    case invalidParameter(String)
    case authenticationFailed(String)
    case cryptorStatus(CCCryptorStatus)

    var description: String {
        switch self {
        case .invalidHex(let value):
            return "invalid hex: \(value)"
        case .invalidLength(let value):
            return "invalid length: \(value)"
        case .invalidParameter(let value):
            return "invalid parameter: \(value)"
        case .authenticationFailed(let value):
            return "authentication failed: \(value)"
        case .cryptorStatus(let status):
            return "CommonCrypto status \(status)"
        }
    }
}

struct NativeMeshCrypto {
    static let zeroKey = [UInt8](repeating: 0, count: 16)

    static func bytes(hex: String) throws -> [UInt8] {
        let compact = hex.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard compact.count % 2 == 0 else {
            throw NativeMeshCryptoError.invalidHex(hex)
        }

        var result: [UInt8] = []
        result.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw NativeMeshCryptoError.invalidHex(hex)
            }
            result.append(byte)
            index = next
        }
        return result
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func ascii(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    static func aes128EncryptBlock(key: [UInt8], block: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("AES-128 key must be 16 bytes")
        }
        guard block.count == kCCBlockSizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("AES block must be 16 bytes")
        }

        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = key.withUnsafeBytes { keyPtr in
            block.withUnsafeBytes { blockPtr in
                output.withUnsafeMutableBytes { outputPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        key.count,
                        nil,
                        blockPtr.baseAddress,
                        block.count,
                        outputPtr.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NativeMeshCryptoError.cryptorStatus(status)
        }
        return Array(output.prefix(outputLength))
    }

    static func aesCmac(key: [UInt8], message: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("CMAC key must be 16 bytes")
        }

        let (subkey1, subkey2) = try cmacSubkeys(key: key)
        let blockCount = max(1, Int(ceil(Double(message.count) / Double(kCCBlockSizeAES128))))
        let lastBlockComplete = !message.isEmpty && message.count % kCCBlockSizeAES128 == 0
        let lastBlock: [UInt8]
        if lastBlockComplete {
            let start = (blockCount - 1) * kCCBlockSizeAES128
            lastBlock = xor(Array(message[start..<start + kCCBlockSizeAES128]), subkey1)
        } else {
            let start = (blockCount - 1) * kCCBlockSizeAES128
            let remainder = message.count - start
            var padded = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
            if remainder > 0 {
                padded.replaceSubrange(0..<remainder, with: message[start..<message.count])
            }
            padded[remainder] = 0x80
            lastBlock = xor(padded, subkey2)
        }

        var state = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        if blockCount > 1 {
            for blockIndex in 0..<(blockCount - 1) {
                let start = blockIndex * kCCBlockSizeAES128
                let block = Array(message[start..<start + kCCBlockSizeAES128])
                state = try aes128EncryptBlock(key: key, block: xor(state, block))
            }
        }
        return try aes128EncryptBlock(key: key, block: xor(state, lastBlock))
    }

    static func aesCcmEncrypt(
        key: [UInt8],
        nonce: [UInt8],
        plaintext: [UInt8],
        aad: [UInt8] = [],
        micLength: Int
    ) throws -> AesCcmResult {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("CCM key must be 16 bytes")
        }
        guard (7...13).contains(nonce.count) else {
            throw NativeMeshCryptoError.invalidLength("CCM nonce must be 7 to 13 bytes")
        }
        guard (4...16).contains(micLength) && micLength % 2 == 0 else {
            throw NativeMeshCryptoError.invalidLength("CCM MIC length must be even and 4 to 16 bytes")
        }

        let lengthFieldSize = 15 - nonce.count
        if lengthFieldSize < MemoryLayout<Int>.size {
            guard plaintext.count < (1 << (8 * lengthFieldSize)) else {
                throw NativeMeshCryptoError.invalidLength("CCM plaintext too long for nonce length")
            }
        }

        let authenticationBlocks = try ccmAuthenticationBlocks(
            nonce: nonce,
            plaintext: plaintext,
            aad: aad,
            micLength: micLength,
            lengthFieldSize: lengthFieldSize
        )
        var state = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        for block in authenticationBlocks {
            state = try aes128EncryptBlock(key: key, block: xor(state, block))
        }
        let authenticationValue = Array(state.prefix(micLength))

        let s0Block = try aes128EncryptBlock(
            key: key,
            block: ccmCounterBlock(nonce: nonce, lengthFieldSize: lengthFieldSize, counter: 0))
        let mic = xor(authenticationValue, Array(s0Block.prefix(micLength)))

        var ciphertext: [UInt8] = []
        ciphertext.reserveCapacity(plaintext.count)
        var counter = 1
        var offset = 0
        while offset < plaintext.count {
            let stream = try aes128EncryptBlock(
                key: key,
                block: ccmCounterBlock(nonce: nonce, lengthFieldSize: lengthFieldSize, counter: counter)
            )
            let count = min(kCCBlockSizeAES128, plaintext.count - offset)
            ciphertext += xor(Array(plaintext[offset..<offset + count]), Array(stream.prefix(count)))
            offset += count
            counter += 1
        }

        return AesCcmResult(ciphertext: ciphertext, mic: mic)
    }

    static func aesCcmDecrypt(
        key: [UInt8],
        nonce: [UInt8],
        ciphertext: [UInt8],
        mic: [UInt8],
        aad: [UInt8] = []
    ) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else {
            throw NativeMeshCryptoError.invalidLength("CCM key must be 16 bytes")
        }
        guard (7...13).contains(nonce.count) else {
            throw NativeMeshCryptoError.invalidLength("CCM nonce must be 7 to 13 bytes")
        }
        guard (4...16).contains(mic.count) && mic.count % 2 == 0 else {
            throw NativeMeshCryptoError.invalidLength("CCM MIC length must be even and 4 to 16 bytes")
        }

        let lengthFieldSize = 15 - nonce.count
        var plaintext: [UInt8] = []
        plaintext.reserveCapacity(ciphertext.count)
        var counter = 1
        var offset = 0
        while offset < ciphertext.count {
            let stream = try aes128EncryptBlock(
                key: key,
                block: ccmCounterBlock(nonce: nonce, lengthFieldSize: lengthFieldSize, counter: counter)
            )
            let count = min(kCCBlockSizeAES128, ciphertext.count - offset)
            plaintext += xor(Array(ciphertext[offset..<offset + count]), Array(stream.prefix(count)))
            offset += count
            counter += 1
        }

        let verification = try aesCcmEncrypt(
            key: key,
            nonce: nonce,
            plaintext: plaintext,
            aad: aad,
            micLength: mic.count
        )
        guard verification.mic == mic else {
            throw NativeMeshCryptoError.authenticationFailed("CCM MIC mismatch")
        }
        return plaintext
    }

    private static func cmacSubkeys(key: [UInt8]) throws -> ([UInt8], [UInt8]) {
        let encryptedZero = try aes128EncryptBlock(key: key, block: [UInt8](repeating: 0, count: 16))
        let subkey1 = dbl(encryptedZero)
        let subkey2 = dbl(subkey1)
        return (subkey1, subkey2)
    }

    private static func ccmAuthenticationBlocks(
        nonce: [UInt8],
        plaintext: [UInt8],
        aad: [UInt8],
        micLength: Int,
        lengthFieldSize: Int
    ) throws -> [[UInt8]] {
        let flags = (aad.isEmpty ? UInt8(0) : UInt8(0x40))
            | UInt8(((micLength - 2) / 2) << 3)
            | UInt8(lengthFieldSize - 1)
        var data = [flags] + nonce + uintBytes(UInt64(plaintext.count), count: lengthFieldSize)

        if !aad.isEmpty {
            data += try ccmEncodedAad(aad)
            appendZeroPadding(&data)
        }

        if !plaintext.isEmpty {
            data += plaintext
            appendZeroPadding(&data)
        }

        return stride(from: 0, to: data.count, by: kCCBlockSizeAES128).map {
            Array(data[$0..<$0 + kCCBlockSizeAES128])
        }
    }

    private static func ccmEncodedAad(_ aad: [UInt8]) throws -> [UInt8] {
        if aad.count < 0xff00 {
            return uintBytes(UInt64(aad.count), count: 2) + aad
        }
        if aad.count <= UInt32.max {
            return [0xff, 0xfe] + uintBytes(UInt64(aad.count), count: 4) + aad
        }
        throw NativeMeshCryptoError.invalidLength("CCM AAD is too large")
    }

    private static func ccmCounterBlock(nonce: [UInt8], lengthFieldSize: Int, counter: Int) -> [UInt8] {
        [UInt8(lengthFieldSize - 1)] + nonce + uintBytes(UInt64(counter), count: lengthFieldSize)
    }
}
