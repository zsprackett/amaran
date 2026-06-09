import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

struct ControlSpecBuilderTests {
    private func fixture(code: String = "", name: String = "n") -> Fixture {
        Fixture(uuid: "f", code: code, name: name, nodeAddress: 3, updateTime: "t")
    }
    private let m5 = "400M5"

    private func current(intensityTenths: Double? = nil, cct: Int? = nil, gm: Int? = nil, gmFlag: Int? = nil)
        -> StatusReport.CurrentValues {
        StatusReport.CurrentValues(intensityTenths: intensityTenths, cctKelvin: cct, gm: gm, gmFlag: gmFlag)
    }

    // MARK: cct

    @Test func cctWithExplicitIntensityAndGmNeedsNoStatus() throws {
        #expect(ControlSpecBuilder.cctNeedsStatus(intensityPercent: 50, gm: 5, fixture: fixture()) == false)
        let result = try ControlSpecBuilder.cctSpec(
            requestedKelvin: 4000, intensityPercent: 50, gm: 5, fixture: fixture(), current: nil)
        #expect(result.spec == "cct:4000:50:5:0")
        #expect(result.clampWarning == nil)
    }

    @Test func cctClampsToFixtureRangeWithWarning() throws {
        // 400M5 range is 2700..6500
        let result = try ControlSpecBuilder.cctSpec(
            requestedKelvin: 8000, intensityPercent: 50, gm: nil,
            fixture: fixture(code: m5), current: nil)
        #expect(result.spec.hasPrefix("cct:6500:50:"))
        #expect(result.clampWarning?.contains("8000K clamped to 6500K") == true)
    }

    @Test func cctNeedsStatusWhenIntensityOmitted() throws {
        #expect(ControlSpecBuilder.cctNeedsStatus(intensityPercent: nil, gm: 5, fixture: fixture()) == true)
        let result = try ControlSpecBuilder.cctSpec(
            requestedKelvin: 4000, intensityPercent: nil, gm: 5, fixture: fixture(),
            current: current(intensityTenths: 400))
        #expect(result.spec == "cct:4000:40:5:0")
    }

    @Test func cctPullsGmFromStatusWhenSupported() throws {
        let result = try ControlSpecBuilder.cctSpec(
            requestedKelvin: 4000, intensityPercent: 50, gm: nil, fixture: fixture(),
            current: current(intensityTenths: 400, gm: 7, gmFlag: 1))
        #expect(result.spec == "cct:4000:50:7:1")
    }

    @Test func cctDefaultsGmToTenWhenUnsupported() throws {
        // 400M5 does not support gm; no status needed for gm
        let result = try ControlSpecBuilder.cctSpec(
            requestedKelvin: 4000, intensityPercent: 50, gm: nil,
            fixture: fixture(code: m5), current: nil)
        #expect(result.spec == "cct:4000:50:10:0")
    }

    @Test func cctRejectsGmOnUnsupportedFixture() {
        #expect(throws: CLIError.self) {
            _ = try ControlSpecBuilder.cctSpec(
                requestedKelvin: 4000, intensityPercent: 50, gm: 5,
                fixture: fixture(code: m5), current: nil)
        }
    }

    @Test func cctThrowsWhenStatusHasNoIntensity() {
        #expect(throws: CLIError.self) {
            _ = try ControlSpecBuilder.cctSpec(
                requestedKelvin: 4000, intensityPercent: nil, gm: 5, fixture: fixture(),
                current: current(intensityTenths: nil))
        }
    }

    // MARK: gm

    @Test func gmSpecPreservesCctAndIntensity() throws {
        let spec = try ControlSpecBuilder.gmSpec(
            gm: 6, fixture: fixture(), current: current(intensityTenths: 400, cct: 5600))
        #expect(spec == "cct:5600:40:6:0")
    }

    @Test func gmSpecRejectsUnsupportedFixture() {
        #expect(throws: CLIError.self) {
            _ = try ControlSpecBuilder.gmSpec(
                gm: 6, fixture: fixture(code: m5), current: current(intensityTenths: 400, cct: 5600))
        }
    }

    @Test func gmSpecThrowsWithoutStatusCct() {
        #expect(throws: CLIError.self) {
            _ = try ControlSpecBuilder.gmSpec(
                gm: 6, fixture: fixture(), current: current(intensityTenths: 400, cct: nil))
        }
    }
}
