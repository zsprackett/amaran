import Testing
@testable import AmaranCore

struct HexTests {
    @Test func encodeProducesLowercase() {
        #expect(Hex.encode([0x00, 0x0a, 0xff, 0x10]) == "000aff10")
        #expect(Hex.encode([]) == "")
    }

    @Test func decodeParsesPairs() throws {
        #expect(try Hex.decode("000aff10") == [0x00, 0x0a, 0xff, 0x10])
        #expect(try Hex.decode("") == [])
    }

    @Test func decodeStripsSeparatorsAndWhitespace() throws {
        #expect(try Hex.decode("00:0a-ff 10") == [0x00, 0x0a, 0xff, 0x10])
        #expect(try Hex.decode("AA:BB:CC:DD:EE:FF") == [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    }

    @Test func decodeRejectsOddLength() {
        #expect(throws: HexError.self) { try Hex.decode("abc") }
    }

    @Test func decodeRejectsNonHex() {
        #expect(throws: HexError.self) { try Hex.decode("zz") }
    }

    @Test func roundTrips() throws {
        let bytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]
        #expect(try Hex.decode(Hex.encode(bytes)) == bytes)
    }
}
