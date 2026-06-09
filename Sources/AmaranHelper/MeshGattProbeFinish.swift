import CoreBluetooth
import Foundation

extension MeshGattProbe {
    func handleTimeout() {
        if centralState != "poweredOn" && discoveries.isEmpty {
            finish(ok: false, error: "Bluetooth did not become available (central_state \(centralState))")
            return
        }
        if options.nativeProvisioningRun != nil && !liveProvisioningCompleted {
            if selectedPeripheral == nil {
                finish(ok: false, error: "no Mesh Provisioning service device found")
            } else {
                finish(ok: false, error: liveProvisioningError ?? "provisioning timed out")
            }
        } else if options.hasProxyWrite && !proxyWriteCompleted {
            handleProxyWriteTimeout()
        } else {
            finish(ok: true, error: nil)
        }
    }

    private func handleProxyWriteTimeout() {
        if selectedPeripheral == nil && options.connectService == meshProvisioningService {
            finish(ok: false, error: "no Mesh Provisioning service device found")
        } else if options.requiredProxyNetworkId != nil && selectedPeripheral == nil {
            finish(ok: false, error: "no matching Mesh Proxy Network ID found")
        } else if options.expectedSegmentAckSeqZero != nil && proxyWriteIndex >= proxyWritePdus.count {
            finish(ok: false, error: "segment acknowledgment timed out")
        } else {
            finish(ok: false, error: "proxy write timed out")
        }
    }

