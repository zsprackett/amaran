import CoreBluetooth
import Foundation

extension MeshGattProbe {
    struct CompletedSegmentedAccess {
        let reassembled: LowerTransportSegmentedAccessReassembled
        let sequence: UInt32
        let summary: [String: Any]
    }

    func decodeProxyNotification(_ proxyPdu: [UInt8], peripheral: CBPeripheral?) -> [String: Any] {
        guard !proxyPdu.isEmpty else {
            return ["length": 0, "decode_error": "empty Proxy PDU"]
        }

        let sar = (proxyPdu[0] & 0xc0) >> 6
        let messageType = proxyPdu[0] & 0x3f
        var result: [String: Any] = [
            "length": proxyPdu.count,
            "sar": sar,
            "type": proxyPduTypeName(messageType)
        ]
        guard messageType == 0x00 else {
            if messageType == 0x01 {
                result["beacon"] = meshBeaconSummary(Array(proxyPdu.dropFirst()))
            } else if messageType == 0x03 {
                result.merge(provisioningProxyNotificationSummary(proxyPdu)) { _, new in new }
            }
            return result
        }
        guard let material = options.decodeMaterial else {
            result["decode_error"] = "no local decode material"
            return result
        }

        do {
            try decodeNetworkNotification(
                Array(proxyPdu.dropFirst()), material: material, peripheral: peripheral, result: &result
            )
        } catch {
            result["decode_error"] = String(describing: error)
        }
        return result
    }

    private func decodeNetworkNotification(
        _ networkPdu: [UInt8],
        material: NativeDecodeMaterial,
        peripheral: CBPeripheral?,
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

        if decodedNetwork.ctl == 0 {
            try decodeAccessTransport(
                decodedNetwork: decodedNetwork,
                material: material,
                peripheral: peripheral,
                result: &result
            )
        } else {
            result["control"] = controlMessageSummary(decodedNetwork.transportPdu)
        }
    }

    private func decodeAccessTransport(
        decodedNetwork: NetworkPduDecoded,
        material: NativeDecodeMaterial,
        peripheral: CBPeripheral?,
        result: inout [String: Any]
    ) throws {
        if let first = decodedNetwork.transportPdu.first, (first & 0x80) != 0 {
            try decodeSegmentedAccessTransport(
                decodedNetwork: decodedNetwork,
                material: material,
                peripheral: peripheral,
                result: &result
            )
        } else {
            let lower = try NativeMeshCrypto.decodeLowerTransportUnsegmentedAccessPdu(
                lowerTransportPdu: decodedNetwork.transportPdu
            )
            result["lower_transport"] = [
                "segmented": false,
                "akf": lower.akf,
                "aid": lower.aid,
                "upper_transport_bytes": lower.upperTransportPdu.count
            ]
            if let access = try decodedAccessSummary(
                header: LowerTransportAccessHeader(akf: lower.akf, aid: lower.aid, szmic: false),
                context: MeshMessageContext(
                    ivIndex: material.ivIndex,
                    sequence: decodedNetwork.sequence,
                    source: decodedNetwork.source,
                    destination: decodedNetwork.destination
                ),
                upperTransportPdu: lower.upperTransportPdu,
                material: material
            ) {
                result["access"] = access
            }
        }
    }

    private func decodeSegmentedAccessTransport(
        decodedNetwork: NetworkPduDecoded,
        material: NativeDecodeMaterial,
        peripheral: CBPeripheral?,
        result: inout [String: Any]
    ) throws {
        let lower = try NativeMeshCrypto.decodeLowerTransportSegmentedAccessPdu(
            lowerTransportPdu: decodedNetwork.transportPdu
        )
        result["lower_transport"] = [
            "segmented": true,
            "akf": lower.akf,
            "aid": lower.aid,
            "szmic": lower.szmic,
            "seq_zero": Int(lower.seqZero),
            "seg_o": Int(lower.segO),
            "seg_n": Int(lower.segN),
            "segment_bytes": lower.segment.count
        ]
        let accessKey = segmentedAccessKey(lower, decodedNetwork: decodedNetwork)
        if completedSegmentedAccessKeys.contains(accessKey) {
            result["segmented_access"] = [
                "pending": false,
                "completed": true,
                "duplicate": true,
                "seq_zero": Int(lower.seqZero),
                "seg_o": Int(lower.segO),
                "seg_n": Int(lower.segN)
            ]
            result["outbound_segment_ack"] = sendSegmentAcknowledgment(
                lower: lower, decodedNetwork: decodedNetwork, material: material,
                peripheral: peripheral, duplicate: true
            )
        } else if let completed = try receiveSegmentedAccess(lower, decodedNetwork: decodedNetwork) {
            result["segmented_access"] = completed.summary
            result["outbound_segment_ack"] = sendSegmentAcknowledgment(
                lower: lower, decodedNetwork: decodedNetwork, material: material,
                peripheral: peripheral, duplicate: false
            )
            try summarizeCompletedSegmentedAccess(
                completed, decodedNetwork: decodedNetwork, material: material, result: &result
            )
        } else {
            result["segmented_access"] = segmentedAccessPendingSummary(lower)
        }
    }

