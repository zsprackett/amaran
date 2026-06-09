import CoreBluetooth
import Foundation
import Network

extension MeshRuntimeDaemon {
    func makeCommand(
        action: String,
        request: [String: Any],
        connection: NWConnection
    ) throws -> RuntimeDaemonCommand {
        guard let statePath = jsonString(request["state_path"]), !statePath.isEmpty else {
            throw AmaranHelperError.invalidState("daemon request missing state_path")
        }
        let nodeID = jsonString(request["node_id"])
        let timeout = max(1.0, (request["timeout"] as? NSNumber)?.doubleValue ?? 10.0)

        switch action {
        case "control":
            return try makeControlCommand(
                request: request, statePath: statePath, nodeID: nodeID, timeout: timeout, connection: connection
            )
        case "control_sequence":
            return try makeControlSequenceCommand(
                request: request, statePath: statePath, nodeID: nodeID, timeout: timeout, connection: connection
            )
        case "status":
            let prepared = try reserveNativeStatusProxyPdu(statePath: statePath, nodeID: nodeID)
            return RuntimeDaemonCommand(
                connection: connection,
                action: action,
                proxyPdus: [prepared.proxyPdu],
                requiredProxyNetworkId: prepared.requiredProxyNetworkId,
                decodeMaterial: prepared.decodeMaterial,
                nativeSendMetadata: prepared.metadata,
                finishAfterTelinkStatus: true,
                settleAfterWrite: 0.0,
                timeout: timeout
            )
        default:
            throw AmaranHelperError.invalidState("unsupported runtime daemon command: \(action)")
        }
    }

    private func makeControlCommand(
        request: [String: Any],
        statePath: String,
        nodeID: String?,
        timeout: TimeInterval,
        connection: NWConnection
    ) throws -> RuntimeDaemonCommand {
        guard let spec = jsonString(request["spec"]) else {
            throw AmaranHelperError.invalidState("control request missing spec")
        }
        let prepared = try reserveNativeControlProxyPdu(
            statePath: statePath,
            nodeID: nodeID,
            command: try NativeTelinkControlCommand.parse(spec: spec.lowercased())
        )
        return RuntimeDaemonCommand(
            connection: connection,
            action: "control",
            proxyPdus: [prepared.proxyPdu],
            requiredProxyNetworkId: prepared.requiredProxyNetworkId,
            decodeMaterial: prepared.decodeMaterial,
            nativeSendMetadata: prepared.metadata,
            finishAfterTelinkStatus: false,
            settleAfterWrite: 0.05,
            timeout: timeout
        )
    }

    private func makeControlSequenceCommand(
        request: [String: Any],
        statePath: String,
        nodeID: String?,
        timeout: TimeInterval,
        connection: NWConnection
    ) throws -> RuntimeDaemonCommand {
        guard let specs = request["specs"] as? [String], !specs.isEmpty else {
            throw AmaranHelperError.invalidState("control_sequence request missing specs")
        }
        let commands = try specs.map { try NativeTelinkControlCommand.parse(spec: $0.lowercased()) }
        let prepared = try reserveNativeControlProxyPdus(statePath: statePath, nodeID: nodeID, commands: commands)
        return RuntimeDaemonCommand(
            connection: connection,
            action: "control_sequence",
            proxyPdus: prepared.proxyPdus,
            requiredProxyNetworkId: prepared.requiredProxyNetworkId,
            decodeMaterial: prepared.decodeMaterial,
            nativeSendMetadata: prepared.metadata,
            finishAfterTelinkStatus: false,
            settleAfterWrite: 0.1,
            timeout: timeout
        )
    }

    func processQueue() {
        guard activeCommand == nil, !commandQueue.isEmpty else {
            return
        }
        guard centralState == "poweredOn" else {
            if centralState == "unknown" || centralState == "resetting" {
                return
            }
            let command = commandQueue.removeFirst()
            sendError("Bluetooth is \(centralState)", connection: command.connection)
            processQueue()
            return
        }

        let command = commandQueue.removeFirst()
        activeCommand = command
        let timeoutWork = DispatchWorkItem { [weak self, weak command] in
            guard let self, let command, self.activeCommand === command else { return }
            self.finishActive(ok: false, error: "runtime command timed out")
        }
        command.timeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + command.timeout, execute: timeoutWork)

        if selectedPeripheral?.state == .connected,
           connectedNetworkId == command.requiredProxyNetworkId,
           proxyDataInCharacteristic != nil {
            startActiveWriteWhenReady()
        } else {
            reconnectForActiveCommand()
        }
    }

    func reconnectForActiveCommand() {
        if let selectedPeripheral, selectedPeripheral.state == .connected {
            manager?.cancelPeripheralConnection(selectedPeripheral)
        }
        selectedPeripheral = nil
        connectedNetworkId = nil
        proxyDataInCharacteristic = nil
        proxyDataOutCharacteristic = nil
        proxyNotificationsReady = false
        pendingCharacteristicServices.removeAll()
        startScanForActiveCommand()
    }

    func startScanForActiveCommand() {
        guard !scanning, activeCommand != nil, centralState == "poweredOn" else {
            return
        }
        scanning = true
        manager?.scanForPeripherals(
            withServices: [meshProxyService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
}
