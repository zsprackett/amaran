import CoreBluetooth
import Darwin
import Foundation
import Network
import os

/// Unified-logging facade for the probe.
///
/// The daemon is launched via `open -g AmaranHelper.app`, so stderr is
/// discarded by launchd/Launch Services. Routing daemon-context logs through
/// `os.Logger` keeps them in the system log store where they can be streamed
/// with `log stream` / `log show` (see `amaran daemon logs`) or Console.app.
/// One-shot CLI invocations continue to use stderr, which the wrapper captures.
enum Log {
    static let subsystem = "dev.local.amaran-helper"
    static let daemon = Logger(subsystem: subsystem, category: "daemon")
    static let ble = Logger(subsystem: subsystem, category: "ble")
    static let mesh = Logger(subsystem: subsystem, category: "mesh")
    static let command = Logger(subsystem: subsystem, category: "command")
}

let meshProxyService = CBUUID(string: "1828")
let meshProvisioningService = CBUUID(string: "1827")
let meshProxyDataIn = CBUUID(string: "2ADD")
let meshProxyDataOut = CBUUID(string: "2ADE")
let meshProvisioningDataIn = CBUUID(string: "2ADB")
let meshProvisioningDataOut = CBUUID(string: "2ADC")
let publicSampleProxyPduHex = "006848cba437860e5673728a627fb938535508e21a6baf57"

func cbuuidString(_ uuid: CBUUID) -> String {
    uuid.uuidString.uppercased()
}

enum AmaranHelperError: Error, CustomStringConvertible {
    case invalidHex(String)
    case invalidState(String)

    var description: String {
        switch self {
        case .invalidHex(let value):
            return "invalid hex: \(value)"
        case .invalidState(let value):
            return "invalid state: \(value)"
        }
    }
}

func bytes(hex: String) throws -> [UInt8] {
    let compact = hex.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
    guard compact.count % 2 == 0 else {
        throw AmaranHelperError.invalidHex(hex)
    }

    var result: [UInt8] = []
    result.reserveCapacity(compact.count / 2)
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        guard let byte = UInt8(compact[index..<next], radix: 16) else {
            throw AmaranHelperError.invalidHex(hex)
        }
        result.append(byte)
        index = next
    }
    return result
}

func defaultStatePath() -> String {
    "\(NSHomeDirectory())/Library/Application Support/amaran-cli/state.json"
}

func jsonInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String {
        return Int(string)
    }
    return nil
}

func jsonString(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty {
        return string
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return nil
}

func isoTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

func writeJSONPayload(_ payload: [String: Any], to outputPath: String) throws {
    let output = URL(fileURLWithPath: outputPath)
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: output, options: .atomic)
}

func writeSensitiveJSONPayload(_ payload: [String: Any], to outputPath: String) throws {
    let output = URL(fileURLWithPath: outputPath)
    let directory = output.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: output, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputPath)
}

func centralStateName(_ state: CBManagerState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .resetting: return "resetting"
    case .unsupported: return "unsupported"
    case .unauthorized: return "unauthorized"
    case .poweredOff: return "poweredOff"
    case .poweredOn: return "poweredOn"
    @unknown default: return "future"
    }
}

func characteristicProperties(_ properties: CBCharacteristicProperties) -> [String] {
    var names: [String] = []
    if properties.contains(.broadcast) { names.append("broadcast") }
    if properties.contains(.read) { names.append("read") }
    if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
    if properties.contains(.write) { names.append("write") }
    if properties.contains(.notify) { names.append("notify") }
    if properties.contains(.indicate) { names.append("indicate") }
    if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
    if properties.contains(.extendedProperties) { names.append("extendedProperties") }
    if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
    if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
    return names
}

func meshRole(serviceUUIDs: [String]) -> [String] {
    var roles: [String] = []
    if serviceUUIDs.contains("1828") { roles.append("proxy") }
    if serviceUUIDs.contains("1827") { roles.append("provisioning") }
    return roles
}
