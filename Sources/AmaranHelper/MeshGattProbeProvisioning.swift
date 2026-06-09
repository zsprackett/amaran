import CoreBluetooth
import Foundation

extension MeshGattProbe {
    func handleLiveProvisioningNotification(_ proxyPdu: [UInt8], peripheral: CBPeripheral) -> [String: Any] {
        guard !proxyPdu.isEmpty else {
            return ["length": 0, "decode_error": "empty Proxy PDU"]
        }

        let sar = (proxyPdu[0] & 0xc0) >> 6
        let messageType = proxyPdu[0] & 0x3f
        var decoded: [String: Any] = [
            "length": proxyPdu.count,
            "sar": sar,
            "type": proxyPduTypeName(messageType)
        ]
        guard messageType == NativeMeshProvisioning.proxyPduType else {
            decoded["decode_error"] = "provisioning expected a provisioning Proxy PDU"
            return decoded
        }

        do {
            let reassembly = try provisioningNotificationReassembler.receive(proxyPdu)
            var reassemblySummary: [String: Any] = [
                "pending": reassembly.pending,
                "payload_bytes": max(0, proxyPdu.count - 1),
                "segment_count": reassembly.segmentCount
            ]
            if let provisioningPdu = reassembly.provisioningPdu {
                reassemblySummary["completed"] = true
                reassemblySummary["bytes"] = provisioningPdu.count
                decoded["provisioning"] = NativeMeshProvisioning.provisioningPduSummary(provisioningPdu)
                liveProvisioningEvents.append([
                    "direction": "in",
                    "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(provisioningPdu[0]),
                    "bytes": provisioningPdu.count
                ])
                try advanceLiveProvisioningSession(with: provisioningPdu, peripheral: peripheral, decoded: &decoded)
            } else {
                reassemblySummary["completed"] = false
            }
            decoded["provisioning_reassembly"] = reassemblySummary
        } catch {
            let message = String(describing: error)
            liveProvisioningError = message
            decoded["decode_error"] = message
            finish(ok: false, error: message)
        }
        return decoded
    }

    func advanceLiveProvisioningSession(
        with provisioningPdu: [UInt8],
        peripheral: CBPeripheral,
        decoded: inout [String: Any]
    ) throws {
        guard var session = liveProvisioningSession else {
            throw AmaranHelperError.invalidState("provisioning session is not started")
        }

        let result = try session.receive(provisioningPdu)
        liveProvisioningSession = session
        decoded["provisioning_session"] = [
            "state": result.state.rawValue,
            "outgoing_pdu_count": result.outgoingPdus.count,
            "completed": result.completed,
            "failed_error": result.failedErrorName ?? NSNull()
        ]
        liveProvisioningEvents.append([
            "direction": "state",
            "state": result.state.rawValue,
            "outgoing_pdu_count": result.outgoingPdus.count,
            "completed": result.completed
        ])

        if let failedErrorName = result.failedErrorName {
            liveProvisioningError = failedErrorName
            finish(ok: false, error: "provisioning failed: \(failedErrorName)")
            return
        }

        if !result.outgoingPdus.isEmpty {
            try enqueueLiveProvisioningPdus(result.outgoingPdus, peripheral: peripheral)
        }

        if result.completed {
            try writeLiveProvisioningState()
            liveProvisioningCompleted = true
            decoded["state_written"] = liveProvisioningStateWritten
            finish(ok: true, error: nil)
        }
    }

    func writeLiveProvisioningState() throws {
        guard let run = options.nativeProvisioningRun else {
            throw AmaranHelperError.invalidState("provisioning run is not configured")
        }
        guard let deviceUUID = liveProvisioningDeviceUUID else {
            throw AmaranHelperError.invalidState("provisioning device UUID is missing")
        }
        guard let transcript = liveProvisioningSession?.transcript else {
            throw AmaranHelperError.invalidState("provisioning transcript is missing")
        }
        guard run.appendsToExistingState || !FileManager.default.fileExists(atPath: run.statePath) else {
            throw AmaranHelperError.invalidState(
                "state file already exists; use add mode or set AMARAN_CLI_STATE_PATH before provisioning"
            )
        }

        let now = isoTimestamp()
        let elementCount = transcript.capabilitiesPdu.count > 1 ? max(1, Int(transcript.capabilitiesPdu[1])) : 1
        let fixture = NativeProvisionedFixtureState(
            uuid: NativeMeshCrypto.hex(deviceUUID),
            macAddress: nil,
            code: nil,
            name: nil,
            nodeAddress: run.unicastAddress,
            deviceKey: transcript.secrets.deviceKey,
            deviceUUID: deviceUUID,
            compositionData: nil,
            elementCount: elementCount,
            updateTime: now
        )
        let payload = try buildProvisionedPayload(run: run, fixture: fixture, now: now)
        try NativeMeshState.writePayload(payload, to: run.statePath)
        liveProvisioningStateWritten = true
        liveProvisioningEvents.append([
            "direction": "state",
            "state": run.appendsToExistingState ? "appended" : "written",
            "node_address": Int(run.unicastAddress),
            "element_count": elementCount
        ])
    }

    private func buildProvisionedPayload(
        run: NativeProvisioningRun,
        fixture: NativeProvisionedFixtureState,
        now: String
    ) throws -> [String: Any] {
        if run.appendsToExistingState {
            let data = try Data(contentsOf: URL(fileURLWithPath: run.statePath))
            guard let existingPayload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AmaranHelperError.invalidState("state file must contain a JSON object")
            }
            return try NativeMeshState.appendingProvisionedFixturePayload(
                existingPayload: existingPayload,
                fixture: fixture,
                provisionedAt: now
            )
        }
        return try NativeMeshState.provisionedPayload(
            meshUUID: run.meshUUID,
            keys: NativeMeshStateKeys(netKey: run.netKey, appKey: run.appKey),
            fixture: fixture,
            provisionedAt: now,
            ivIndex: run.ivIndex,
            sequenceNext: 1,
            sourceAddress: run.sourceAddress
        )
    }
}
