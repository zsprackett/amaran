import CoreBluetooth
import Foundation

extension MeshGattProbe {
    func sendSegmentAcknowledgment(
        lower: LowerTransportSegmentedAccessDecoded,
        decodedNetwork: NetworkPduDecoded,
        material: NativeDecodeMaterial,
        peripheral: CBPeripheral?,
        duplicate: Bool
    ) -> [String: Any] {
        let ackedSegments = lower.segN == 31 ? UInt32.max : (UInt32(1) << UInt32(lower.segN + 1)) - 1
        var summary: [String: Any] = [
            "seq_zero": Int(lower.seqZero),
            "seg_n": Int(lower.segN),
            "acked_segments": Int(ackedSegments),
            "acked_segments_hex": String(format: "%08x", ackedSegments),
            "source": Int(decodedNetwork.destination),
            "destination": Int(decodedNetwork.source),
            "duplicate": duplicate
        ]

        guard let peripheral, let input = proxyDataInCharacteristic else {
            return recordAckFailure(&summary, error: "proxy Data In characteristic not ready")
        }
        guard input.properties.contains(.writeWithoutResponse) else {
            return recordAckFailure(
                &summary, error: "proxy Data In characteristic does not support writeWithoutResponse"
            )
        }
        guard peripheral.canSendWriteWithoutResponse else {
            return recordAckFailure(&summary, error: "peripheral is not ready for writeWithoutResponse")
        }

        do {
            let reserved = try reserveNativeRuntimeSequence(
                statePath: options.statePath,
                lastReservedBy: "segment-ack"
            )
            let network = try buildSegmentAckNetworkPdu(
                lower: lower, decodedNetwork: decodedNetwork, material: material, sequence: reserved.sequence
            )
            summary["sequence"] = reserved.sequence
            summary["sequence_next"] = reserved.sequenceNext
            summary["ttl"] = 0
            summary["bytes"] = network.proxyPdu.count

            peripheral.writeValue(Data(network.proxyPdu), for: input, type: .withoutResponse)
            summary["written"] = true
            summary["write_type"] = "withoutResponse"
            outboundSegmentAckSummaries.append(summary)
            return summary
        } catch {
            return recordAckFailure(&summary, error: String(describing: error))
        }
    }

    private func buildSegmentAckNetworkPdu(
        lower: LowerTransportSegmentedAccessDecoded,
        decodedNetwork: NetworkPduDecoded,
        material: NativeDecodeMaterial,
        sequence: Int
    ) throws -> NetworkPduResult {
        let ackedSegments = lower.segN == 31 ? UInt32.max : (UInt32(1) << UInt32(lower.segN + 1)) - 1
        let transportPdu = try NativeMeshCrypto.lowerTransportSegmentAcknowledgmentPdu(
            seqZero: lower.seqZero,
            ackedSegments: ackedSegments
        )
        return try NativeMeshCrypto.networkPdu(
            input: NetworkPduInput(
                context: MeshMessageContext(
                    ivIndex: material.ivIndex,
                    sequence: UInt32(sequence),
                    source: decodedNetwork.destination,
                    destination: decodedNetwork.source
                ),
                keyMaterial: material.networkKeys,
                ctl: 1,
                ttl: 0
            ),
            transportPdu: transportPdu
        )
    }

    private func recordAckFailure(_ summary: inout [String: Any], error: String) -> [String: Any] {
        summary["written"] = false
        summary["write_error"] = error
        outboundSegmentAckSummaries.append(summary)
        return summary
    }

    func provisioningProxyNotificationSummary(_ proxyPdu: [UInt8]) -> [String: Any] {
        do {
            let reassembly = try provisioningNotificationReassembler.receive(proxyPdu)
            var summary: [String: Any] = [
                "pending": reassembly.pending,
                "payload_bytes": max(0, proxyPdu.count - 1),
                "segment_count": reassembly.segmentCount
            ]
            if let provisioningPdu = reassembly.provisioningPdu {
                summary["completed"] = true
                summary["bytes"] = provisioningPdu.count
                return [
                    "provisioning": NativeMeshProvisioning.provisioningPduSummary(provisioningPdu),
                    "provisioning_reassembly": summary
                ]
            }
            summary["completed"] = false
            return [
                "provisioning_reassembly": summary
            ]
        } catch {
            return [
                "decode_error": String(describing: error)
            ]
        }
    }

    func proxyPduTypeName(_ value: UInt8) -> String {
        switch value {
        case 0x00: return "network"
        case 0x01: return "meshBeacon"
        case 0x02: return "proxyConfiguration"
        case 0x03: return "provisioning"
        default: return "unknown"
        }
    }

    func meshBeaconSummary(_ beacon: [UInt8]) -> [String: Any] {
        guard beacon.count == 22, beacon[0] == 0x01 else {
            return ["bytes": beacon.count]
        }
        var result: [String: Any] = [
            "type": "secureNetwork",
            "flags": beacon[1],
            "key_refresh": (beacon[1] & 0x01) != 0,
            "iv_update": (beacon[1] & 0x02) != 0,
            "iv_index": UInt32(beacon[10]) << 24 | UInt32(beacon[11]) << 16
                | UInt32(beacon[12]) << 8 | UInt32(beacon[13]),
            "auth_value_bytes": 8
        ]
        if let requiredNetworkId = options.requiredProxyNetworkId {
            result["network_id_match"] = Array(beacon[2..<10]) == requiredNetworkId
        }
        return result
    }

    func controlMessageSummary(_ transportPdu: [UInt8]) -> [String: Any] {
        guard let first = transportPdu.first else {
            return ["decode_error": "empty lower transport control PDU"]
        }

        var result: [String: Any] = [
            "bytes": transportPdu.count,
            "segmented": (first & 0x80) != 0
        ]
        if (first & 0x80) == 0 {
            result["opcode"] = first & 0x7f
            if first == 0x00 {
                do {
                    let ack = try NativeMeshCrypto.decodeLowerTransportSegmentAcknowledgment(
                        lowerTransportPdu: transportPdu
                    )
                    result["opcode_name"] = "segment_acknowledgment"
                    result["obo"] = ack.obo
                    result["seq_zero"] = ack.seqZero
                    result["acked_segments"] = ack.ackedSegments
                    result["acked_segments_hex"] = String(format: "%08x", ack.ackedSegments)
                } catch {
                    result["decode_error"] = String(describing: error)
                }
            }
        } else {
            result["opcode"] = first & 0x7f
        }
        return result
    }

    func accessOpcodeLength(_ accessMessage: [UInt8]) -> Int? {
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
}
