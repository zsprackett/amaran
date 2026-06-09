import CoreBluetooth
import Foundation

extension ProbeOptions {
    /// Parses the argument at `index`, dispatching to a category handler, and
    /// returns the index to resume parsing from. Unknown flags are skipped.
    func parse(
        arguments: [String],
        at index: Int,
        addToExistingState: Bool,
        joinCapture: inout ProbeOptions.JoinCaptureRequest
    ) -> Int {
        if let next = parseGeneralFlags(arguments: arguments, at: index) {
            return next
        }
        if let next = parseMiscFlags(arguments: arguments, at: index) {
            return next
        }
        if let next = parseProvisioningFlags(
            arguments: arguments,
            at: index,
            addToExistingState: addToExistingState
        ) {
            return next
        }
        if let next = parseJoinCaptureFlags(arguments: arguments, at: index, joinCapture: &joinCapture) {
            return next
        }
        if let next = parseProxyFlags(arguments: arguments, at: index) {
            return next
        }
        if let next = parseConfigFlags(arguments: arguments, at: index) {
            return next
        }
        return index + 1
    }

    private func parseGeneralFlags(arguments: [String], at index: Int) -> Int? {
        switch arguments[index] {
        case "--output":
            return consumeValue(arguments, at: index) { outputPath = $0 }
        case "--advertisement-capture":
            return consumeValue(arguments, at: index, missing: "--advertisement-capture requires a file path") {
                advertisementCapturePath = ($0 as NSString).expandingTildeInPath
            }
        case "--discover-all-services":
            discoverAllServices = true
            return index + 1
        case "--read-characteristics":
            readCharacteristics = true
            return index + 1
        case "--scan-only":
            connect = false
            return index + 1
        case "--provisioning-scan":
            scanServices = [meshProvisioningService]
            connectService = meshProvisioningService
            connect = true
            return index + 1
        case "--node":
            return consumeValue(arguments, at: index) { nodeID = $0 }
        case "--state-path":
            return consumeValue(arguments, at: index) { statePath = ($0 as NSString).expandingTildeInPath }
        case "--confirm-reset", "--add-to-existing-state":
            return index + 1
        default:
            return nil
        }
    }

