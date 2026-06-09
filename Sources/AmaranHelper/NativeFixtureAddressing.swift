import Foundation

func fixtureLabel(_ fixture: [String: Any]) -> String {
    if let friendlyName = jsonString(fixture["friendly_name"]) {
        return friendlyName
    }
    if let name = jsonString(fixture["name"]) {
        return name
    }
    let address = jsonInt(fixture["node_address"]) ?? 0
    return "fixture-\(address)"
}

func fixtureMacSuffix(_ fixture: [String: Any]) -> String? {
    guard let value = jsonString(fixture["mac_address"]) else {
        return nil
    }
    let normalized = value.filter { $0.isHexDigit }.uppercased()
    guard !normalized.isEmpty else {
        return nil
    }
    return String(normalized.suffix(6))
}

func selectFixture(_ fixtures: [[String: Any]], nodeID: String?) throws -> [String: Any] {
    if let nodeID, !nodeID.isEmpty {
        if let fixture = fixtures.first(where: { fixture in
            jsonString(fixture["node_address"]) == nodeID ||
                jsonString(fixture["friendly_name"]) == nodeID ||
                jsonString(fixture["name"]) == nodeID
        }) {
            return fixture
        }
        throw AmaranHelperError.invalidState("fixture not found: \(nodeID)")
    }

    guard fixtures.count == 1 else {
        throw AmaranHelperError.invalidState("multiple fixtures found; pass --node")
    }
    return fixtures[0]
}

func prepareNativeProxyStateProbe(
    statePath: String,
    nodeID: String?
) throws -> (requiredProxyNetworkId: [UInt8], metadata: [String: Any]) {
    let url = URL(fileURLWithPath: statePath)
    let data = try Data(contentsOf: url)
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AmaranHelperError.invalidState("state file must contain a JSON object")
    }
    guard jsonInt(payload["schema_version"]) == 1 else {
        throw AmaranHelperError.invalidState("unsupported state schema version")
    }
    guard let mesh = payload["mesh"] as? [String: Any] else {
        throw AmaranHelperError.invalidState("state file is missing mesh data")
    }
    guard let fixtures = payload["fixtures"] as? [[String: Any]], !fixtures.isEmpty else {
        throw AmaranHelperError.invalidState("state file is missing fixtures")
    }
    guard let netKeyHex = jsonString(mesh["net_key"]) else {
        throw AmaranHelperError.invalidState("state mesh data missing NetKey")
    }

    let fixture = try selectFixture(fixtures, nodeID: nodeID)
    guard let destination = jsonInt(fixture["node_address"]), (1...0x7fff).contains(destination) else {
        throw AmaranHelperError.invalidState("fixture has invalid node address")
    }

    let netKey = try NativeMeshCrypto.bytes(hex: netKeyHex)
    var metadata: [String: Any] = [
        "address": destination,
        "fixture": fixtureLabel(fixture),
        "probe": "mesh_proxy_network_id"
    ]
    if let suffix = fixtureMacSuffix(fixture) {
        metadata["mac_suffix"] = suffix
    }
    return (try NativeMeshCrypto.k3(n: netKey), metadata)
}

func prepareNativeMeshMonitor(
    statePath: String,
    nodeID: String?
) throws -> NativeMeshMonitorPreparation {
    var context = try NativeReservationContext(statePath: statePath, nodeID: nodeID, requireDeviceKey: false)
    let sourceAddress = try context.runtimeSourceAddress()
    let sequenceNext = try context.sequenceNext()
    let filterPdu = try NativeMeshCrypto.proxyConfigurationProxyPdu(
        ivIndex: UInt32(context.ivIndex),
        sequence: UInt32(sequenceNext),
        source: UInt16(sourceAddress),
        netKey: context.netKey,
        transportPdu: [0x00, 0x01]
    )
    try context.persist(
        sourceAddress: sourceAddress,
        sequenceNext: sequenceNext + 1,
        lastReservedBy: "monitor-proxy-filter"
    )

    return NativeMeshMonitorPreparation(
        requiredProxyNetworkId: try NativeMeshCrypto.k3(n: context.netKey),
        decodeMaterial: context.makeDecodeMaterial(),
        metadata: [
            "address": context.destination,
            "fixture": fixtureLabel(context.fixture),
            "monitor": "mesh_proxy",
            "proxy_filter": "reject_list_empty",
            "proxy_filter_sequence": sequenceNext,
            "proxy_filter_source": sourceAddress
        ],
        filterProxyPdu: filterPdu.proxyPdu
    )
}

func occupiedFixtureAddresses(_ fixtures: [[String: Any]]) -> Set<Int> {
    var occupied = Set<Int>()
    for fixture in fixtures {
        guard let primary = jsonInt(fixture["node_address"]), (1...0x7fff).contains(primary) else {
            continue
        }

        var elementCount = 1
        if let compositionHex = jsonString(fixture["composition_data"]),
           !compositionHex.isEmpty,
           let compositionBytes = try? NativeMeshCrypto.bytes(hex: compositionHex),
           let composition = try? NativeMeshConfig.compositionDataPage0(compositionBytes) {
            elementCount = max(1, composition.elements.count)
        } else if let storedElementCount = jsonInt(fixture["element_count"]),
                  (1...255).contains(storedElementCount) {
            elementCount = storedElementCount
        }

        for offset in 0..<elementCount {
            let address = primary + offset
            if (1...0x7fff).contains(address) {
                occupied.insert(address)
            }
        }
    }
    return occupied
}

