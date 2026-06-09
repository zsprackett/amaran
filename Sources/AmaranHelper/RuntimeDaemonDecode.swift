import CoreBluetooth
import Foundation

extension MeshRuntimeDaemon {
    func finishActive(ok succeeded: Bool, error: String?) {
        guard let command = activeCommand else {
            return
        }
        command.timeoutWorkItem?.cancel()
        activeCommand = nil
        let elapsed = Date().timeIntervalSince(command.startedAt)
        var data: [String: Any] = [
            "central_state": centralState,
            "daemon": daemonSummary(),
            "elapsed_seconds": Double(round(elapsed * 1000) / 1000),
            "connected": selectedPeripheral?.state == .connected,
            "proxy_write": proxyWriteSummary(for: command),
            "native_send": command.nativeSendMetadata
        ]
        if !command.decodedNotifications.isEmpty {
            data["proxy_notifications"] = command.decodedNotifications
        }
        var payload: [String: Any] = ["ok": succeeded, "data": data]
        if let error {
            payload["error"] = error
        }
        logCommandOutcome(command, succeeded: succeeded, elapsed: elapsed, error: error)
        sendPayload(payload, connection: command.connection)
        processQueue()
    }

    private func proxyWriteSummary(for command: RuntimeDaemonCommand) -> [String: Any] {
        [
            "attempted": command.proxyWriteStarted,
            "completed": command.proxyWriteCompleted,
            "pdu_label": command.action == "status" ? "telink-0x26-status" : "telink-0x26-control",
            "bytes": command.proxyWritePdus.reduce(0) { $0 + $1.count },
            "logical_pdu_count": command.proxyWriteLogicalPduCount == 0
                ? command.proxyPdus.count : command.proxyWriteLogicalPduCount,
            "logical_bytes": command.proxyWriteLogicalBytes == 0
                ? command.proxyPdus.reduce(0) { $0 + $1.count } : command.proxyWriteLogicalBytes,
            "characteristic": cbuuidString(meshProxyDataIn),
            "max_write_length": command.proxyWriteMaxLength,
            "proxy_sar_segmented": command.proxyWritePdus.count != command.proxyPdus.count,
            "segment_count": command.proxyWritePdus.count,
            "segment_lengths": command.proxyWriteSegmentLengths.isEmpty
                ? command.proxyWritePdus.map(\.count) : command.proxyWriteSegmentLengths,
            "segments_written": command.proxyWriteSegmentsWrittenTotal,
            "write_type": command.proxyWriteType,
            "notification_count": command.notificationLengths.count,
            "notification_lengths": command.notificationLengths
        ]
    }

    private func logCommandOutcome(
        _ command: RuntimeDaemonCommand,
        succeeded: Bool,
        elapsed: TimeInterval,
        error: String?
    ) {
        let elapsedString = String(format: "%.3f", elapsed)
        if succeeded {
            Log.command.info(
                "command \(command.action, privacy: .public) ok in \(elapsedString, privacy: .public)s"
            )
        } else {
            let failureMessage = "command \(command.action) failed in \(elapsedString)s: "
                + "\(error ?? "unknown error")"
            Log.command.error("\(failureMessage, privacy: .public)")
        }
    }

    func proxyNetworkMatches(advertisementData: [String: Any], networkId: [UInt8]) -> Bool {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        guard let proxyData = serviceData[meshProxyService] else {
            return false
        }
        let bytes = Array(proxyData)
        return bytes.count == 9 && bytes[0] == 0x00 && Array(bytes[1...]) == networkId
    }

