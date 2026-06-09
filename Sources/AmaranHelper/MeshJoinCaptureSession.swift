import CoreBluetooth
import Foundation

extension MeshJoinCapturePeripheral {
    func handleIncomingProxyPdu(_ proxyPdu: [UInt8]) throws {
        receiveSegmentCount += 1
        let reassembly = try reassembler.receive(proxyPdu)
        events.append([
            "event": "proxy_segment_in",
            "pending": reassembly.pending,
            "segments": reassembly.segmentCount,
            "bytes": proxyPdu.count
        ])
        guard let provisioningPdu = reassembly.provisioningPdu else {
            return
        }

        receivePduCount += 1
        let result = try session.receive(provisioningPdu)
        events.append([
            "event": "provisioning_pdu_in",
            "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(provisioningPdu[0]),
            "state": result.state.rawValue,
            "outgoing_pdu_count": result.outgoingPdus.count,
            "completed": result.completed
        ])

        if let failedErrorName = result.failedErrorName {
            throw AmaranHelperError.invalidState("provisioning failed: \(failedErrorName)")
        }
        if !result.outgoingPdus.isEmpty {
            try enqueueOutgoingProvisioningPdus(result.outgoingPdus)
        }
        if result.completed {
            completionPending = true
            completeIfReady()
        }
    }

    func enqueueOutgoingProvisioningPdus(_ provisioningPdus: [[UInt8]]) throws {
        for pdu in provisioningPdus {
            sentPduCount += 1
            let segments = try NativeMeshProvisioning.segmentedProxyPdus(
                provisioningPdu: pdu,
                maxSegmentPayloadBytes: 19
            )
            outgoingQueue.append(contentsOf: segments)
            events.append([
                "event": "provisioning_pdu_out",
                "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(pdu[0]),
                "bytes": pdu.count,
                "proxy_segments": segments.count
            ])
        }
        sendNextQueuedProxySegment()
    }

    func sendNextQueuedProxySegment() {
        guard !finished,
              subscribedCentralCount > 0,
              let manager,
              let dataOutCharacteristic else {
            return
        }

        while !outgoingQueue.isEmpty {
            let segment = outgoingQueue[0]
            if manager.updateValue(Data(segment), for: dataOutCharacteristic, onSubscribedCentrals: nil) {
                outgoingQueue.removeFirst()
                sentProxySegmentCount += 1
            } else {
                return
            }
        }
        completeIfReady()
    }

    func completeIfReady() {
        guard completionPending, outgoingQueue.isEmpty, !stateWritten else {
            return
        }
        do {
            try writeCaptureState()
            stateWritten = true
            events.append([
                "event": "capture_state_written",
                "path": run.captureStatePath
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.finish(ok: true, error: nil)
            }
        } catch {
            let message = String(describing: error)
            errorMessage = message
            finish(ok: false, error: message)
        }
    }

    func writeCaptureState() throws {
        guard !FileManager.default.fileExists(atPath: run.captureStatePath) else {
            throw AmaranHelperError.invalidState("capture state file already exists at \(run.captureStatePath)")
        }
        guard let capturedData = session.capturedData, let deviceKey = session.deviceKey else {
            throw AmaranHelperError.invalidState("provisioning capture is incomplete")
        }
        let now = isoTimestamp()
        let payload: [String: Any] = [
            "schema_version": 1,
            "captured_at": now,
            "source": [
                "type": "sidus_join_capture",
                "phase": "provisioning",
                "app_key_captured": false
            ],
            "mesh": [
                "net_key": NativeMeshCrypto.hex(capturedData.networkKey),
                "key_index": capturedData.keyIndex,
                "flags": capturedData.flags,
                "iv_index": Int(capturedData.ivIndex)
            ],
            "captured_node": [
                "device_uuid": NativeMeshCrypto.hex(run.deviceUUID),
                "device_key": NativeMeshCrypto.hex(deviceKey),
                "unicast_address": Int(capturedData.unicastAddress),
                "element_count": run.elementCount
            ],
            "app_key": NSNull(),
            "app_key_captured": false,
            "next_step": "Provisioning capture has NetKey and the fake node DeviceKey. "
                + "AppKey is still required before runtime fixture control can join this mesh."
        ]
        try writeSensitiveJSONPayload(payload, to: run.captureStatePath)
    }

    func handleTimeout() {
        if finished {
            return
        }
        if centralState != "poweredOn" {
            finish(ok: false, error: "Bluetooth peripheral did not become available (state \(centralState))")
            return
        }
        if !advertisingStarted {
            finish(ok: false, error: "join capture did not start advertising")
        } else if receivePduCount == 0 {
            finish(ok: false, error: "join capture timed out waiting for Sidus Link provisioning")
        } else {
            finish(ok: false, error: errorMessage ?? "join capture timed out before provisioning completed")
        }
    }

    func finish(ok succeeded: Bool, error: String?) {
        guard !finished else {
            return
        }
        finished = true
        manager?.stopAdvertising()
        let elapsed = Date().timeIntervalSince(startedAt)
        var capture: [String: Any] = [
            "started": centralState == "poweredOn",
            "advertising_started": advertisingStarted,
            "service_data_advertised": serviceDataAdvertisingActive,
            "subscribed_central_count": subscribedCentralCount,
            "received_proxy_segments": receiveSegmentCount,
            "received_provisioning_pdus": receivePduCount,
            "sent_proxy_segments": sentProxySegmentCount,
            "sent_provisioning_pdus": sentPduCount,
            "completed": session.state == .complete,
            "state_written": stateWritten,
            "capture_state_path": run.captureStatePath,
            "app_key_captured": false,
            "device_uuid_suffix": NativeMeshCrypto.hex(Array(run.deviceUUID.suffix(3))),
            "session_state": session.state.rawValue
        ]
        if let capturedData = session.capturedData {
            capture["node_address"] = Int(capturedData.unicastAddress)
            capture["key_index"] = capturedData.keyIndex
            capture["flags"] = capturedData.flags
            capture["iv_index"] = Int(capturedData.ivIndex)
        }
        if let error = error ?? errorMessage {
            capture["error"] = error
        }
        if !events.isEmpty {
            capture["events"] = events
        }

        var payload: [String: Any] = [
            "ok": succeeded,
            "data": [
                "central_state": centralState,
                "elapsed_seconds": Double(round(elapsed * 1000) / 1000),
                "join_capture": capture
            ]
        ]
        if let error {
            payload["error"] = error
        }
        writePayload(payload)

        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func writePayload(_ payload: [String: Any]) {
        do {
            try writeJSONPayload(payload, to: options.outputPath)
        } catch {
            fputs("failed to write join capture output: \(error.localizedDescription)\n", stderr)
        }
    }
}
