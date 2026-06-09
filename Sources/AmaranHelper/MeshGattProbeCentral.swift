import CoreBluetooth
import Foundation

extension MeshGattProbe {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = centralStateName(central.state)
        guard central.state == .poweredOn else {
            finish(ok: central.state != .unauthorized && central.state != .unsupported, error: nil)
            return
        }

        startedAt = Date()
        central.scanForPeripherals(
            withServices: options.scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout) { [weak self] in
            self?.handleTimeout()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let networkMatches = proxyNetworkMatches(advertisementData: advertisementData)
        record(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: RSSI,
            proxyNetworkMatches: networkMatches
        )

        guard options.connect, selectedPeripheral == nil else {
            return
        }
        if let connectService = options.connectService,
            !advertisementIncludesService(advertisementData, uuid: connectService) {
            return
        }
        guard networkMatches else {
            return
        }
        if options.nativeProvisioningRun != nil {
            liveProvisioningDeviceUUID = provisioningDeviceUUID(advertisementData: advertisementData)
        }

        selectedPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        updateDiscovery(peripheral) { entry in
            entry["connected"] = true
        }
        peripheral.discoverServices(options.discoverAllServices ? nil : [meshProxyService, meshProvisioningService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        updateDiscovery(peripheral) { entry in
            entry["connect_error"] = error?.localizedDescription ?? "connect failed"
        }
        finish(ok: true, error: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        updateDiscovery(peripheral) { entry in
            entry["connected"] = false
            if let error {
                entry["disconnect_error"] = error.localizedDescription
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            updateDiscovery(peripheral) { entry in
                entry["service_error"] = error.localizedDescription
            }
            finish(ok: true, error: nil)
            return
        }

        let services = peripheral.services ?? []
        if services.isEmpty {
            finish(ok: true, error: nil)
            return
        }

        pendingCharacteristicServices = Set(services.map { cbuuidString($0.uuid) })
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let serviceID = cbuuidString(service.uuid)
        updateDiscovery(peripheral) { entry in
            var services = entry["services"] as? [[String: Any]] ?? []
            var serviceEntry: [String: Any] = [
                "uuid": serviceID,
                "role": meshRole(serviceUUIDs: [serviceID])
            ]
            if let error {
                serviceEntry["error"] = error.localizedDescription
            } else {
                serviceEntry["characteristics"] = (service.characteristics ?? []).map { characteristic in
                    if characteristic.uuid == options.writeDataInUUID {
                        proxyDataInCharacteristic = characteristic
                    } else if characteristic.uuid == options.writeDataOutUUID {
                        proxyDataOutCharacteristic = characteristic
                    }
                    var characteristicEntry: [String: Any] = [
                        "uuid": cbuuidString(characteristic.uuid),
                        "properties": characteristicProperties(characteristic.properties),
                        "role": characteristicRole(characteristic.uuid)
                    ]
                    if options.readCharacteristics && characteristic.properties.contains(.read) {
                        pendingCharacteristicReads.insert(
                            characteristicKey(service: service, characteristic: characteristic)
                        )
                        characteristicEntry["read_pending"] = true
                    }
                    return characteristicEntry
                }
            }
            services.removeAll { ($0["uuid"] as? String) == serviceID }
            services.append(serviceEntry)
            entry["services"] = services.sorted { lhs, rhs in
                (lhs["uuid"] as? String ?? "") < (rhs["uuid"] as? String ?? "")
            }
        }

        if options.readCharacteristics {
            for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }

        pendingCharacteristicServices.remove(serviceID)
        continueAfterDiscoveryIfReady(peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == options.writeDataOutUUID else {
            return
        }
        if let error {
            finish(
                ok: false,
                error: "\(writeDataOutLabel()) notification subscribe failed: \(error.localizedDescription)"
            )
            return
        }
        if options.nativeProvisioningRun != nil {
            startLiveProvisioning(peripheral)
        } else if options.monitorDuration != nil {
            startMonitor(peripheral)
        } else {
            writeProxyPdus(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == options.writeDataInUUID else {
            return
        }
        if options.nativeProvisioningRun != nil {
            handleLiveProvisioningWriteResponse(peripheral, error: error)
            return
        }
        if let error {
            finish(ok: false, error: "\(writeDataInLabel()) write failed: \(error.localizedDescription)")
            return
        }
        proxyWriteIndex += 1
        proxyWriteSegmentsWrittenTotal += 1
        if proxyWriteIndex >= proxyWritePdus.count {
            completeProxyWriteOrWaitForAck()
        } else {
            writeNextProxyPdu(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let readKey = characteristicKey(characteristic: characteristic)
        if pendingCharacteristicReads.contains(readKey) {
            updateReadValue(peripheral: peripheral, characteristic: characteristic, error: error)
            pendingCharacteristicReads.remove(readKey)
            continueAfterDiscoveryIfReady(peripheral)
            return
        }

        guard characteristic.uuid == options.writeDataOutUUID else {
            return
        }
        if error == nil, let value = characteristic.value {
            notificationLengths.append(value.count)
            let proxyPdu = Array(value)
            let decoded = options.nativeProvisioningRun != nil
                ? handleLiveProvisioningNotification(proxyPdu, peripheral: peripheral)
                : decodeProxyNotification(proxyPdu, peripheral: peripheral)
            decodedNotifications.append(decoded)
            handleSegmentAcknowledgment(decoded)
            if options.finishAfterTelinkStatus && isTelinkCCTStatus(decoded) {
                finish(ok: true, error: nil)
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if options.nativeProvisioningRun != nil && liveProvisioningWriting {
            writeNextLiveProvisioningProxyPdu(peripheral)
            return
        }
        if options.hasProxyWrite && proxyWriteStarted && !proxyWriteCompleted {
            writeNextProxyPdu(peripheral)
        }
    }

    func characteristicRole(_ uuid: CBUUID) -> String {
        switch cbuuidString(uuid) {
        case cbuuidString(meshProxyDataIn): return "proxyDataIn"
        case cbuuidString(meshProxyDataOut): return "proxyDataOut"
        case cbuuidString(meshProvisioningDataIn): return "provisioningDataIn"
        case cbuuidString(meshProvisioningDataOut): return "provisioningDataOut"
        default: return "unknown"
        }
    }

    func characteristicKey(service: CBService, characteristic: CBCharacteristic) -> String {
        "\(cbuuidString(service.uuid))/\(cbuuidString(characteristic.uuid))"
    }

    func characteristicKey(characteristic: CBCharacteristic) -> String {
        guard let service = characteristic.service else {
            return "unknown/\(cbuuidString(characteristic.uuid))"
        }
        return characteristicKey(service: service, characteristic: characteristic)
    }

    func isTelinkCCTStatus(_ decoded: [String: Any]) -> Bool {
        guard let access = decoded["access"] as? [String: Any],
              let telink = access["telink"] as? [String: Any] else {
            return false
        }
        return telink["cct"] != nil
    }

    func updateReadValue(peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard let service = characteristic.service else {
            return
        }
        let serviceID = cbuuidString(service.uuid)
        let characteristicID = cbuuidString(characteristic.uuid)

        updateDiscovery(peripheral) { entry in
            var services = entry["services"] as? [[String: Any]] ?? []
            guard let serviceIndex = services.firstIndex(where: { ($0["uuid"] as? String) == serviceID }) else {
                return
            }

            var serviceEntry = services[serviceIndex]
            var characteristics = serviceEntry["characteristics"] as? [[String: Any]] ?? []
            guard let characteristicIndex = characteristics.firstIndex(where: {
                ($0["uuid"] as? String) == characteristicID
            }) else {
                return
            }

            var characteristicEntry = characteristics[characteristicIndex]
            characteristicEntry.removeValue(forKey: "read_pending")
            if let error {
                characteristicEntry["read_error"] = error.localizedDescription
            } else {
                let bytes = Array(characteristic.value ?? Data())
                characteristicEntry["read"] = [
                    "length": bytes.count,
                    "hex": NativeMeshCrypto.hex(bytes)
                ]
            }
            characteristics[characteristicIndex] = characteristicEntry
            serviceEntry["characteristics"] = characteristics
            services[serviceIndex] = serviceEntry
            entry["services"] = services.sorted { lhs, rhs in
                (lhs["uuid"] as? String ?? "") < (rhs["uuid"] as? String ?? "")
            }
        }
    }

    func continueAfterDiscoveryIfReady(_ peripheral: CBPeripheral) {
        guard pendingCharacteristicServices.isEmpty && pendingCharacteristicReads.isEmpty else {
            return
        }
        if options.nativeProvisioningRun != nil {
            startLiveProvisioningIfReady(peripheral)
        } else if options.monitorDuration != nil {
            startMonitorIfReady(peripheral)
        } else if options.hasProxyWrite {
            startProxyWriteIfReady(peripheral)
        } else {
            finish(ok: true, error: nil)
        }
    }

    func proxyNetworkMatches(advertisementData: [String: Any]) -> Bool {
        guard let requiredNetworkId = options.requiredProxyNetworkId else {
            return true
        }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        guard let proxyData = serviceData[meshProxyService] else {
            return false
        }
        let bytes = Array(proxyData)
        return bytes.count == 9 && bytes[0] == 0x00 && Array(bytes[1...]) == requiredNetworkId
    }

    func advertisementIncludesService(_ advertisementData: [String: Any], uuid: CBUUID) -> Bool {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertisedServices.contains(uuid) {
            return true
        }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return serviceData[uuid] != nil
    }

    func provisioningDeviceUUID(advertisementData: [String: Any]) -> [UInt8]? {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        guard let provisioningData = serviceData[meshProvisioningService] else {
            return nil
        }
        let bytes = Array(provisioningData)
        guard bytes.count >= 18 else {
            return nil
        }
        return Array(bytes[0..<16])
    }
}
