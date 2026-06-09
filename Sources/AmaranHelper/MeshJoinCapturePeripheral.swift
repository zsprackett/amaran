import CoreBluetooth
import Foundation

final class MeshJoinCapturePeripheral: NSObject, CBPeripheralManagerDelegate {
    let options: ProbeOptions
    let run: NativeJoinCaptureRun
    var manager: CBPeripheralManager?
    var dataOutCharacteristic: CBMutableCharacteristic?
    var session: NativeProvisioneeCaptureSession
    var reassembler = NativeProvisioningProxyPduReassembler()
    var startedAt = Date()
    var finished = false
    var centralState = "unknown"
    var advertisingStarted = false
    var serviceDataAdvertisingRequested = false
    var serviceDataAdvertisingActive = false
    var subscribedCentralCount = 0
    var receiveSegmentCount = 0
    var receivePduCount = 0
    var sentProxySegmentCount = 0
    var sentPduCount = 0
    var stateWritten = false
    var outgoingQueue: [[UInt8]] = []
    var completionPending = false
    var errorMessage: String?
    var events: [[String: Any]] = []

    init(options: ProbeOptions, run: NativeJoinCaptureRun) throws {
        self.options = options
        self.run = run
        self.session = try NativeProvisioneeCaptureSession(
            deviceKeyPair: run.deviceKeyPair,
            deviceRandom: run.deviceRandom,
            elementCount: run.elementCount
        )
        super.init()
        self.manager = CBPeripheralManager(delegate: self, queue: DispatchQueue.main)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout) { [weak self] in
            self?.handleTimeout()
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        centralState = centralStateName(peripheral.state)
        guard peripheral.state == .poweredOn else {
            if peripheral.state == .unauthorized || peripheral.state == .unsupported
                || peripheral.state == .poweredOff {
                finish(ok: false, error: "Bluetooth peripheral is \(centralState)")
            }
            return
        }

        startedAt = Date()
        let dataIn = CBMutableCharacteristic(
            type: meshProvisioningDataIn,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let dataOut = CBMutableCharacteristic(
            type: meshProvisioningDataOut,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        dataOutCharacteristic = dataOut
        let service = CBMutableService(type: meshProvisioningService, primary: true)
        service.characteristics = [dataIn, dataOut]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            finish(ok: false, error: "Mesh Provisioning service add failed: \(error.localizedDescription)")
            return
        }
        startAdvertising(includeServiceData: false)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            if serviceDataAdvertisingRequested {
                events.append([
                    "event": "advertising_service_data_rejected",
                    "fallback": "service_uuid_and_name"
                ])
                peripheral.stopAdvertising()
                startAdvertising(includeServiceData: false)
                return
            }
            finish(ok: false, error: "Mesh Provisioning advertising failed: \(error.localizedDescription)")
            return
        }
        advertisingStarted = true
        serviceDataAdvertisingActive = serviceDataAdvertisingRequested
        events.append([
            "event": "advertising_started",
            "service_data": serviceDataAdvertisingActive,
            "name": run.localName
        ])
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == meshProvisioningDataOut else {
            return
        }
        subscribedCentralCount += 1
        events.append([
            "event": "subscribed",
            "central": central.identifier.uuidString
        ])
        sendNextQueuedProxySegment()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == meshProvisioningDataOut else {
            return
        }
        subscribedCentralCount = max(0, subscribedCentralCount - 1)
        events.append([
            "event": "unsubscribed",
            "central": central.identifier.uuidString
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == meshProvisioningDataIn else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            guard request.offset == 0 else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                continue
            }
            guard let value = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            do {
                try handleIncomingProxyPdu(Array(value))
                peripheral.respond(to: request, withResult: .success)
            } catch {
                let message = String(describing: error)
                errorMessage = message
                events.append([
                    "event": "receive_error",
                    "error": message
                ])
                peripheral.respond(to: request, withResult: .unlikelyError)
                finish(ok: false, error: message)
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        sendNextQueuedProxySegment()
    }

    func startAdvertising(includeServiceData: Bool) {
        guard let manager else {
            return
        }
        serviceDataAdvertisingRequested = includeServiceData
        var advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [meshProvisioningService],
            CBAdvertisementDataLocalNameKey: run.localName
        ]
        if includeServiceData {
            advertisement[CBAdvertisementDataServiceDataKey] = [
                meshProvisioningService: Data(run.deviceUUID + [0x00, 0x00])
            ]
        }
        manager.startAdvertising(advertisement)
    }
}
