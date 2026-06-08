import Testing
@testable import AmaranCore

struct MacAddressTests {
    @Test func normalizeUppercasesAndColonJoins() throws {
        #expect(try MacAddress.normalize("aabbccddeeff") == "AA:BB:CC:DD:EE:FF")
        #expect(try MacAddress.normalize("aa:bb:cc:dd:ee:ff") == "AA:BB:CC:DD:EE:FF")
        #expect(try MacAddress.normalize("AA-BB-CC-DD-EE-FF") == "AA:BB:CC:DD:EE:FF")
    }

    @Test func normalizeRejectsWrongLength() {
        #expect(throws: MacAddressError.self) { try MacAddress.normalize("aabb") }
    }

    @Test func normalizeRejectsNonHex() {
        #expect(throws: MacAddressError.self) { try MacAddress.normalize("zzbbccddeeff") }
    }

    @Test func normalizeOptionalReturnsNilForEmpty() throws {
        #expect(try MacAddress.normalizeOptional(nil) == nil)
        #expect(try MacAddress.normalizeOptional("") == nil)
        #expect(try MacAddress.normalizeOptional("aabbccddeeff") == "AA:BB:CC:DD:EE:FF")
    }

    @Test func suffixReturnsLastSixHexUppercased() {
        #expect(MacAddress.suffix("aabbccddeeff") == "DDEEFF")
        #expect(MacAddress.suffix("aa:bb:cc:dd:ee:ff") == "DDEEFF")
        #expect(MacAddress.suffix("") == "")
        #expect(MacAddress.suffix(nil) == "")
    }
}
