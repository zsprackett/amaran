import Testing
@testable import AmaranHelperKit

/// Pure bit-packing and protocol math for the Telink 0x26 vendor control
/// packets. These drive the physical fixture, so encode/decode correctness is
/// asserted with exact vectors and build-then-decode round trips.
struct TelinkControlTests {
    // MARK: percent / kelvin scaling

    @Test func percentScalesToTenths() throws {
        #expect(try NativeTelinkControl.percentToTelinkIntensity("0") == 0)
        #expect(try NativeTelinkControl.percentToTelinkIntensity("100") == 1000)
        #expect(try NativeTelinkControl.percentToTelinkIntensity("50") == 500)
        #expect(try NativeTelinkControl.percentToTelinkIntensity("12.5") == 125)
    }

    @Test func percentRejectsOutOfRangeAndJunk() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.percentToTelinkIntensity("-1")
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.percentToTelinkIntensity("101")
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.percentToTelinkIntensity("abc")
        }
    }

    @Test func kelvinScalesToTenths() throws {
        #expect(try NativeTelinkControl.kelvinToTelinkCCT("2700") == 270)
        #expect(try NativeTelinkControl.kelvinToTelinkCCT("800") == 80)
        #expect(try NativeTelinkControl.kelvinToTelinkCCT("20000") == 2000)
    }

    @Test func kelvinRejectsOutOfRangeAndJunk() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.kelvinToTelinkCCT("799")
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.kelvinToTelinkCCT("20001")
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.kelvinToTelinkCCT("warm")
        }
    }

    // MARK: on / off / status packets

    @Test func onOffPacketsAreTenBytesWithValidChecksum() {
        for turnOn in [true, false] {
            let packet = NativeTelinkControl.onOffPacket(turnOn: turnOn)
            #expect(packet.count == 10)
            let decoded = NativeTelinkControl.decodePacket(packet)
            #expect(decoded?["checksum_valid"] as? Bool == true)
        }
    }

    @Test func onAndOffDifferInTheLowCommandByte() {
        let onPacket = NativeTelinkControl.onOffPacket(turnOn: true)
        let offPacket = NativeTelinkControl.onOffPacket(turnOn: false)
        #expect(onPacket != offPacket)
        // high16 = 0x8c00 | (turnOn ? 1 : 0), written little-endian at byte 8.
        #expect(onPacket[8] == 0x01)
        #expect(offPacket[8] == 0x00)
    }

    @Test func statusRequestPacketIsValid() {
        let packet = NativeTelinkControl.statusRequestPacket()
        #expect(packet.count == 10)
        #expect(NativeTelinkControl.decodePacket(packet)?["checksum_valid"] as? Bool == true)
    }

    // MARK: brightness

    @Test func brightnessPacketRoundTripsChecksum() throws {
        let packet = try NativeTelinkControl.brightnessPacket(telinkIntensity: 500)
        #expect(packet.count == 10)
        #expect(NativeTelinkControl.decodePacket(packet)?["checksum_valid"] as? Bool == true)
    }

    @Test func brightnessPacketRejectsOverflow() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.brightnessPacket(telinkIntensity: 1001)
        }
    }

    // MARK: cct encode/decode round trips

    @Test func cctPacketRoundTripsLowBranch() throws {
        // telinkCct < 1001 path.
        let packet = try NativeTelinkControl.cctPacket(
            telinkCct: 270, telinkIntensity: 500, gm: 0, gmFlag: 0
        )
        let decoded = try #require(NativeTelinkControl.decodePacket(packet))
        #expect(decoded["checksum_valid"] as? Bool == true)
        let cct = try #require(decoded["cct"] as? [String: Any])
        #expect(cct["cct_decoded"] as? Int == 270)
        #expect(cct["intensity"] as? Int == 500)
        #expect(cct["gm_flag"] as? Int == 0)
    }

    @Test func cctPacketRoundTripsHighBranch() throws {
        // telinkCct >= 1001 path encodes an offset plus the cct_flag bit.
        let packet = try NativeTelinkControl.cctPacket(
            telinkCct: 1500, telinkIntensity: 250, gm: 0, gmFlag: 0
        )
        let decoded = try #require(NativeTelinkControl.decodePacket(packet))
        let cct = try #require(decoded["cct"] as? [String: Any])
        #expect(cct["cct_decoded"] as? Int == 1500)
        #expect(cct["intensity"] as? Int == 250)
    }

    @Test func cctPacketRoundTripsGreenMagenta() throws {
        let packet = try NativeTelinkControl.cctPacket(
            telinkCct: 400, telinkIntensity: 100, gm: 40, gmFlag: 1
        )
        let decoded = try #require(NativeTelinkControl.decodePacket(packet))
        let cct = try #require(decoded["cct"] as? [String: Any])
        #expect(cct["gm_flag"] as? Int == 1)
        #expect(cct["gm_decoded"] as? Int == 40)
    }

    @Test func cctPacketRejectsOutOfRangeInputs() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.cctPacket(telinkCct: 79, telinkIntensity: 0, gm: 0, gmFlag: 0)
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.cctPacket(telinkCct: 2001, telinkIntensity: 0, gm: 0, gmFlag: 0)
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.cctPacket(telinkCct: 270, telinkIntensity: 1001, gm: 0, gmFlag: 0)
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.cctPacket(telinkCct: 270, telinkIntensity: 0, gm: 0, gmFlag: 2)
        }
        // gm out of range for the chosen flag.
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.cctPacket(telinkCct: 270, telinkIntensity: 0, gm: 200, gmFlag: 0)
        }
    }

    // MARK: decodePacket guards

    @Test func decodePacketRejectsWrongLength() {
        #expect(NativeTelinkControl.decodePacket(Array(repeating: 0, count: 9)) == nil)
        #expect(NativeTelinkControl.decodePacket([]) == nil)
    }

    @Test func decodePacketFlagsBadChecksum() {
        var packet = NativeTelinkControl.onOffPacket(turnOn: true)
        packet[0] = packet[0] &+ 1 // corrupt the checksum byte
        #expect(NativeTelinkControl.decodePacket(packet)?["checksum_valid"] as? Bool == false)
    }

    // MARK: rawPacket validation

    @Test func rawPacketAcceptsAWellFormedPacket() throws {
        let valid = NativeTelinkControl.onOffPacket(turnOn: true)
        let parsed = try NativeTelinkControl.rawPacket(hex: NativeMeshCrypto.hex(valid))
        #expect(parsed == valid)
    }

    @Test func rawPacketRejectsWrongLength() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.rawPacket(hex: "deadbeef")
        }
    }

    @Test func rawPacketRejectsBadChecksum() {
        var packet = NativeTelinkControl.onOffPacket(turnOn: true)
        packet[5] = packet[5] &+ 1 // corrupt a payload byte, leaving the checksum stale
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControl.rawPacket(hex: NativeMeshCrypto.hex(packet))
        }
    }

    // MARK: command spec parsing

    @Test func parseToggleCommands() throws {
        #expect(try NativeTelinkControlCommand.parse(spec: "on").isOnOff(true))
        #expect(try NativeTelinkControlCommand.parse(spec: "off").isOnOff(false))
    }

    @Test func parseToggleRejectsExtraFields() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControlCommand.parse(spec: "on:1")
        }
    }

    @Test func parseIntensityCommand() throws {
        let command = try NativeTelinkControlCommand.parse(spec: "intensity:50")
        guard case .brightness(let percent) = command else {
            Issue.record("expected brightness command")
            return
        }
        #expect(percent == "50")
    }

    @Test func parseIntensityRejectsWrongArity() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControlCommand.parse(spec: "intensity")
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControlCommand.parse(spec: "intensity:50:60")
        }
    }

    @Test func parseCctCommand() throws {
        let command = try NativeTelinkControlCommand.parse(spec: "cct:2700:80:0:0")
        guard case .cct(let kelvin, let intensity, let greenMagenta, let gmFlag) = command else {
            Issue.record("expected cct command")
            return
        }
        #expect(kelvin == "2700")
        #expect(intensity == "80")
        #expect(greenMagenta == 0)
        #expect(gmFlag == 0)
    }

    @Test func parseCctRejectsBadShape() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControlCommand.parse(spec: "cct:2700")
        }
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControlCommand.parse(spec: "cct:2700:80:x:0")
        }
    }

    @Test func parseRawCommand() throws {
        let valid = NativeMeshCrypto.hex(NativeTelinkControl.onOffPacket(turnOn: true))
        let command = try NativeTelinkControlCommand.parse(spec: "raw:\(valid)")
        guard case .raw(let packetHex, _) = command else {
            Issue.record("expected raw command")
            return
        }
        #expect(packetHex == valid)
    }

    @Test func parseStatusCommand() throws {
        #expect(try NativeTelinkControlCommand.parse(spec: "status").isStatus)
    }

    @Test func parseRejectsUnknownCommand() {
        #expect(throws: NativeTelinkControlError.self) {
            _ = try NativeTelinkControlCommand.parse(spec: "bogus")
        }
    }

    // MARK: access message framing

    @Test func accessMessagePrependsVendorOpcode() throws {
        let status = try NativeTelinkControlCommand.parse(spec: "status").accessMessage()
        #expect(status.first == NativeTelinkControl.accessOpcode)
        let onMessage = try NativeTelinkControlCommand.parse(spec: "on").accessMessage()
        #expect(onMessage.first == NativeTelinkControl.accessOpcode)
        #expect(onMessage.count == 11)
    }

    @Test func onOffMetadataReportsCommand() throws {
        let onMeta = try NativeTelinkControlCommand.parse(spec: "on").metadata()
        #expect(onMeta["control_command"] as? String == "on")
        let offMeta = try NativeTelinkControlCommand.parse(spec: "off").metadata()
        #expect(offMeta["control_command"] as? String == "off")
    }
}

private extension NativeTelinkControlCommand {
    func isOnOff(_ expected: Bool) -> Bool {
        if case .onOff(let value) = self { return value == expected }
        return false
    }

    var isStatus: Bool {
        if case .status = self { return true }
        return false
    }
}
