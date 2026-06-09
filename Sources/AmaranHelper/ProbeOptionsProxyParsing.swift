import CoreBluetooth
import Foundation

extension ProbeOptions {
    func parseProxyFlags(arguments: [String], at index: Int) -> Int? {
        if let next = parseProxyPduFlags(arguments: arguments, at: index) {
            return next
        }
        return parseProxyCommandFlags(arguments: arguments, at: index)
    }

    private func parseProxyPduFlags(arguments: [String], at index: Int) -> Int? {
        switch arguments[index] {
        case "--proxy-state-probe":
            parseProxyStateProbe()
            return index + 1
        case "--proxy-test":
            do {
                proxyPdu = try bytes(hex: publicSampleProxyPduHex)
                proxyPduLabel = "public-sample-network-pdu"
                connect = true
            } catch {
                fputs("invalid built-in proxy test PDU: \(error)\n", stderr)
            }
            return index + 1
        case "--proxy-pdu":
            guard index + 1 < arguments.count else {
                return index + 1
            }
            do {
                proxyPdu = try bytes(hex: arguments[index + 1])
                proxyPduLabel = "custom"
                connect = true
            } catch {
                fputs("\(error)\n", stderr)
            }
            return index + 2
        case "--monitor":
            parseMonitor()
            return index + 1
        default:
            return nil
        }
    }

    private func parseProxyCommandFlags(arguments: [String], at index: Int) -> Int? {
        switch arguments[index] {
        case "--sig-onoff-test":
            return parseSigOnOffTest(arguments: arguments, at: index)
        case "--control-test":
            return parseControlTest(arguments: arguments, at: index)
        case "--control-sequence":
            return parseControlSequence(arguments: arguments, at: index)
        case "--status-test":
            parseStatusTest()
            return index + 1
        case "--status-batch":
            return parseStatusBatch(arguments: arguments, at: index)
        default:
            return nil
        }
    }

    private func parseProxyStateProbe() {
        do {
            let prepared = try prepareNativeProxyStateProbe(statePath: statePath, nodeID: nodeID)
            requiredProxyNetworkId = prepared.requiredProxyNetworkId
            nativeSendMetadata = prepared.metadata
            scanServices = [meshProxyService]
            connectService = meshProxyService
            connect = true
        } catch {
            configurationError = String(describing: error)
        }
    }

    private func parseMonitor() {
        do {
            let prepared = try prepareNativeMeshMonitor(statePath: statePath, nodeID: nodeID)
            requiredProxyNetworkId = prepared.requiredProxyNetworkId
            decodeMaterial = prepared.decodeMaterial
            nativeSendMetadata = prepared.metadata
            monitorFilterProxyPdu = prepared.filterProxyPdu
            scanServices = [meshProxyService]
            connectService = meshProxyService
            monitorDuration = timeout
            includeRawAccess = true
            connect = true
        } catch {
            configurationError = String(describing: error)
        }
    }

    private func parseSigOnOffTest(arguments: [String], at index: Int) -> Int {
        guard index + 1 < arguments.count else {
            configurationError = "--sig-onoff-test requires on or off"
            return index + 1
        }
        let value = arguments[index + 1].lowercased()
        guard value == "on" || value == "off" else {
            configurationError = "--sig-onoff-test must be on or off"
            return index + 2
        }
        do {
            let prepared = try reserveNativeSigOnOffProxyPdu(
                statePath: statePath,
                nodeID: nodeID,
                turnOn: value == "on"
            )
            applyPrepared(prepared, label: "generic-onoff-set-unack")
        } catch {
            configurationError = String(describing: error)
        }
        return index + 2
    }

    private func parseControlTest(arguments: [String], at index: Int) -> Int {
        guard index + 1 < arguments.count else {
            configurationError = "--control-test requires a command spec"
            return index + 1
        }
        do {
            let command = try NativeTelinkControlCommand.parse(spec: arguments[index + 1].lowercased())
            let prepared = try reserveNativeControlProxyPdu(statePath: statePath, nodeID: nodeID, command: command)
            applyPrepared(prepared, label: "telink-0x26-control")
            settleAfterWrite = 0.2
        } catch {
            configurationError = String(describing: error)
        }
        return index + 2
    }

    private func parseControlSequence(arguments: [String], at index: Int) -> Int {
        guard index + 1 < arguments.count else {
            configurationError = "--control-sequence requires a comma-separated command spec list"
            return index + 1
        }
        do {
            let specs = arguments[index + 1]
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).lowercased() }
            let commands = try specs.map { try NativeTelinkControlCommand.parse(spec: $0) }
            let prepared = try reserveNativeControlProxyPdus(
                statePath: statePath,
                nodeID: nodeID,
                commands: commands
            )
            applyPreparedSequence(prepared, label: "telink-0x26-control-sequence")
            proxyWriteInterSegmentDelay = max(proxyWriteInterSegmentDelay, 0.25)
            settleAfterWrite = 0.2
        } catch {
            configurationError = String(describing: error)
        }
        return index + 2
    }

    private func parseStatusTest() {
        do {
            let prepared = try reserveNativeStatusProxyPdu(statePath: statePath, nodeID: nodeID)
            applyPrepared(prepared, label: "telink-0x26-status")
            finishAfterTelinkStatus = true
            settleAfterWrite = max(settleAfterWrite, 2.0)
        } catch {
            configurationError = String(describing: error)
        }
    }

    private func parseStatusBatch(arguments: [String], at index: Int) -> Int {
        guard index + 1 < arguments.count else {
            configurationError = "--status-batch requires a comma-separated address list"
            return index + 1
        }
        do {
            let addresses = try parseUnicastAddressList(arguments[index + 1])
            let prepared = try reserveNativeStatusProxyPdus(statePath: statePath, addresses: addresses)
            applyPreparedSequence(prepared, label: "telink-0x26-status-batch")
            proxyWriteInterSegmentDelay = max(proxyWriteInterSegmentDelay, 0.05)
            proxyWritePauseEvery = 8
            proxyWritePauseDuration = 0.6
            settleAfterWrite = max(settleAfterWrite, 2.0)
        } catch {
            configurationError = String(describing: error)
        }
        return index + 2
    }
}