    private func summarizeCompletedSegmentedAccess(
        _ completed: CompletedSegmentedAccess,
        decodedNetwork: NetworkPduDecoded,
        material: NativeDecodeMaterial,
        result: inout [String: Any]
    ) throws {
        if let access = try decodedAccessSummary(
            header: LowerTransportAccessHeader(
                akf: completed.reassembled.akf,
                aid: completed.reassembled.aid,
                szmic: completed.reassembled.szmic
            ),
            context: MeshMessageContext(
                ivIndex: material.ivIndex,
                sequence: completed.sequence,
                source: decodedNetwork.source,
                destination: decodedNetwork.destination
            ),
            upperTransportPdu: completed.reassembled.upperTransportPdu,
            material: material
        ) {
            result["access"] = access
        }
    }

    func receiveSegmentedAccess(
        _ lower: LowerTransportSegmentedAccessDecoded,
        decodedNetwork: NetworkPduDecoded
    ) throws -> CompletedSegmentedAccess? {
        let key = segmentedAccessKey(lower, decodedNetwork: decodedNetwork)
        if var pending = segmentedAccessReassemblies[key] {
            try pending.add(
                decoded: lower,
                sequence: decodedNetwork.sequence,
                lowerTransportPdu: decodedNetwork.transportPdu
            )
            segmentedAccessReassemblies[key] = pending
        } else {
            segmentedAccessReassemblies[key] = IncomingSegmentedAccessAccumulator(
                decoded: lower,
                sequence: decodedNetwork.sequence,
                lowerTransportPdu: decodedNetwork.transportPdu
            )
        }

        guard let pending = segmentedAccessReassemblies[key] else {
            return nil
        }
        guard pending.isComplete else {
            return nil
        }
        guard let sequence = pending.segmentZeroSequence else {
            throw AmaranHelperError.invalidState("segmented access reassembly is missing segment zero")
        }
        let reassembled = try NativeMeshCrypto.reassembleLowerTransportSegmentedAccessPdus(
            lowerTransportPdus: pending.orderedLowerTransportPdus
        )
        segmentedAccessReassemblies.removeValue(forKey: key)
        completedSegmentedAccessKeys.insert(key)
        return CompletedSegmentedAccess(
            reassembled: reassembled,
            sequence: sequence,
            summary: [
                "pending": false,
                "completed": true,
                "seq_zero": Int(reassembled.seqZero),
                "segment_count": Int(pending.segN) + 1,
                "upper_transport_bytes": reassembled.upperTransportPdu.count
            ]
        )
    }

    func segmentedAccessPendingSummary(_ lower: LowerTransportSegmentedAccessDecoded) -> [String: Any] {
        [
            "pending": true,
            "completed": false,
            "seq_zero": Int(lower.seqZero),
            "seg_o": Int(lower.segO),
            "seg_n": Int(lower.segN)
        ]
    }

    func segmentedAccessKey(
        _ lower: LowerTransportSegmentedAccessDecoded,
        decodedNetwork: NetworkPduDecoded
    ) -> String {
        [
            String(decodedNetwork.source),
            String(decodedNetwork.destination),
            String(lower.akf ? 1 : 0),
            String(lower.aid),
            String(lower.szmic ? 1 : 0),
            String(lower.seqZero),
            String(lower.segN)
        ].joined(separator: ":")
    }

    func decodedAccessSummary(
        header: LowerTransportAccessHeader,
        context: MeshMessageContext,
        upperTransportPdu: [UInt8],
        material: NativeDecodeMaterial
    ) throws -> [String: Any]? {
        if header.akf && header.aid == material.appAid {
            let upper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
                applicationKey: material.appKey,
                context: context,
                upperTransportPdu: upperTransportPdu,
                transMicLength: header.szmic ? 8 : 4
            )
            return accessMessageSummaryWithState(upper.accessMessage)
        }
        if !header.akf, let deviceKey = material.deviceKey {
            let upper = try NativeMeshCrypto.decodeUpperTransportAccessPdu(
                deviceKey: deviceKey,
                context: context,
                upperTransportPdu: upperTransportPdu,
                transMicLength: header.szmic ? 8 : 4
            )
            var access = accessMessageSummaryWithState(upper.accessMessage)
            access["key"] = "device"
            return access
        }
        return nil
    }

    func handleSegmentAcknowledgment(_ decodedNotification: [String: Any]) {
        guard let expectedSeqZero = options.expectedSegmentAckSeqZero,
              let expectedSegN = options.expectedSegmentAckSegN,
              let control = decodedNotification["control"] as? [String: Any],
              (control["opcode_name"] as? String) == "segment_acknowledgment" else {
            return
        }
        let seqZero: UInt16?
        if let value = control["seq_zero"] as? UInt16 {
            seqZero = value
        } else if let value = jsonInt(control["seq_zero"]) {
            seqZero = UInt16(exactly: value)
        } else {
            seqZero = nil
        }
        guard let seqZero, seqZero == expectedSeqZero else {
            return
        }

        let ackedSegments: UInt32
        if let number = control["acked_segments"] as? NSNumber {
            ackedSegments = number.uint32Value
        } else if let value = control["acked_segments"] as? UInt32 {
            ackedSegments = value
        } else if let value = control["acked_segments"] as? Int {
            ackedSegments = UInt32(value)
        } else {
            return
        }

        segmentAckNotificationCount += 1
        segmentAckLastSeqZero = seqZero
        segmentAckedSegments |= ackedSegments
        let expectedMask = expectedSegN == 31 ? UInt32.max : (UInt32(1) << UInt32(expectedSegN + 1)) - 1
        if (segmentAckedSegments & expectedMask) == expectedMask {
            segmentAckComplete = true
            proxyWriteCompleted = true
            finishAfterProxySettle()
        }
    }
}
