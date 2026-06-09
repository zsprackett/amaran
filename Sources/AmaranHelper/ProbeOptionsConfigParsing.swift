import Foundation

extension ProbeOptions {
    func parseConfigFlags(arguments: [String], at index: Int) -> Int? {
        switch arguments[index] {
        case "--config-composition-get-test":
            parseConfigCompositionGet()
            return index + 1
        case "--config-appkey-get-test":
            parseConfigAppKeyGet()
            return index + 1
        case "--config-appkey-add-test":
            parseConfigAppKeyAdd()
            return index + 1
        case "--config-model-app-bind-test":
            parseConfigModelAppBind()
            return index + 1
        case "--config-node-reset-test":
            parseConfigNodeReset()
            return index + 1
        default:
            return nil
        }
    }

    private func parseConfigCompositionGet() {
        do {
            let prepared = try reserveNativeConfigCompositionGetProxyPdu(statePath: statePath, nodeID: nodeID)
            applyPrepared(prepared, label: "config-composition-data-get")
            storeConfigCompositionData = true
            settleAfterWrite = max(settleAfterWrite, 4.0)
        } catch {
            configurationError = String(describing: error)
        }
    }

    private func parseConfigAppKeyGet() {
        do {
            let prepared = try reserveNativeConfigAppKeyGetProxyPdu(statePath: statePath, nodeID: nodeID)
            applyPrepared(prepared, label: "config-appkey-get")
            settleAfterWrite = max(settleAfterWrite, 2.0)
        } catch {
            configurationError = String(describing: error)
        }
    }

    private func parseConfigAppKeyAdd() {
        do {
            let prepared = try reserveNativeConfigAppKeyAddProxyPdus(statePath: statePath, nodeID: nodeID)
            applyPreparedSequence(prepared, label: "config-appkey-add")
            expectedSegmentAckSeqZero = prepared.expectedSegmentAckSeqZero
            expectedSegmentAckSegN = prepared.expectedSegmentAckSegN
            proxyWriteInterSegmentDelay = max(proxyWriteInterSegmentDelay, 0.25)
            settleAfterWrite = max(settleAfterWrite, 2.0)
        } catch {
            configurationError = String(describing: error)
        }
    }

    private func parseConfigModelAppBind() {
        do {
            let prepared = try reserveNativeConfigModelAppBindProxyPdu(statePath: statePath, nodeID: nodeID)
            applyPrepared(prepared, label: "config-model-app-bind")
        } catch {
            configurationError = String(describing: error)
        }
    }

    private func parseConfigNodeReset() {
        guard confirmReset else {
            configurationError = "--config-node-reset-test requires --confirm-reset"
            return
        }
        do {
            let prepared = try reserveNativeConfigNodeResetProxyPdu(statePath: statePath, nodeID: nodeID)
            applyPrepared(prepared, label: "config-node-reset")
            settleAfterWrite = max(settleAfterWrite, 4.0)
        } catch {
            configurationError = String(describing: error)
        }
    }
}
