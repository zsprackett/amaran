import CoreBluetooth
import Darwin
import Foundation
import Network
import os

struct RuntimeDaemonOptions {
    let portFile: String
    let socketPath: String

    init(arguments: [String]) {
        var portFile = "\(NSHomeDirectory())/Library/Application Support/amaran-cli/daemon.json"
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--daemon-port-file", index + 1 < arguments.count {
                portFile = (arguments[index + 1] as NSString).expandingTildeInPath
                index += 2
            } else {
                index += 1
            }
        }
        self.portFile = portFile
        // The daemon listens on a Unix domain socket beside the metadata file.
        // The containing directory is created 0700, so the socket is reachable
        // only by the owner (no open localhost port).
        self.socketPath = (portFile as NSString).deletingLastPathComponent + "/daemon.sock"
    }
}

final class RuntimeDaemonCommand {
    let connection: NWConnection
    let action: String
    let proxyPdus: [[UInt8]]
    let requiredProxyNetworkId: [UInt8]
    let decodeMaterial: NativeDecodeMaterial
    let nativeSendMetadata: [String: Any]
    let finishAfterTelinkStatus: Bool
    let settleAfterWrite: TimeInterval
    let timeout: TimeInterval
    let startedAt = Date()
    var timeoutWorkItem: DispatchWorkItem?
    var proxyWritePdus: [[UInt8]] = []
    var proxyWriteStarted = false
    var proxyWriteCompleted = false
    var proxyWriteType = "none"
    var proxyWriteIndex = 0
    var proxyWriteMaxLength = 0
    var proxyWriteLogicalPduCount = 0
    var proxyWriteLogicalBytes = 0
    var proxyWriteSegmentsWrittenTotal = 0
    var proxyWriteSegmentLengths: [Int] = []
    var notificationLengths: [Int] = []
    var decodedNotifications: [[String: Any]] = []

    init(
        connection: NWConnection,
        action: String,
        proxyPdus: [[UInt8]],
        requiredProxyNetworkId: [UInt8],
        decodeMaterial: NativeDecodeMaterial,
        nativeSendMetadata: [String: Any],
        finishAfterTelinkStatus: Bool,
        settleAfterWrite: TimeInterval,
        timeout: TimeInterval
    ) {
        self.connection = connection
        self.action = action
        self.proxyPdus = proxyPdus
        self.requiredProxyNetworkId = requiredProxyNetworkId
        self.decodeMaterial = decodeMaterial
        self.nativeSendMetadata = nativeSendMetadata
        self.finishAfterTelinkStatus = finishAfterTelinkStatus
        self.settleAfterWrite = settleAfterWrite
        self.timeout = timeout
    }
}

final class MeshRuntimeDaemon: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let options: RuntimeDaemonOptions
    let listener: NWListener
    var manager: CBCentralManager?
    var centralState = "unknown"
    var selectedPeripheral: CBPeripheral?
    var connectedNetworkId: [UInt8]?
    var proxyDataInCharacteristic: CBCharacteristic?
    var proxyDataOutCharacteristic: CBCharacteristic?
    var pendingCharacteristicServices = Set<String>()
    var proxyNotificationsReady = false
    var commandQueue: [RuntimeDaemonCommand] = []
    var activeCommand: RuntimeDaemonCommand?
    var scanning = false

    init(options: RuntimeDaemonOptions) throws {
        self.options = options
        // Ensure the 0700 socket directory exists, then bind a Unix domain
        // socket listener (removing any stale socket file first).
        try FileManager.default.createDirectory(
            atPath: (options.socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(atPath: options.socketPath)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: options.socketPath)
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters)
        super.init()
        self.manager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        configureListener()
    }

    func start() {
        Log.daemon.notice(
            "daemon starting (pid \(getpid(), privacy: .public), socket \(self.options.socketPath, privacy: .public))"
        )
        listener.start(queue: .main)
    }

    private func configureListener() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.writeDaemonFile()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    private func writeDaemonFile() {
        do {
            let url = URL(fileURLWithPath: options.portFile)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Restrict the socket itself for defense in depth.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: options.socketPath)
            let payload: [String: Any] = [
                "pid": Int(getpid()),
                "socket_path": options.socketPath,
                "started_at": isoTimestamp()
            ]
            try writeJSONPayload(payload, to: options.portFile)
            Log.daemon.notice("listening on unix socket \(self.options.socketPath, privacy: .public)")
        } catch {
            Log.daemon.error("failed to write daemon metadata file: \(error.localizedDescription, privacy: .public)")
            fputs("failed to write daemon metadata file: \(error.localizedDescription)\n", stderr)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.sendError("daemon request read failed: \(error.localizedDescription)", connection: connection)
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if let newline = nextBuffer.firstIndex(of: 0x0a) {
                let requestData = nextBuffer[..<newline]
                self.handleRequestData(Data(requestData), connection: connection)
                return
            }
            if isComplete {
                self.handleRequestData(nextBuffer, connection: connection)
                return
            }
            self.receive(connection: connection, buffer: nextBuffer)
        }
    }

    private func handleRequestData(_ data: Data, connection: NWConnection) {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AmaranHelperError.invalidState("daemon request must be a JSON object")
            }
            try handleRequest(request, connection: connection)
        } catch {
            sendError(String(describing: error), connection: connection)
        }
    }

    private func handleRequest(_ request: [String: Any], connection: NWConnection) throws {
        let action = jsonString(request["action"]) ?? ""
        Log.command.debug("request received: action=\(action, privacy: .public)")
        switch action {
        case "ping":
            sendPayload([
                "ok": true,
                "data": [
                    "daemon": daemonSummary(),
                    "central_state": centralState,
                    "connected": selectedPeripheral?.state == .connected
                ]
            ], connection: connection)
        case "shutdown":
            handleShutdown(connection: connection)
        case "control", "control_sequence", "status":
            let command = try makeCommand(action: action, request: request, connection: connection)
            commandQueue.append(command)
            processQueue()
        default:
            throw AmaranHelperError.invalidState("unknown daemon action: \(action)")
        }
    }

    private func handleShutdown(connection: NWConnection) {
        Log.daemon.notice("shutdown requested")
        sendPayload(["ok": true, "data": ["daemon": daemonSummary(), "shutdown": true]], connection: connection)
        listener.cancel()
        try? FileManager.default.removeItem(atPath: options.portFile)
        try? FileManager.default.removeItem(atPath: options.socketPath)
        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func sendError(_ error: String, connection: NWConnection) {
        sendPayload([
            "ok": false,
            "error": error,
            "data": [
                "central_state": centralState,
                "daemon": daemonSummary()
            ]
        ], connection: connection)
    }

    func sendPayload(_ payload: [String: Any], connection: NWConnection) {
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            data.append(0x0a)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }

    func daemonSummary() -> [String: Any] {
        [
            "pid": Int(getpid()),
            "port_file": options.portFile,
            "selected_peripheral_id": selectedPeripheral?.identifier.uuidString ?? NSNull()
        ]
    }
}