    func finish(ok succeeded: Bool, error: String?) {
        guard !finished else {
            return
        }
        finished = true
        manager?.stopScan()
        if let peripheral = selectedPeripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        var payload: [String: Any] = ["ok": succeeded, "data": buildFinishData(elapsed: elapsed)]
        if let error {
            payload["error"] = error
        }
        writeAdvertisementCapture(ok: succeeded, error: error)
        writePayload(payload)

        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    private func buildFinishData(elapsed: TimeInterval) -> [String: Any] {
        var data: [String: Any] = [
            "central_state": centralState,
            "elapsed_seconds": Double(round(elapsed * 1000) / 1000),
            "scanned_services": options.scanServices.map(cbuuidString).sorted(),
            "connected": discoveries.values.contains { ($0["connected"] as? Bool) == true },
            "discoveries": discoveries.values.sorted {
                ($0["rssi"] as? Int ?? -999) > ($1["rssi"] as? Int ?? -999)
            }
        ]
        if let selectedPeripheral {
            data["selected_peripheral_id"] = selectedPeripheral.identifier.uuidString
        }
        addProxyWriteData(&data)
        addMonitorData(&data)
        addMetadataAndProvisioningData(&data)
        return data
    }

    private func addProxyWriteData(_ data: inout [String: Any]) {
        guard options.hasProxyWrite else {
            return
        }
        data["proxy_write"] = proxyWriteSummary()
        if let segmentAck = segmentAckSummary() {
            data["segment_ack"] = segmentAck
        }
        if !decodedNotifications.isEmpty {
            data["proxy_notifications"] = decodedNotifications
        }
    }

    private func addMonitorData(_ data: inout [String: Any]) {
        guard options.monitorDuration != nil else {
            return
        }
        data["monitor"] = monitorSummary()
        if !decodedNotifications.isEmpty {
            data["proxy_notifications"] = decodedNotifications
        }
    }

    private func addMetadataAndProvisioningData(_ data: inout [String: Any]) {
        if !outboundSegmentAckSummaries.isEmpty {
            data["outbound_segment_acks"] = outboundSegmentAckSummaries
        }
        if let nativeSendMetadata = options.nativeSendMetadata {
            data["native_send"] = nativeSendMetadata
        }
        if let storedCompositionDataSummary {
            data["composition_data"] = storedCompositionDataSummary
        }
        if options.nativeProvisioningRun != nil {
            data["native_provisioning"] = provisioningSummary()
        }
        if let advertisementCapturePath = options.advertisementCapturePath {
            data["advertisement_capture"] = [
                "path": advertisementCapturePath,
                "count": advertisementCapturesByPeripheralID.count
            ]
        }
    }

    private func proxyWriteSummary() -> [String: Any] {
        let logicalProxyPdus = options.configuredProxyPdus()
        let writtenProxyPdus = proxyWritePdus.isEmpty ? logicalProxyPdus : proxyWritePdus
        return [
            "attempted": proxyWriteStarted,
            "completed": proxyWriteCompleted,
            "pdu_label": options.proxyPduLabel,
            "bytes": writtenProxyPdus.reduce(0) { $0 + $1.count },
            "logical_pdu_count": proxyWriteLogicalPduCount == 0
                ? logicalProxyPdus.count : proxyWriteLogicalPduCount,
            "logical_bytes": proxyWriteLogicalBytes == 0
                ? logicalProxyPdus.reduce(0) { $0 + $1.count } : proxyWriteLogicalBytes,
            "characteristic": cbuuidString(options.writeDataInUUID),
            "max_write_length": proxyWriteMaxLength,
            "proxy_sar_segmented": writtenProxyPdus.count != logicalProxyPdus.count,
            "segment_count": writtenProxyPdus.count,
            "segment_lengths": proxyWriteSegmentLengths.isEmpty
                ? writtenProxyPdus.map(\.count) : proxyWriteSegmentLengths,
            "segments_written": proxyWriteSegmentsWrittenTotal,
            "write_type": proxyWriteType,
            "notification_count": notificationLengths.count,
            "notification_lengths": notificationLengths
        ]
    }

    private func segmentAckSummary() -> [String: Any]? {
        guard let expectedSeqZero = options.expectedSegmentAckSeqZero,
              let expectedSegN = options.expectedSegmentAckSegN else {
            return nil
        }
        return [
            "expected_seq_zero": Int(expectedSeqZero),
            "expected_seg_n": Int(expectedSegN),
            "last_seq_zero": segmentAckLastSeqZero.map { Int($0) } ?? NSNull(),
            "acked_segments": Int(segmentAckedSegments),
            "acked_segments_hex": String(format: "%08x", segmentAckedSegments),
            "complete": segmentAckComplete,
            "notification_count": segmentAckNotificationCount,
            "send_attempts": segmentAckSendAttempts,
            "max_send_attempts": options.segmentAckMaxSendAttempts
        ]
    }

    private func monitorSummary() -> [String: Any] {
        [
            "started": options.monitorStarted,
            "duration": options.monitorDuration ?? options.timeout,
            "proxy_filter_written": options.monitorFilterWritten,
            "notification_count": notificationLengths.count,
            "notification_lengths": notificationLengths
        ]
    }

    private func provisioningSummary() -> [String: Any] {
        guard let run = options.nativeProvisioningRun else {
            return [:]
        }
        var provisioning: [String: Any] = [
            "started": liveProvisioningStarted,
            "completed": liveProvisioningCompleted,
            "state_written": liveProvisioningStateWritten,
            "state_mode": run.appendsToExistingState ? "append" : "create",
            "state_path": run.statePath,
            "node_address": Int(run.unicastAddress),
            "source_address": Int(run.sourceAddress),
            "iv_index": Int(run.ivIndex),
            "proxy_segments_written": liveProvisioningProxySegmentsWritten,
            "proxy_segment_lengths": liveProvisioningProxySegmentLengths,
            "write_type": liveProvisioningWriteType,
            "notification_count": notificationLengths.count
        ]
        if let deviceUUID = liveProvisioningDeviceUUID {
            provisioning["device_uuid_suffix"] = NativeMeshCrypto.hex(Array(deviceUUID.suffix(3)))
        }
        if let state = liveProvisioningSession?.state.rawValue {
            provisioning["session_state"] = state
        }
        if let liveProvisioningError {
            provisioning["error"] = liveProvisioningError
        }
        if !liveProvisioningEvents.isEmpty {
            provisioning["events"] = liveProvisioningEvents
        }
        return provisioning
    }

    func writePayload(_ payload: [String: Any]) {
        do {
            try writeJSONPayload(payload, to: options.outputPath)
        } catch {
            fputs("failed to write probe output: \(error.localizedDescription)\n", stderr)
        }
    }

    func writeAdvertisementCapture(ok succeeded: Bool, error: String?) {
        guard let capturePath = options.advertisementCapturePath else {
            return
        }

        var payload: [String: Any] = [
            "ok": succeeded,
            "captured_at": isoTimestamp(),
            "central_state": centralState,
            "scanned_services": options.scanServices.map(cbuuidString).sorted(),
            "advertisements": advertisementCapturesByPeripheralID.values.sorted {
                ($0["rssi"] as? Int ?? -999) > ($1["rssi"] as? Int ?? -999)
            }
        ]
        if let error {
            payload["error"] = error
        }

        do {
            try writeSensitiveJSONPayload(payload, to: capturePath)
        } catch {
            fputs("failed to write advertisement capture: \(error.localizedDescription)\n", stderr)
        }
    }

    func writeDataInLabel() -> String {
        options.writeDataInUUID == meshProvisioningDataIn ? "Mesh Provisioning Data In" : "Mesh Proxy Data In"
    }

    func writeDataOutLabel() -> String {
        options.writeDataOutUUID == meshProvisioningDataOut ? "Mesh Provisioning Data Out" : "Mesh Proxy Data Out"
    }
}
