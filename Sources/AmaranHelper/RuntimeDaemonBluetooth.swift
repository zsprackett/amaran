import CoreBluetooth
import Foundation

extension MeshRuntimeDaemon {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = centralStateName(central.state)
        Log.ble.notice("central state: \(self.centralState, privacy: .public)")
        if central.state == .unauthorized {
            Log.ble.error(
                "Bluetooth permission not granted; grant it in System Settings > Privacy & Security > Bluetooth"
            )
        }
        if central.state == .poweredOn {
            processQueue()
        } else if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
            if activeCommand != nil {
                finishActive(ok: false, error: "Bluetooth is \(centralState)")
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let activeCommand, proxyNetworkMatches(
            advertisementData: advertisementData,
            networkId: activeCommand.requiredProxyNetworkId
        ) else {
            return
        }
        scanning = false
        central.stopScan()
        selectedPeripheral = peripheral
        connectedNetworkId = activeCommand.requiredProxyNetworkId
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.ble.info("connected to mesh proxy \(peripheral.identifier.uuidString, privacy: .public)")
        peripheral.discoverServices([meshProxyService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.ble.error("connect failed: \(error?.localizedDescription ?? "Mesh Proxy connect failed", privacy: .public)")
        finishActive(ok: false, error: error?.localizedDescription ?? "Mesh Proxy connect failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.ble.info(
            "disconnected from mesh proxy\(error.map { ": \($0.localizedDescription)" } ?? "", privacy: .public)"
        )
        if selectedPeripheral === peripheral {
            selectedPeripheral = nil
            connectedNetworkId = nil
            proxyDataInCharacteristic = nil
            proxyDataOutCharacteristic = nil
            proxyNotificationsReady = false
        }
        if activeCommand != nil {
            finishActive(ok: false, error: error?.localizedDescription ?? "Mesh Proxy disconnected")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finishActive(ok: false, error: "Mesh Proxy service discovery failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        pendingCharacteristicServices = Set(services.map { cbuuidString($0.uuid) })
        if pendingCharacteristicServices.isEmpty {
            finishActive(ok: false, error: "Mesh Proxy service not found")
            return
        }
        for service in services {
            peripheral.discoverCharacteristics([meshProxyDataIn, meshProxyDataOut], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            finishActive(ok: false, error: "Mesh Proxy characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == meshProxyDataIn {
                proxyDataInCharacteristic = characteristic
            } else if characteristic.uuid == meshProxyDataOut {
                proxyDataOutCharacteristic = characteristic
            }
        }
        pendingCharacteristicServices.remove(cbuuidString(service.uuid))
        if pendingCharacteristicServices.isEmpty {
            startActiveWriteWhenReady()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == meshProxyDataOut else {
            return
        }
        if let error {
            finishActive(
                ok: false,
                error: "Mesh Proxy Data Out notification subscribe failed: \(error.localizedDescription)"
            )
            return
        }
        proxyNotificationsReady = characteristic.isNotifying
        startActiveWrite()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == meshProxyDataIn, let activeCommand else {
            return
        }
        if let error {
            finishActive(ok: false, error: "Mesh Proxy Data In write failed: \(error.localizedDescription)")
            return
        }
        activeCommand.proxyWriteIndex += 1
        activeCommand.proxyWriteSegmentsWrittenTotal += 1
        if activeCommand.proxyWriteIndex >= activeCommand.proxyWritePdus.count {
            completeActiveWrites()
        } else {
            writeNextActivePdu()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == meshProxyDataOut, let activeCommand else {
            return
        }
        if error == nil, let value = characteristic.value {
            let proxyPdu = Array(value)
            activeCommand.notificationLengths.append(proxyPdu.count)
            let decoded = decodeRuntimeProxyNotification(proxyPdu, material: activeCommand.decodeMaterial)
            activeCommand.decodedNotifications.append(decoded)
            if activeCommand.finishAfterTelinkStatus && isTelinkCCTStatus(decoded) {
                finishActive(ok: true, error: nil)
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeNextActivePdu()
    }

    func startActiveWriteWhenReady() {
        guard let peripheral = selectedPeripheral,
              let output = proxyDataOutCharacteristic,
              output.properties.contains(.notify) || output.properties.contains(.indicate) else {
            startActiveWrite()
            return
        }
        if proxyNotificationsReady || output.isNotifying {
            proxyNotificationsReady = true
            startActiveWrite()
        } else {
            peripheral.setNotifyValue(true, for: output)
        }
    }

    func startActiveWrite() {
        guard let activeCommand, !activeCommand.proxyWriteStarted else {
            return
        }
        guard let peripheral = selectedPeripheral, peripheral.state == .connected else {
            reconnectForActiveCommand()
            return
        }
        guard let input = proxyDataInCharacteristic else {
            finishActive(ok: false, error: "Mesh Proxy Data In characteristic not found")
            return
        }

        do {
            let writeType: CBCharacteristicWriteType = input.properties.contains(.writeWithoutResponse)
                ? .withoutResponse
                : .withResponse
            activeCommand.proxyWriteStarted = true
            activeCommand.proxyWriteIndex = 0
            activeCommand.proxyWriteMaxLength = peripheral.maximumWriteValueLength(for: writeType)
            activeCommand.proxyWriteLogicalPduCount = activeCommand.proxyPdus.count
            activeCommand.proxyWriteLogicalBytes = activeCommand.proxyPdus.reduce(0) { $0 + $1.count }
            activeCommand.proxyWritePdus = try activeCommand.proxyPdus.flatMap {
                try segmentProxyProtocolPdu($0, maxWriteLength: activeCommand.proxyWriteMaxLength)
            }
            activeCommand.proxyWriteSegmentLengths = activeCommand.proxyWritePdus.map(\.count)
            writeNextActivePdu()
        } catch {
            finishActive(ok: false, error: String(describing: error))
        }
    }

    func writeNextActivePdu() {
        guard let activeCommand,
              activeCommand.proxyWriteStarted,
              !activeCommand.proxyWriteCompleted else {
            return
        }
        guard activeCommand.proxyWriteIndex < activeCommand.proxyWritePdus.count else {
            completeActiveWrites()
            return
        }
        guard let peripheral = selectedPeripheral,
              let input = proxyDataInCharacteristic else {
            finishActive(ok: false, error: "Mesh Proxy Data In characteristic not ready")
            return
        }

        let data = Data(activeCommand.proxyWritePdus[activeCommand.proxyWriteIndex])
        if input.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else {
                return
            }
            activeCommand.proxyWriteType = "withoutResponse"
            peripheral.writeValue(data, for: input, type: .withoutResponse)
            activeCommand.proxyWriteIndex += 1
            activeCommand.proxyWriteSegmentsWrittenTotal += 1
            if activeCommand.proxyWriteIndex >= activeCommand.proxyWritePdus.count {
                completeActiveWrites()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.writeNextActivePdu()
                }
            }
        } else if input.properties.contains(.write) {
            activeCommand.proxyWriteType = "withResponse"
            peripheral.writeValue(data, for: input, type: .withResponse)
        } else {
            finishActive(ok: false, error: "Mesh Proxy Data In characteristic is not writable")
        }
    }

    func completeActiveWrites() {
        guard let activeCommand, !activeCommand.proxyWriteCompleted else {
            return
        }
        activeCommand.proxyWriteCompleted = true
        if activeCommand.finishAfterTelinkStatus {
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + activeCommand.settleAfterWrite
        ) { [weak self, weak activeCommand] in
            guard let self, let activeCommand, self.activeCommand === activeCommand else { return }
            self.finishActive(ok: true, error: nil)
        }
    }
}