    func decodeRuntimeProxyNotification(_ proxyPdu: [UInt8], material: NativeDecodeMaterial) -> [String: Any] {
        guard !proxyPdu.isEmpty else {
            return ["length": 0, "decode_error": "empty Proxy PDU"]
        }
        let sar = (proxyPdu[0] & 0xc0) >> 6
        let messageType = proxyPdu[0] & 0x3f
        var result: [String: Any] = [
            "length": proxyPdu.count,
            "sar": sar,
            "type": messageType == 0x00 ? "network" : (messageType == 0x01 ? "meshBeacon" : "unknown")
        ]
        guard messageType == 0x00 else {
            return result
        }
        do {
            try decodeRuntimeNetwork(Array(proxyPdu.dropFirst()), material: material, result: &result)
        } catch {
            result["decode_error"] = String(describing: error)
        }
        return result
    }

    private func decodeRuntimeNetwork(
        _ networkPdu: [UInt8],
        material: NativeDecodeMaterial,
        result: inout [String: Any]
    ) throws {
        let decodedNetwork = try NativeMeshCrypto.decodeNetworkPdu(
            networkPdu: networkPdu,
            ivIndex: material.ivIndex,
            nid: material.networkKeys.nid,
            encryptionKey: material.networkKeys.encryptionKey,
            privacyKey: material.networkKeys.privacyKey
        )
        result["network"] = [
            "ctl": decodedNetwork.ctl,
            "ttl": decodedNetwork.ttl,
            "sequence": decodedNetwork.sequence,
            "source": decodedNetwork.source,
            "destination": decodedNetwork.destination,
            "transport_bytes": decodedNetwork.transportPdu.count
        ]
        guard decodedNetwork.ctl == 0 else {
            return
        }
        guard let first = decodedNetwork.transportPdu.first, (first & 0x80) == 0 else {
            result["lower_transport"] = ["segmented": true]
            return
        }
        let lower = try NativeMeshCrypto.decodeLowerTransportUnsegmentedAccessPdu(
            lowerTransportPdu: decodedNetwork.transportPdu
        )
        result["lower_transport"] = [
            "segmented": false,
            "akf": lower.akf,
            "aid": lower.aid,
            "upper_transport_bytes": lower.upperTransportPdu.count
        ]
        guard lower.akf && lower.aid == material.appAid else {
            return
        }
        let upper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
            applicationKey: material.appKey,
            context: MeshMessageContext(
                ivIndex: material.ivIndex,
                sequence: decodedNetwork.sequence,
                source: decodedNetwork.source,
                destination: decodedNetwork.destination
            ),
            upperTransportPdu: lower.upperTransportPdu,
            transMicLength: 4
        )
        result["access"] = runtimeAccessMessageSummary(upper.accessMessage)
    }

    private func runtimeAccessMessageSummary(_ accessMessage: [UInt8]) -> [String: Any] {
        guard let opcodeLength = runtimeAccessOpcodeLength(accessMessage) else {
            return ["decode_error": "invalid access opcode", "bytes": accessMessage.count]
        }
        let opcode = Array(accessMessage.prefix(opcodeLength))
        var result: [String: Any] = [
            "opcode": NativeMeshCrypto.hex(opcode),
            "opcode_type": opcodeLength == 3 ? "vendor" : "sig",
            "parameters_bytes": max(0, accessMessage.count - opcodeLength)
        ]
        if opcodeLength == 1 && opcode[0] == NativeTelinkControl.accessOpcode {
            let parameters = Array(accessMessage.dropFirst())
            if let telink = NativeTelinkControl.decodePacket(parameters) {
                result["telink"] = telink
            }
        }
        return result
    }

    private func runtimeAccessOpcodeLength(_ accessMessage: [UInt8]) -> Int? {
        guard let first = accessMessage.first else {
            return nil
        }
        let length: Int
        if (first & 0x80) == 0 {
            length = 1
        } else if (first & 0xc0) == 0x80 {
            length = 2
        } else {
            length = 3
        }
        return accessMessage.count >= length ? length : nil
    }

    func isTelinkCCTStatus(_ decoded: [String: Any]) -> Bool {
        guard let access = decoded["access"] as? [String: Any],
              let telink = access["telink"] as? [String: Any] else {
            return false
        }
        return telink["cct"] != nil
    }
}
