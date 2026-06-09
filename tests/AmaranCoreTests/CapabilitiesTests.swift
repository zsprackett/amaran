import Testing
@testable import AmaranCore

struct CapabilitiesTests {
    private func fixture(
        node: Int = 6,
        code: String = "",
        name: String = "",
        mac: String = "",
        friendly: String? = nil,
        capabilities: FixtureCapabilities? = nil
    ) -> Fixture {
        Fixture(uuid: "f", macAddress: mac, code: code, name: name, nodeAddress: node,
                updateTime: "t", friendlyName: friendly, capabilities: capabilities)
    }

    @Test func defaultCapabilities() {
        let caps = Capabilities.resolve(fixture())
        #expect(caps.cctMin == 2000)
        #expect(caps.cctMax == 10000)
        #expect(caps.gmSupported == true)
    }

    @Test func detects400M5ByCode() {
        let caps = Capabilities.resolve(fixture(code: "400M5"))
        #expect(caps.cctMin == 2700)
        #expect(caps.cctMax == 6500)
        #expect(caps.gmSupported == false)
    }

    @Test func detects400M5ByName() {
        let caps = Capabilities.resolve(fixture(name: "400M5-DDEEFF"))
        #expect(caps.cctMin == 2700)
        #expect(caps.cctMax == 6500)
    }

    @Test func explicitCapabilitiesOverride() {
        let caps = Capabilities.resolve(
            fixture(capabilities: FixtureCapabilities(cctMin: 3000, cctMax: 5600, gmSupported: false)))
        #expect(caps.cctMin == 3000)
        #expect(caps.cctMax == 5600)
        #expect(caps.gmSupported == false)
    }

    @Test func swapsInvertedRange() {
        let caps = Capabilities.resolve(
            fixture(capabilities: FixtureCapabilities(cctMin: 6000, cctMax: 3000)))
        #expect(caps.cctMin == 3000)
        #expect(caps.cctMax == 6000)
    }

    @Test func clampsCctToRange() {
        #expect(Capabilities.clampCct(1500, for: fixture()) == 2000)
        #expect(Capabilities.clampCct(12000, for: fixture()) == 10000)
        #expect(Capabilities.clampCct(3200, for: fixture()) == 3200)
    }

    @Test func normalizesSmallKelvinValues() {
        // values below 1000 are treated as deci-kelvin and multiplied by 10
        #expect(Capabilities.clampCct(320, for: fixture()) == 3200)
    }

    @Test func labelPrecedence() {
        #expect(Capabilities.label(fixture(friendly: "key")) == "key")
        #expect(Capabilities.label(fixture(name: "named")) == "named")
        #expect(Capabilities.label(fixture(code: "400M5", mac: "AABBCCDDEEFF")) == "400M5-DDEEFF")
        #expect(Capabilities.label(fixture(mac: "AABBCCDDEEFF")) == "DDEEFF")
        #expect(Capabilities.label(fixture(node: 9)) == "fixture-9")
    }

    @Test func selectorValuesIncludeAddressForms() {
        let values = Capabilities.selectorValues(fixture(node: 6, name: "named", friendly: "key"))
        #expect(values.contains("6"))
        #expect(values.contains("0x6"))
        #expect(values.contains("named"))
        #expect(values.contains("key"))
    }

    @Test func selectsByExplicitSelector() {
        let fixtures = [fixture(node: 6, name: "a"), fixture(node: 7, name: "b")]
        #expect(Capabilities.selectedFixture(fixtures, selector: "7")?.nodeAddress == 7)
        #expect(Capabilities.selectedFixture(fixtures, selector: "0x7")?.nodeAddress == 7)
        #expect(Capabilities.selectedFixture(fixtures, selector: "b")?.nodeAddress == 7)
        #expect(Capabilities.selectedFixture(fixtures, selector: "missing") == nil)
    }

    @Test func selectsSingleWhenNoSelector() {
        #expect(Capabilities.selectedFixture([fixture(node: 6)], selector: nil)?.nodeAddress == 6)
        let two = [fixture(node: 6), fixture(node: 7)]
        #expect(Capabilities.selectedFixture(two, selector: nil) == nil)
    }
}
