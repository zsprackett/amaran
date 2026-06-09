import Testing
@testable import AmaranHelperKit

/// Unicast-address selection and fixture-label logic. These operate purely on
/// in-memory state dictionaries (no disk), so a wrong allocation that would
/// collide on real hardware is caught deterministically here.
struct FixtureAddressingTests {
    private func fixture(
        node: Int,
        elementCount: Int? = nil,
        name: String? = nil,
        friendly: String? = nil,
        mac: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = ["node_address": node]
        if let elementCount { dict["element_count"] = elementCount }
        if let name { dict["name"] = name }
        if let friendly { dict["friendly_name"] = friendly }
        if let mac { dict["mac_address"] = mac }
        return dict
    }

    // MARK: parseUnicastAddressList

    @Test func parsesAndPreservesOrder() throws {
        #expect(try parseUnicastAddressList("1,2,3") == [1, 2, 3])
    }

    @Test func dedupesKeepingFirstOccurrence() throws {
        #expect(try parseUnicastAddressList("3,1,2,1") == [3, 1, 2])
    }

    @Test func trimsWhitespace() throws {
        #expect(try parseUnicastAddressList(" 1 , 2 ") == [1, 2])
    }

    @Test func rejectsEmptyAndOutOfRange() {
        #expect(throws: Error.self) { _ = try parseUnicastAddressList("") }
        #expect(throws: Error.self) { _ = try parseUnicastAddressList("0") }
        #expect(throws: Error.self) { _ = try parseUnicastAddressList("32768") }
        #expect(throws: Error.self) { _ = try parseUnicastAddressList("x") }
    }

    // MARK: occupiedFixtureAddresses

    @Test func occupiedSpansElementCount() {
        let occupied = occupiedFixtureAddresses([fixture(node: 5, elementCount: 3)])
        #expect(occupied == Set([5, 6, 7]))
    }

    @Test func occupiedDefaultsToSingleElement() {
        let occupied = occupiedFixtureAddresses([fixture(node: 9)])
        #expect(occupied == Set([9]))
    }

    @Test func occupiedSkipsInvalidAddresses() {
        let occupied = occupiedFixtureAddresses([fixture(node: 0), fixture(node: 0x8000), fixture(node: 4)])
        #expect(occupied == Set([4]))
    }

    // MARK: provisioning reservations

    @Test func reservesSixteenBlockWhenExtentUnknown() {
        let reserved = provisioningReservedFixtureAddresses([fixture(node: 10)])
        #expect(reserved == Set(10...25))
    }

    @Test func reservesOnlyOccupiedWhenExtentKnown() {
        let reserved = provisioningReservedFixtureAddresses([fixture(node: 10, elementCount: 2)])
        #expect(reserved == Set([10, 11]))
    }

    @Test func nextProvisioningAddressStartsAtTwo() throws {
        #expect(try nextProvisioningUnicastAddress(fixtures: [], runtime: [:]) == 2)
    }

    @Test func nextProvisioningAddressSkipsRuntimeSources() throws {
        let next = try nextProvisioningUnicastAddress(
            fixtures: [], runtime: ["source_address": 2]
        )
        #expect(next == 3)
    }

    // MARK: CLI-owned source address

    @Test func runtimeSourceDefaultsToThree() throws {
        #expect(try nativeRuntimeSourceAddress(runtime: [:], fixtures: [], destination: 5) == 3)
    }

    @Test func runtimeSourceAvoidsDestination() throws {
        #expect(try nativeRuntimeSourceAddress(runtime: [:], fixtures: [], destination: 3) == 4)
    }

    @Test func runtimeSourceHonorsValidExisting() throws {
        let source = try nativeRuntimeSourceAddress(
            runtime: ["source_address": 7], fixtures: [], destination: 5
        )
        #expect(source == 7)
    }

    @Test func runtimeSourceRejectsInvalidExisting() {
        #expect(throws: Error.self) {
            _ = try nativeRuntimeSourceAddress(
                runtime: ["source_address": 0x8000], fixtures: [], destination: 5
            )
        }
    }

    // MARK: Telink runtime source address

    @Test func telinkSourcePrefersOne() throws {
        #expect(try nativeTelinkSourceAddress(runtime: [:], fixtures: [], destination: 5) == 1)
    }

    @Test func telinkSourceFallsBackWhenDestinationIsOne() throws {
        // Cannot use 1 (it is the destination); falls back to CLI-owned logic.
        #expect(try nativeTelinkSourceAddress(runtime: [:], fixtures: [], destination: 1) == 3)
    }

    @Test func telinkSourceAvoidingSetPrefersOne() throws {
        #expect(try nativeTelinkSourceAddress(runtime: [:], fixtures: [], avoiding: [5, 6]) == 1)
    }

    @Test func telinkSourceAvoidingSetSkipsBlocked() throws {
        let source = try nativeTelinkSourceAddress(
            runtime: [:], fixtures: [fixture(node: 1)], avoiding: [5]
        )
        #expect(source == 3)
    }

    // MARK: labels and selection

    @Test func labelPrefersFriendlyName() {
        #expect(fixtureLabel(fixture(node: 5, name: "raw", friendly: "Key Light")) == "Key Light")
    }

    @Test func labelFallsBackToNameThenAddress() {
        #expect(fixtureLabel(fixture(node: 5, name: "raw")) == "raw")
        #expect(fixtureLabel(fixture(node: 5)) == "fixture-5")
    }

    @Test func macSuffixTakesLastSixHexUppercased() {
        #expect(fixtureMacSuffix(fixture(node: 5, mac: "aa:bb:cc:dd:ee:ff")) == "DDEEFF")
    }

    @Test func macSuffixIsNilWhenMissing() {
        #expect(fixtureMacSuffix(fixture(node: 5)) == nil)
    }

    @Test func selectFixtureMatchesByNodeAddress() throws {
        let fixtures = [fixture(node: 5), fixture(node: 6)]
        let chosen = try selectFixture(fixtures, nodeID: "6")
        #expect(jsonInt(chosen["node_address"]) == 6)
    }

    @Test func selectFixtureReturnsLoneFixtureWithoutNodeID() throws {
        let chosen = try selectFixture([fixture(node: 5)], nodeID: nil)
        #expect(jsonInt(chosen["node_address"]) == 5)
    }

    @Test func selectFixtureRejectsAmbiguityAndMisses() {
        let fixtures = [fixture(node: 5), fixture(node: 6)]
        #expect(throws: Error.self) { _ = try selectFixture(fixtures, nodeID: nil) }
        #expect(throws: Error.self) { _ = try selectFixture(fixtures, nodeID: "99") }
    }
}
