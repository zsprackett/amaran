import Foundation
import CommonCrypto
import Testing
@testable import AmaranCLI

struct IosBackupDecryptTests {
    private func hex(_ hexString: String) -> Data {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            data.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    // RFC 6070: PBKDF2-HMAC-SHA1, password="password", salt="salt", c=1, dkLen=20.
    @Test func pbkdf2Sha1MatchesRFC6070() {
        let derived = BackupCrypto.pbkdf2(
            password: Data("password".utf8), salt: Data("salt".utf8), rounds: 1,
            prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), keyLength: 20)
        #expect(derived == hex("0c60c80f961f0e71f3a9b524af6012062fe037a6"))
    }

    @Test func pbkdf2Sha1MatchesRFC6070TwoIterations() {
        let derived = BackupCrypto.pbkdf2(
            password: Data("password".utf8), salt: Data("salt".utf8), rounds: 2,
            prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), keyLength: 20)
        #expect(derived == hex("ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"))
    }

    // RFC 3394 4.1: 128-bit KEK, 128-bit key data.
    @Test func aesKeyUnwrapMatchesRFC3394() {
        let kek = hex("000102030405060708090a0b0c0d0e0f")
        let wrapped = hex("1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5")
        let unwrapped = BackupCrypto.aesUnwrap(kek: kek, wrapped: wrapped)
        #expect(unwrapped == hex("00112233445566778899aabbccddeeff"))
    }

    @Test func aesKeyUnwrapRejectsTamperedData() {
        let kek = hex("000102030405060708090a0b0c0d0e0f")
        let bad = hex("1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe6")  // last byte flipped
        #expect(BackupCrypto.aesUnwrap(kek: kek, wrapped: bad) == nil)
    }

    // AES-CBC zero-IV round trip (no padding).
    @Test func aesCBCDecryptRoundTrip() throws {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let plaintext = Data("sixteen byte blk".utf8)  // exactly 16 bytes
        // Encrypt with CommonCrypto (mirror of decrypt) to produce ciphertext.
        let capacity = plaintext.count + 16
        var cipher = Data(count: capacity)
        var moved = 0
        let ivData = Data(count: 16)
        _ = cipher.withUnsafeMutableBytes { cipherPtr in plaintext.withUnsafeBytes { plainPtr in
            key.withUnsafeBytes { keyPtr in ivData.withUnsafeBytes { ivPtr in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                    keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                    plainPtr.baseAddress, plaintext.count, cipherPtr.baseAddress, capacity, &moved)
        }}}}
        let decrypted = BackupCrypto.aesCBCDecrypt(key: key, data: cipher.prefix(moved))
        #expect(decrypted.prefix(plaintext.count) == plaintext)
    }

    @Test func littleEndianClassParse() {
        #expect(IosBackupDecrypt.littleEndianUInt32(Data([0x04, 0x00, 0x00, 0x00])) == 4)
        #expect(IosBackupDecrypt.bigEndianInt(Data([0x00, 0x00, 0x04, 0x00])) == 0x0400)
    }
}
