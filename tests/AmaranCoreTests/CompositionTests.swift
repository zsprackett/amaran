import Testing
@testable import AmaranCore

struct CompositionTests {
    // 10-byte page-0 header (cid/pid/vid/crpl/features), all zero.
    private let header: [UInt8] = Array(repeating: 0, count: 10)

    // One element: location(2)=0, sigCount=1, vendorCount=0, one sig model(2)=0.
    private let oneElement: [UInt8] = [0, 0, 1, 0, 0, 0]

    // One element: location(2)=0, sigCount=0, vendorCount=1, one vendor model(4)=0.
    private let vendorElement: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0]

    @Test func countsSingleElement() throws {
        #expect(try Composition.page0ElementCount(header + oneElement) == 1)
    }

    @Test func countsMultipleElements() throws {
        #expect(try Composition.page0ElementCount(header + oneElement + vendorElement) == 2)
    }

    @Test func rejectsTruncatedHeader() {
        #expect(throws: CompositionError.self) {
            try Composition.page0ElementCount(Array(repeating: 0, count: 9))
        }
    }

    @Test func rejectsTruncatedModelList() {
        // sigCount=2 but no model bytes follow.
        #expect(throws: CompositionError.self) {
            try Composition.page0ElementCount(header + [0, 0, 2, 0])
        }
    }

    @Test func rejectsNoElements() {
        #expect(throws: CompositionError.self) {
            try Composition.page0ElementCount(header)
        }
    }

    // Higher-level fixture element-count derivation (mirrors fixtureElementCount).
    @Test func derivedFromComposition() throws {
        let hex = Hex.encode(header + oneElement + vendorElement)
        #expect(try Composition.derivedElementCount(compositionHex: hex, declaredElementCount: nil) == 2)
    }

    @Test func derivedFromDeclaredCount() throws {
        #expect(try Composition.derivedElementCount(compositionHex: nil, declaredElementCount: 4) == 4)
        #expect(try Composition.derivedElementCount(compositionHex: "", declaredElementCount: 4) == 4)
    }

    @Test func derivedDefaultsToOne() throws {
        #expect(try Composition.derivedElementCount(compositionHex: nil, declaredElementCount: nil) == 1)
    }

    @Test func derivedRejectsOutOfRangeDeclaredCount() {
        #expect(throws: CompositionError.self) {
            try Composition.derivedElementCount(compositionHex: nil, declaredElementCount: 0)
        }
        #expect(throws: CompositionError.self) {
            try Composition.derivedElementCount(compositionHex: nil, declaredElementCount: 256)
        }
    }
}
