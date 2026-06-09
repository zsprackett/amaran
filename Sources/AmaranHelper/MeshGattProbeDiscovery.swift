import CoreBluetooth
import Foundation

extension MeshGattProbe {
    func record(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber,
        proxyNetworkMatches: Bool
    ) {
        updateDiscovery(peripheral) { entry in
            let advertisedServices = Set(
                (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(cbuuidString)
                    + (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
                        .keys.map(cbuuidString)
            ).sorted()
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
            let serviceDataLengths = serviceData.reduce(into: [String: Int]()) { result, item in
                result[cbuuidString(item.key)] = item.value.count
            }

            entry["id"] = peripheral.identifier.uuidString
            entry["name"] = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? NSNull()
            entry["rssi"] = rssi.intValue
            entry["advertised_services"] = advertisedServices
            entry["mesh_roles"] = meshRole(serviceUUIDs: advertisedServices)
            entry["connectable"] = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? NSNull()
            entry["manufacturer_data_length"] =
                (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.count ?? 0
            entry["service_data_lengths"] = serviceDataLengths
            if let provisioningData = serviceData[meshProvisioningService] {
                entry["provisioning"] = NativeMeshProvisioning.provisioningServiceDataSummary(Array(provisioningData))
            }
            if options.requiredProxyNetworkId != nil {
                entry["proxy_network_match"] = proxyNetworkMatches
            }
        }
        captureAdvertisement(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: rssi,
            proxyNetworkMatches: proxyNetworkMatches
        )
    }

    func captureAdvertisement(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber,
        proxyNetworkMatches: Bool
    ) {
        guard options.advertisementCapturePath != nil else {
            return
        }

        let advertisedServices = Set(
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(cbuuidString)
                + (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
                    .keys.map(cbuuidString)
        ).sorted()
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        var serviceDataHex: [String: String] = [:]
        for (uuid, data) in serviceData {
            serviceDataHex[cbuuidString(uuid)] = NativeMeshCrypto.hex(Array(data))
        }
        let advertisedName: Any
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            advertisedName = localName
        } else if let peripheralName = peripheral.name {
            advertisedName = peripheralName
        } else {
            advertisedName = NSNull()
        }

        var capture: [String: Any] = [
            "id": peripheral.identifier.uuidString,
            "name": advertisedName,
            "rssi": rssi.intValue,
            "advertised_services": advertisedServices,
            "mesh_roles": meshRole(serviceUUIDs: advertisedServices),
            "connectable": advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? NSNull(),
            "service_data_hex": serviceDataHex,
            "captured_at": isoTimestamp()
        ]

        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            capture["manufacturer_data_hex"] = NativeMeshCrypto.hex(Array(manufacturerData))
            capture["manufacturer_data_length"] = manufacturerData.count
        } else {
            capture["manufacturer_data_length"] = 0
        }
        if let provisioningData = serviceData[meshProvisioningService] {
            capture["provisioning"] = NativeMeshProvisioning.provisioningServiceDataSummary(Array(provisioningData))
        }
        if options.requiredProxyNetworkId != nil {
            capture["proxy_network_match"] = proxyNetworkMatches
        }

        advertisementCapturesByPeripheralID[peripheral.identifier.uuidString] = capture
    }

    func startProxyWriteIfReady(_ peripheral: CBPeripheral) {
        guard !proxyWriteStarted else {
            return
        }
        guard proxyDataInCharacteristic != nil else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) not found"
            )
            return
        }
        guard let out = proxyDataOutCharacteristic else {
            writeProxyPdus(peripheral)
            return
        }

        if out.properties.contains(.notify) || out.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: out)
        } else {
            writeProxyPdus(peripheral)
        }
    }

    func startMonitorIfReady(_ peripheral: CBPeripheral) {
        guard !options.monitorStarted else {
            return
        }
        guard proxyDataInCharacteristic != nil else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) not found"
            )
            return
        }
        guard let out = proxyDataOutCharacteristic else {
            finish(
                ok: false,
                error: "\(writeDataOutLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataOutUUID)) not found"
            )
            return
        }

        if out.properties.contains(.notify) || out.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: out)
        } else {
            finish(
                ok: false,
                error: "\(writeDataOutLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataOutUUID)) is not notifiable"
            )
        }
    }

    func startMonitor(_ peripheral: CBPeripheral) {
        guard !options.monitorStarted else {
            return
        }
        if let filterProxyPdu = options.monitorFilterProxyPdu, !options.monitorFilterWritten {
            guard let input = proxyDataInCharacteristic else {
                finish(
                    ok: false,
                    error: "\(writeDataInLabel()) characteristic "
                        + "\(cbuuidString(options.writeDataInUUID)) not found"
                )
                return
            }
            guard input.properties.contains(.writeWithoutResponse) else {
                finish(ok: false, error: "\(writeDataInLabel()) characteristic does not support writeWithoutResponse")
                return
            }
            peripheral.writeValue(Data(filterProxyPdu), for: input, type: .withoutResponse)
            options.monitorFilterWritten = true
        }
        options.monitorStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (options.monitorDuration ?? options.timeout)) { [weak self] in
            self?.finish(ok: true, error: nil)
        }
    }

    func startLiveProvisioningIfReady(_ peripheral: CBPeripheral) {
        guard !liveProvisioningStarted else {
            return
        }
        guard proxyDataInCharacteristic != nil else {
            finish(
                ok: false,
                error: "\(writeDataInLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataInUUID)) not found"
            )
            return
        }
        guard let out = proxyDataOutCharacteristic else {
            finish(
                ok: false,
                error: "\(writeDataOutLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataOutUUID)) not found"
            )
            return
        }

        if out.properties.contains(.notify) || out.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: out)
        } else {
            finish(
                ok: false,
                error: "\(writeDataOutLabel()) characteristic "
                    + "\(cbuuidString(options.writeDataOutUUID)) is not notifiable"
            )
        }
    }

    func updateDiscovery(_ peripheral: CBPeripheral, mutate: (inout [String: Any]) -> Void) {
        let key = peripheral.identifier.uuidString
        var entry = discoveries[key] ?? [
            "id": key,
            "name": peripheral.name ?? NSNull(),
            "connected": false
        ]
        mutate(&entry)
        discoveries[key] = entry
    }
}
