import CoreBluetooth
import Foundation

final class MeshGattProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let options: ProbeOptions
    var manager: CBCentralManager?
    var selectedPeripheral: CBPeripheral?
    var pendingCharacteristicServices = Set<String>()
    var pendingCharacteristicReads = Set<String>()
    var discoveries: [String: [String: Any]] = [:]
    var centralState = "unknown"
    var startedAt = Date()
    var finished = false
    var proxyDataInCharacteristic: CBCharacteristic?
    var proxyDataOutCharacteristic: CBCharacteristic?
    var proxyWriteStarted = false
    var proxyWriteCompleted = false
    var proxyWriteType = "none"
    var proxyWriteIndex = 0
    var proxyWritePdus: [[UInt8]] = []
    var proxyWriteMaxLength = 0
    var proxyWriteLogicalPduCount = 0
    var proxyWriteLogicalBytes = 0
    var proxyWriteSegmentsWrittenTotal = 0
    var proxyWriteSegmentLengths: [Int] = []
    var outboundSegmentAckSummaries: [[String: Any]] = []
    var notificationLengths: [Int] = []
    var decodedNotifications: [[String: Any]] = []
    var segmentedAccessReassemblies: [String: IncomingSegmentedAccessAccumulator] = [:]
    var completedSegmentedAccessKeys = Set<String>()
    var storedCompositionDataSummary: [String: Any]?
    var segmentAckComplete = false
    var segmentAckedSegments: UInt32 = 0
    var segmentAckNotificationCount = 0
    var segmentAckLastSeqZero: UInt16?
    var segmentAckSendAttempts = 0
    var segmentAckRetryScheduled = false
    var provisioningNotificationReassembler = NativeProvisioningProxyPduReassembler()
    var liveProvisioningSession: NativeNoOobProvisioningSession?
    var liveProvisioningStarted = false
    var liveProvisioningCompleted = false
    var liveProvisioningStateWritten = false
    var liveProvisioningError: String?
    var liveProvisioningDeviceUUID: [UInt8]?
    var liveProvisioningEvents: [[String: Any]] = []
    var liveProvisioningQueue: [[UInt8]] = []
    var liveProvisioningWriting = false
    var liveProvisioningPendingWriteResponse = false
    var liveProvisioningWriteType = "none"
    var liveProvisioningProxySegmentsWritten = 0
    var liveProvisioningProxySegmentLengths: [Int] = []
    var advertisementCapturesByPeripheralID: [String: [String: Any]] = [:]

    init(options: ProbeOptions) {
        self.options = options
        super.init()
        self.manager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout + 1.0) { [weak self] in
            self?.handleTimeout()
        }
    }
}
