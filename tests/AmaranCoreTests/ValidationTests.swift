import Testing
@testable import AmaranCore

struct ValidationTests {
    private let netKey = "0123456789abcdef0123456789abcdef"
    private let appKey = "fedcba9876543210fedcba9876543210"
    private let devKey = "11223344556677889900aabbccddeeff"
    private let devUUID = "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7"

    private func makeFixture(node: Int, elementCount: Int? = nil) -> Fixture {
        Fixture(uuid: "f\(node)", macAddress: "AA:BB:CC:DD:EE:FF", name: "n\(node)",
                nodeAddress: node, deviceKey: devKey, deviceUUID: devUUID,
                elementCount: elementCount, updateTime: "t")
    }

    private func makeState(
        schemaVersion: Int = 1,
        netKey: String? = nil,
        fixtures: [Fixture]? = nil,
        runtime: Runtime? = nil
    ) -> State {
        State(
            schemaVersion: schemaVersion,
            syncedAt: "t",
            source: Source(type: "native_provisioning"),
            mesh: Mesh(uuid: "m", netKey: netKey ?? self.netKey, appKey: appKey, updateTime: "t"),
            fixtures: fixtures ?? [makeFixture(node: 6)],
            runtime: runtime ?? Runtime(ivIndex: 0, sourceAddress: 3, telinkSourceAddress: 1,
                                        sequenceNext: 1, updatedAt: "t")
        )
    }

    @Test func acceptsValidState() throws {
        try Validation.validate(makeState())
    }

    @Test func rejectsWrongSchemaVersion() {
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(schemaVersion: 2)) }
    }

    @Test func rejectsBadNetKeyLength() {
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(netKey: "abcd")) }
    }

    @Test func rejectsEmptyFixtures() {
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(fixtures: [])) }
    }

    @Test func rejectsOutOfRangeNodeAddress() {
        #expect(throws: ValidationError.self) {
            try Validation.validate(makeState(fixtures: [makeFixture(node: 0)]))
        }
        #expect(throws: ValidationError.self) {
            try Validation.validate(makeState(fixtures: [makeFixture(node: 0x8000)]))
        }
    }

    @Test func rejectsDuplicateElementAddresses() {
        let dup = [makeFixture(node: 6), makeFixture(node: 6)]
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(fixtures: dup)) }
    }

    @Test func rejectsMultiElementCollision() {
        // node 5 occupies 5 and 6; node 6 then collides.
        let fixtures = [makeFixture(node: 5, elementCount: 2), makeFixture(node: 6)]
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(fixtures: fixtures)) }
    }

    @Test func acceptsAdjacentMultiElementFixtures() throws {
        // node 5 occupies 5,6; node 7 is clear.
        let fixtures = [makeFixture(node: 5, elementCount: 2), makeFixture(node: 7)]
        try Validation.validate(makeState(fixtures: fixtures))
    }

    @Test func rejectsBadRuntimeCounters() {
        let badSeq = Runtime(ivIndex: 0, sourceAddress: 3, telinkSourceAddress: 1,
                             sequenceNext: 0x00ff_ffff, updatedAt: "t")
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(runtime: badSeq)) }

        let badSource = Runtime(ivIndex: 0, sourceAddress: 0, telinkSourceAddress: 1,
                                sequenceNext: 1, updatedAt: "t")
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(runtime: badSource)) }
    }

    @Test func rejectsInvalidMacAddress() {
        let bad = Fixture(uuid: "f", macAddress: "zz:zz", name: "n", nodeAddress: 6,
                          deviceKey: devKey, deviceUUID: devUUID, updateTime: "t")
        #expect(throws: ValidationError.self) { try Validation.validate(makeState(fixtures: [bad])) }
    }
}
