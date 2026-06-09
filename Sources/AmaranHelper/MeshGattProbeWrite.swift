import CoreBluetooth
import Foundation

extension MeshGattProbe {
    func startLiveProvisioning(_ peripheral: CBPeripheral) {
        guard !liveProvisioningStarted else {
            return
        }
        guard let run = options.nativeProvisioningRun else {
            finish(ok: false, error: "provisioning run is not configured")
            return
        }
        guard let deviceUUID = liveProvisioningDeviceUUID else {
            finish(ok: false, error: "unprovisioned advertisement did not include a device UUID")
            return
        }

        do {
            var session = try NativeNoOobProvisioningSession(
                provisionerKeyPair: run.provisionerKeyPair,
                provisionerRandom: run.provisionerRandom,
                networkKey: run.netKey,
                keyIndex: run.keyIndex,
                flags: run.flags,
                ivIndex: run.ivIndex,
                unicastAddress: run.unicastAddress
            )
            let invite = try session.start(attentionDuration: run.attentionDuration)
            liveProvisioningSession = session
            liveProvisioningStarted = true
            liveProvisioningEvents.append([
                "direction": "out",
                "pdu_type": "provisioning_invite",
                "state": session.state.rawValue,
                "device_uuid_suffix": NativeMeshCrypto.hex(Array(deviceUUID.suffix(3)))
            ])
            try enqueueLiveProvisioningPdus([invite], peripheral: peripheral)
        } catch {
            let message = String(describing: error)
            liveProvisioningError = message
            finish(ok: false, error: message)
        }
    }

    func enqueueLiveProvisioningPdus(_ provisioningPdus: [[UInt8]], peripheral: CBPeripheral) throws {
        for pdu in provisioningPdus {
            let proxyPdus = try NativeMeshProvisioning.segmentedProxyPdus(
                provisioningPdu: pdu,
                maxSegmentPayloadBytes: 20
            )
            liveProvisioningQueue.append(contentsOf: proxyPdus)
            liveProvisioningEvents.append([
                "direction": "out",
                "pdu_type": NativeMeshProvisioning.provisioningPduTypeName(pdu[0]),
                "bytes": pdu.count,
                "proxy_segments": proxyPdus.count
            ])
        }
        writeNextLiveProvisioningProxyPdu(peripheral)
    }