func fixtureHasKnownElementExtent(_ fixture: [String: Any]) -> Bool {
    if let compositionHex = jsonString(fixture["composition_data"]),
       !compositionHex.isEmpty,
       let compositionBytes = try? NativeMeshCrypto.bytes(hex: compositionHex),
       (try? NativeMeshConfig.compositionDataPage0(compositionBytes)) != nil {
        return true
    }
    if let storedElementCount = jsonInt(fixture["element_count"]),
       (1...255).contains(storedElementCount) {
        return true
    }
    return false
}

func provisioningReservedFixtureAddresses(_ fixtures: [[String: Any]]) -> Set<Int> {
    var reserved = occupiedFixtureAddresses(fixtures)
    for fixture in fixtures {
        guard let primary = jsonInt(fixture["node_address"]), (1...0x7fff).contains(primary) else {
            continue
        }
        guard !fixtureHasKnownElementExtent(fixture) else {
            continue
        }
        for offset in 0..<16 {
            let address = primary + offset
            if (1...0x7fff).contains(address) {
                reserved.insert(address)
            }
        }
    }
    return reserved
}

func nextProvisioningUnicastAddress(
    fixtures: [[String: Any]],
    runtime: [String: Any]
) throws -> UInt16 {
    var reserved = provisioningReservedFixtureAddresses(fixtures)
    for key in ["source_address", "telink_source_address"] {
        if let address = jsonInt(runtime[key]), (1...0x7fff).contains(address) {
            reserved.insert(address)
        }
    }

    for candidate in 2...0x7fff where !reserved.contains(candidate) {
        return UInt16(candidate)
    }
    throw AmaranHelperError.invalidState("could not choose an unused fixture node address")
}

func nativeRuntimeSourceAddress(
    runtime: [String: Any],
    fixtures: [[String: Any]],
    destination: Int
) throws -> Int {
    let occupied = occupiedFixtureAddresses(fixtures)
    let existing = jsonInt(runtime["source_address"])
    if let existing, !(1...0x7fff).contains(existing) {
        throw AmaranHelperError.invalidState("runtime source_address must be a unicast address")
    }
    if let existing,
       existing != 1,
       existing != destination,
       !occupied.contains(existing) {
        return existing
    }

    if !occupied.contains(3), destination != 3 {
        return 3
    }
    for candidate in 4...0x7fff {
        if candidate != destination, !occupied.contains(candidate) {
            return candidate
        }
    }
    if !occupied.contains(2), destination != 2 {
        return 2
    }
    throw AmaranHelperError.invalidState("could not choose an unused CLI source address")
}

func nativeTelinkSourceAddress(
    runtime: [String: Any],
    fixtures: [[String: Any]],
    destination: Int
) throws -> Int {
    let occupied = occupiedFixtureAddresses(fixtures)
    let existing = jsonInt(runtime["telink_source_address"])
    if let existing, !(1...0x7fff).contains(existing) {
        throw AmaranHelperError.invalidState("runtime telink_source_address must be a unicast address")
    }
    if let existing,
       existing != destination,
       !occupied.contains(existing) {
        return existing
    }

    if destination != 1, !occupied.contains(1) {
        return 1
    }
    return try nativeRuntimeSourceAddress(
        runtime: runtime,
        fixtures: fixtures,
        destination: destination
    )
}

func nativeTelinkSourceAddress(
    runtime: [String: Any],
    fixtures: [[String: Any]],
    avoiding destinations: Set<Int>
) throws -> Int {
    let occupied = occupiedFixtureAddresses(fixtures)
    let blocked = occupied.union(destinations)
    let existing = jsonInt(runtime["telink_source_address"])
    if let existing, !(1...0x7fff).contains(existing) {
        throw AmaranHelperError.invalidState("runtime telink_source_address must be a unicast address")
    }
    if let existing,
       !blocked.contains(existing) {
        return existing
    }

    if !blocked.contains(1) {
        return 1
    }
    for candidate in 3...0x7fff where !blocked.contains(candidate) {
        return candidate
    }
    if !blocked.contains(2) {
        return 2
    }
    throw AmaranHelperError.invalidState("could not choose an unused Telink source address")
}

func parseUnicastAddressList(_ spec: String) throws -> [Int] {
    let parts = spec.split(separator: ",", omittingEmptySubsequences: true)
    guard !parts.isEmpty else {
        throw AmaranHelperError.invalidState("status batch requires at least one address")
    }
    var seen = Set<Int>()
    var addresses: [Int] = []
    for part in parts {
        guard let address = Int(part.trimmingCharacters(in: .whitespacesAndNewlines), radix: 10),
              (1...0x7fff).contains(address) else {
            throw AmaranHelperError.invalidState("status batch contains an invalid unicast address")
        }
        if !seen.contains(address) {
            seen.insert(address)
            addresses.append(address)
        }
    }
    return addresses
}

enum NativeSourceRole {
    case cliOwned
    case telinkRuntime
}