    private func parseMiscFlags(arguments: [String], at index: Int) -> Int? {
        switch arguments[index] {
        case "--timeout":
            if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                timeout = max(1, value)
                return index + 2
            }
            return index + 1
        case "--settle-after-write":
            if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                settleAfterWrite = max(0.1, value)
                return index + 2
            }
            return index + 1
        case "--expect-segment-ack":
            return parseExpectSegmentAck(arguments: arguments, at: index)
        default:
            return nil
        }
    }

    private func parseExpectSegmentAck(arguments: [String], at index: Int) -> Int {
        if index + 2 < arguments.count,
           let seqZero = Int(arguments[index + 1]),
           let segN = Int(arguments[index + 2]),
           (0...0x1fff).contains(seqZero),
           (0...0x1f).contains(segN) {
            expectedSegmentAckSeqZero = UInt16(seqZero)
            expectedSegmentAckSegN = UInt8(segN)
            return index + 3
        }
        configurationError = "--expect-segment-ack requires SeqZero 0..8191 and SegN 0..31"
        return index + 1
    }

    private func parseProvisioningFlags(
        arguments: [String],
        at index: Int,
        addToExistingState: Bool
    ) -> Int? {
        switch arguments[index] {
        case "--provisioning-invite-test":
            return parseProvisioningInviteTest(arguments: arguments, at: index)
        case "--provision-test":
            return parseProvisionTest(arguments: arguments, at: index, addToExistingState: addToExistingState)
        default:
            return nil
        }
    }

    private func parseProvisioningInviteTest(arguments: [String], at index: Int) -> Int {
        guard index + 1 < arguments.count, let attentionDuration = Int(arguments[index + 1]) else {
            configurationError = "--provisioning-invite-test requires an attention duration from 0 to 255"
            return index + 1
        }
        do {
            proxyPdu = NativeMeshProvisioning.completeProxyPdu(
                provisioningPdu: try NativeMeshProvisioning.provisioningInvite(
                    attentionDuration: attentionDuration
                )
            )
            proxyPduLabel = "provisioning-invite"
            writeDataInUUID = meshProvisioningDataIn
            writeDataOutUUID = meshProvisioningDataOut
            scanServices = [meshProvisioningService]
            connectService = meshProvisioningService
            nativeSendMetadata = [
                "attention_duration": attentionDuration,
                "pdu_type": "provisioning_invite"
            ]
            settleAfterWrite = max(settleAfterWrite, 2.0)
            connect = true
        } catch {
            configurationError = String(describing: error)
        }
        return index + 2
    }

    private func parseProvisionTest(
        arguments: [String],
        at index: Int,
        addToExistingState: Bool
    ) -> Int {
        guard index + 1 < arguments.count, let attentionDuration = Int(arguments[index + 1]) else {
            configurationError = "--provision-test requires an attention duration from 0 to 255"
            return index + 1
        }
        do {
            nativeProvisioningRun = try makeNativeProvisioningRun(
                attentionDuration: attentionDuration,
                statePath: statePath,
                addToExistingState: addToExistingState
            )
            proxyPduLabel = "provision"
            writeDataInUUID = meshProvisioningDataIn
            writeDataOutUUID = meshProvisioningDataOut
            scanServices = [meshProvisioningService]
            connectService = meshProvisioningService
            nativeSendMetadata = [
                "attention_duration": attentionDuration,
                "pdu_type": "provision",
                "state_mode": addToExistingState ? "append" : "create",
                "node_address": Int(nativeProvisioningRun?.unicastAddress ?? 0)
            ]
            connect = true
        } catch {
            configurationError = String(describing: error)
        }
        return index + 2
    }

    private func parseJoinCaptureFlags(
        arguments: [String],
        at index: Int,
        joinCapture: inout ProbeOptions.JoinCaptureRequest
    ) -> Int? {
        switch arguments[index] {
        case "--join-capture":
            joinCapture.requested = true
            connect = false
            scanServices = []
            return index + 1
        case "--capture-state":
            return consumeValueInto(
                arguments, at: index, missing: "--capture-state requires a file path"
            ) { joinCapture.path = ($0 as NSString).expandingTildeInPath }
        case "--advertise-name":
            return consumeValueInto(
                arguments, at: index, missing: "--advertise-name requires a value"
            ) { joinCapture.name = $0 }
        case "--device-uuid":
            return parseDeviceUUID(arguments: arguments, at: index, joinCapture: &joinCapture)
        default:
            return nil
        }
    }

    private func parseDeviceUUID(
        arguments: [String],
        at index: Int,
        joinCapture: inout ProbeOptions.JoinCaptureRequest
    ) -> Int {
        guard index + 1 < arguments.count else {
            configurationError = "--device-uuid requires a 16-byte hex value"
            return index + 1
        }
        do {
            let value = try bytes(hex: arguments[index + 1])
            guard value.count == 16 else {
                throw AmaranHelperError.invalidState("device UUID must be 16 bytes")
            }
            joinCapture.deviceUUID = value
        } catch {
            configurationError = String(describing: error)
        }
        return index + 2
    }

    /// Consumes the value following a flag, applying it via `apply`. When the
    /// value is missing, sets `configurationError` to `missing` if provided.
    private func consumeValue(
        _ arguments: [String],
        at index: Int,
        missing: String? = nil,
        apply: (String) -> Void
    ) -> Int {
        if index + 1 < arguments.count {
            apply(arguments[index + 1])
            return index + 2
        }
        if let missing {
            configurationError = missing
        }
        return index + 1
    }

    private func consumeValueInto(
        _ arguments: [String],
        at index: Int,
        missing: String,
        apply: (String) -> Void
    ) -> Int {
        if index + 1 < arguments.count {
            apply(arguments[index + 1])
            return index + 2
        }
        configurationError = missing
        return index + 1
    }
}