    func writeNextLiveProvisioningProxyPdu(_ peripheral: CBPeripheral) {
        guard options.nativeProvisioningRun != nil, !liveProvisioningCompleted else {
            return
        }
        guard !liveProvisioningPendingWriteResponse else {
            return
        }
        guard !liveProvisioningQueue.isEmpty else {
            liveProvisioningWriting = false
            return
        }
        guard let input = proxyDataInCharacteristic else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) not found"
            )
            return
        }

        liveProvisioningWriting = true
        let data = Data(liveProvisioningQueue[0])
        if input.properties.contains(.writeWithoutResponse) {
            liveProvisioningWriteType = "withoutResponse"
            peripheral.writeValue(data, for: input, type: .withoutResponse)
            liveProvisioningQueue.removeFirst()
            liveProvisioningProxySegmentsWritten += 1
            liveProvisioningProxySegmentLengths.append(data.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak peripheral] in
                guard let self, let peripheral else {
                    return
                }
                self.writeNextLiveProvisioningProxyPdu(peripheral)
            }
        } else if input.properties.contains(.write) {
            liveProvisioningWriteType = "withResponse"
            liveProvisioningPendingWriteResponse = true
            peripheral.writeValue(data, for: input, type: .withResponse)
        } else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) is not writable"
            )
        }
    }

    func handleLiveProvisioningWriteResponse(_ peripheral: CBPeripheral, error: Error?) {
        if let error {
            let message = "\(writeDataInLabel()) write failed: \(error.localizedDescription)"
            liveProvisioningError = message
            finish(ok: false, error: message)
            return
        }
        guard liveProvisioningPendingWriteResponse else {
            return
        }
        liveProvisioningPendingWriteResponse = false
        if !liveProvisioningQueue.isEmpty {
            let count = liveProvisioningQueue.removeFirst().count
            liveProvisioningProxySegmentsWritten += 1
            liveProvisioningProxySegmentLengths.append(count)
        }
        writeNextLiveProvisioningProxyPdu(peripheral)
    }

    func writeProxyPdus(_ peripheral: CBPeripheral) {
        guard !proxyWriteStarted else {
            return
        }
        guard !options.configuredProxyPdus().isEmpty else {
            finish(ok: false, error: "no proxy PDU configured")
            return
        }
        guard let input = proxyDataInCharacteristic else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) not found"
            )
            return
        }

        let logicalPdus = options.configuredProxyPdus()
        proxyWriteStarted = true
        proxyWriteIndex = 0
        proxyWriteSegmentsWrittenTotal = 0
        proxyWriteLogicalPduCount = logicalPdus.count
        proxyWriteLogicalBytes = logicalPdus.reduce(0) { $0 + $1.count }
        if options.expectedSegmentAckSeqZero != nil {
            segmentAckSendAttempts = 1
        }
        do {
            let writeType: CBCharacteristicWriteType = input.properties.contains(.writeWithoutResponse)
                ? .withoutResponse
                : .withResponse
            proxyWriteMaxLength = peripheral.maximumWriteValueLength(for: writeType)
            proxyWritePdus = try logicalPdus.flatMap {
                try segmentProxyProtocolPdu($0, maxWriteLength: proxyWriteMaxLength)
            }
            proxyWriteSegmentLengths = proxyWritePdus.map(\.count)
            writeNextProxyPdu(peripheral, input: input)
        } catch {
            finish(ok: false, error: String(describing: error))
        }
    }

    func writeNextProxyPdu(_ peripheral: CBPeripheral, input: CBCharacteristic? = nil) {
        guard !proxyWriteCompleted else {
            return
        }
        let pdus = proxyWritePdus
        guard proxyWriteIndex < pdus.count else {
            completeProxyWriteOrWaitForAck()
            return
        }
        guard let input = input ?? proxyDataInCharacteristic else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) not found"
            )
            return
        }

        let data = Data(pdus[proxyWriteIndex])
        if input.properties.contains(.writeWithoutResponse) {
            writeProxyPduWithoutResponse(data, peripheral: peripheral, input: input, pduCount: pdus.count)
        } else if input.properties.contains(.write) {
            proxyWriteType = "withResponse"
            peripheral.writeValue(data, for: input, type: .withResponse)
        } else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) is not writable"
            )
        }
    }

    private func writeProxyPduWithoutResponse(
        _ data: Data,
        peripheral: CBPeripheral,
        input: CBCharacteristic,
        pduCount: Int
    ) {
        guard peripheral.canSendWriteWithoutResponse else {
            return
        }
        proxyWriteType = "withoutResponse"
        peripheral.writeValue(data, for: input, type: .withoutResponse)
        proxyWriteIndex += 1
        proxyWriteSegmentsWrittenTotal += 1
        if proxyWriteIndex >= pduCount {
            completeProxyWriteOrWaitForAck()
            return
        }
        let delay: TimeInterval
        if options.proxyWritePauseEvery > 0, proxyWriteIndex % options.proxyWritePauseEvery == 0 {
            delay = options.proxyWritePauseDuration
        } else {
            delay = options.proxyWriteInterSegmentDelay
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
            guard let self, let peripheral else {
                return
            }
            self.writeNextProxyPdu(peripheral)
        }
    }

    func completeProxyWriteOrWaitForAck() {
        if options.expectedSegmentAckSeqZero != nil {
            if segmentAckComplete {
                proxyWriteCompleted = true
                finishAfterProxySettle()
            } else {
                scheduleSegmentAckRetryIfNeeded()
            }
            return
        }

        proxyWriteCompleted = true
        finishAfterProxySettle()
    }

    func scheduleSegmentAckRetryIfNeeded() {
        guard !finished,
              !segmentAckRetryScheduled,
              segmentAckSendAttempts < options.segmentAckMaxSendAttempts,
              let peripheral = selectedPeripheral else {
            return
        }

        segmentAckRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + options.segmentAckRetryDelay) { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  !self.finished,
                  !self.segmentAckComplete,
                  !self.proxyWriteCompleted else {
                return
            }
            self.segmentAckRetryScheduled = false
            self.segmentAckSendAttempts += 1
            self.proxyWriteIndex = 0
            self.writeNextProxyPdu(peripheral)
        }
    }

    func finishAfterProxySettle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + options.settleAfterWrite) { [weak self] in
            self?.finish(ok: true, error: nil)
        }
    }
}
