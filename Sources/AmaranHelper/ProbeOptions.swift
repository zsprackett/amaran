import CoreBluetooth
import Foundation

final class ProbeOptions {
    var outputPath = "/tmp/amaran-helper.json"
    var timeout: TimeInterval = 10
    var connect = true
    var scanServices = [meshProxyService, meshProvisioningService]
    var connectService: CBUUID?
    var proxyPdu: [UInt8]?
    var proxyPdus: [[UInt8]] = []
    var proxyPduLabel = "custom"
    var writeDataInUUID = meshProxyDataIn
    var writeDataOutUUID = meshProxyDataOut
    var requiredProxyNetworkId: [UInt8]?
    var decodeMaterial: NativeDecodeMaterial?
    var nativeSendMetadata: [String: Any]?
    var nativeProvisioningRun: NativeProvisioningRun?
    var nativeJoinCaptureRun: NativeJoinCaptureRun?
    var nodeID: String?
    var statePath = defaultStatePath()
    var settleAfterWrite: TimeInterval = 1.0
    var proxyWriteInterSegmentDelay: TimeInterval = 0.03
    var proxyWritePauseEvery = 0
    var proxyWritePauseDuration: TimeInterval = 0.0
    var expectedSegmentAckSeqZero: UInt16?
    var expectedSegmentAckSegN: UInt8?
    var segmentAckMaxSendAttempts = 4
    var segmentAckRetryDelay: TimeInterval = 0.75
    var finishAfterTelinkStatus = false
    var storeConfigCompositionData = false
    var monitorDuration: TimeInterval?
    var monitorStarted = false
    var monitorFilterProxyPdu: [UInt8]?
    var monitorFilterWritten = false
    var includeRawAccess = false
    var confirmReset = false
    var advertisementCapturePath: String?
    var discoverAllServices = false
    var readCharacteristics = false
    var configurationError: String?

    /// Mutable scratch state accumulated while parsing join-capture flags. The
    /// run object is constructed once parsing completes.
    struct JoinCaptureRequest {
        var requested = false
        var path: String?
        var name = "amaran 60x S"
        var deviceUUID: [UInt8]?
    }

    init(arguments: [String]) {
        confirmReset = arguments.contains("--confirm-reset")
        let addToExistingState = arguments.contains("--add-to-existing-state")
        var joinCapture = JoinCaptureRequest()
        var index = 1
        while index < arguments.count {
            index = parse(
                arguments: arguments,
                at: index,
                addToExistingState: addToExistingState,
                joinCapture: &joinCapture
            )
        }

        if let advertisementCapturePath, FileManager.default.fileExists(atPath: advertisementCapturePath) {
            configurationError = "advertisement capture file already exists at \(advertisementCapturePath)"
        }

        if joinCapture.requested, configurationError == nil {
            configureJoinCapture(joinCapture)
        }
    }

    var hasProxyWrite: Bool {
        proxyPdu != nil || !proxyPdus.isEmpty
    }

    func configuredProxyPdus() -> [[UInt8]] {
        if !proxyPdus.isEmpty {
            return proxyPdus
        }
        if let proxyPdu {
            return [proxyPdu]
        }
        return []
    }

    /// Applies a single prepared Proxy PDU reservation to the option state.
    func applyPrepared(_ prepared: NativePreparedProxyPdu, label: String) {
        proxyPdu = prepared.proxyPdu
        proxyPduLabel = label
        requiredProxyNetworkId = prepared.requiredProxyNetworkId
        decodeMaterial = prepared.decodeMaterial
        nativeSendMetadata = prepared.metadata
        connect = true
    }

    /// Applies a prepared Proxy PDU sequence reservation to the option state.
    func applyPreparedSequence(_ prepared: NativePreparedProxyPduSequence, label: String) {
        proxyPdus = prepared.proxyPdus
        proxyPduLabel = label
        requiredProxyNetworkId = prepared.requiredProxyNetworkId
        decodeMaterial = prepared.decodeMaterial
        nativeSendMetadata = prepared.metadata
        connect = true
    }

    private func configureJoinCapture(_ joinCapture: JoinCaptureRequest) {
        do {
            guard let path = joinCapture.path, !path.isEmpty else {
                throw AmaranHelperError.invalidState("--join-capture requires --capture-state <file>")
            }
            let deviceUUID: [UInt8]
            if let captured = joinCapture.deviceUUID {
                deviceUUID = captured
            } else {
                deviceUUID = try NativeMeshProvisioning.generateProvisioningRandom()
            }
            nativeJoinCaptureRun = NativeJoinCaptureRun(
                captureStatePath: path,
                localName: joinCapture.name,
                deviceUUID: deviceUUID,
                elementCount: 1,
                deviceKeyPair: try NativeMeshProvisioning.generateProvisionerKeyPair(),
                deviceRandom: try NativeMeshProvisioning.generateProvisioningRandom()
            )
        } catch {
            configurationError = String(describing: error)
        }
    }
}
