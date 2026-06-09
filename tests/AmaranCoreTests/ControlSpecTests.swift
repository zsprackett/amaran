import Testing
@testable import AmaranCore

struct ControlSpecTests {
    @Test func parsesSimpleCommands() throws {
        #expect(try ControlSpec.parse("on") == .on)
        #expect(try ControlSpec.parse("off") == .off)
        #expect(try ControlSpec.parse("status") == .status)
    }

    @Test func simpleCommandsRejectExtraParts() {
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("on:1") }
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("off:x") }
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("status:1") }
    }

    @Test func parsesIntensity() throws {
        #expect(try ControlSpec.parse("intensity:50") == .intensity(percent: "50"))
    }

    @Test func intensityRequiresExactlyOneValue() {
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("intensity") }
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("intensity:50:60") }
    }

    @Test func parsesCct() throws {
        #expect(try ControlSpec.parse("cct:3200:50:10:1")
            == .cct(kelvin: "3200", intensity: "50", gm: 10, gmFlag: 1))
    }

    @Test func cctRequiresIntegerGmFields() {
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("cct:3200:50:x:1") }
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("cct:3200:50:10:y") }
    }

    @Test func cctRequiresFiveParts() {
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("cct:3200:50:10") }
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("cct:3200:50:10:1:0") }
    }

    @Test func parsesRaw() throws {
        #expect(try ControlSpec.parse("raw:aabbccddeeff00112233")
            == .raw(hex: "aabbccddeeff00112233"))
    }

    @Test func rawRequiresValue() {
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("raw") }
    }

    @Test func rejectsUnknownCommand() {
        #expect(throws: ControlSpecError.self) { try ControlSpec.parse("bogus") }
    }

    @Test func serializesBackToSpecString() throws {
        let specs = ["on", "off", "status", "intensity:50", "cct:3200:50:10:1", "raw:aabbccdd"]
        for spec in specs {
            #expect(try ControlSpec.parse(spec).serialized == spec)
        }
    }
}
