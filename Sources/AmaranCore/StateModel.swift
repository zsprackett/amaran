import Foundation

/// Typed model of `state.json` (schema v1). Fields the CLI logic touches are
/// modeled explicitly; `Fixture` and `Source` keep an `extra` catch-all so a
/// load/modify/save cycle preserves any fields not modeled here (matching the
/// existing `json.load`/`json.dump` behavior).
public struct State: Codable, Equatable {
    public var schemaVersion: Int
    public var syncedAt: String
    public var source: Source
    public var mesh: Mesh
    public var fixtures: [Fixture]
    public var runtime: Runtime
    public var scenes: [String: Scene]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case syncedAt = "synced_at"
        case source, mesh, fixtures, runtime, scenes
    }

    public init(
        schemaVersion: Int = 1,
        syncedAt: String,
        source: Source,
        mesh: Mesh,
        fixtures: [Fixture],
        runtime: Runtime,
        scenes: [String: Scene]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.syncedAt = syncedAt
        self.source = source
        self.mesh = mesh
        self.fixtures = fixtures
        self.runtime = runtime
        self.scenes = scenes
    }
}

public struct Mesh: Codable, Equatable {
    public var uuid: String
    public var netKey: String
    public var appKey: String
    public var fixturesOrderedList: String
    public var scenesOrderedList: String
    public var updateTime: String
    public var state: Int

    enum CodingKeys: String, CodingKey {
        case uuid
        case netKey = "net_key"
        case appKey = "app_key"
        case fixturesOrderedList = "fixtures_ordered_list"
        case scenesOrderedList = "scenes_ordered_list"
        case updateTime = "update_time"
        case state
    }

    public init(
        uuid: String,
        netKey: String,
        appKey: String,
        fixturesOrderedList: String = "[]",
        scenesOrderedList: String = "[]",
        updateTime: String,
        state: Int = 0
    ) {
        self.uuid = uuid
        self.netKey = netKey
        self.appKey = appKey
        self.fixturesOrderedList = fixturesOrderedList
        self.scenesOrderedList = scenesOrderedList
        self.updateTime = updateTime
        self.state = state
    }
}

public struct Runtime: Codable, Equatable {
    public var ivIndex: Int
    public var sourceAddress: Int
    public var telinkSourceAddress: Int
    public var sequenceNext: Int
    public var updatedAt: String
    public var lastReservedBy: String?

    enum CodingKeys: String, CodingKey {
        case ivIndex = "iv_index"
        case sourceAddress = "source_address"
        case telinkSourceAddress = "telink_source_address"
        case sequenceNext = "sequence_next"
        case updatedAt = "updated_at"
        case lastReservedBy = "last_reserved_by"
    }

    public init(
        ivIndex: Int,
        sourceAddress: Int,
        telinkSourceAddress: Int,
        sequenceNext: Int,
        updatedAt: String,
        lastReservedBy: String? = nil
    ) {
        self.ivIndex = ivIndex
        self.sourceAddress = sourceAddress
        self.telinkSourceAddress = telinkSourceAddress
        self.sequenceNext = sequenceNext
        self.updatedAt = updatedAt
        self.lastReservedBy = lastReservedBy
    }
}

public struct FixtureCapabilities: Codable, Equatable {
    public var cctMin: Int?
    public var cctMax: Int?
    public var gmSupported: Bool?

    enum CodingKeys: String, CodingKey {
        case cctMin = "cct_min"
        case cctMax = "cct_max"
        case gmSupported = "gm_supported"
    }

    public init(cctMin: Int? = nil, cctMax: Int? = nil, gmSupported: Bool? = nil) {
        self.cctMin = cctMin
        self.cctMax = cctMax
        self.gmSupported = gmSupported
    }
}

public struct Fixture: Codable, Equatable {
    public var uuid: String
    public var macAddress: String
    public var code: String
    public var name: String
    public var nodeAddress: Int
    public var deviceKey: String?
    public var deviceUUID: String?
    public var compositionData: String
    public var elementCount: Int?
    public var updateTime: String
    public var state: Int
    public var friendlyName: String?
    public var macAddressSource: String?
    public var controlOnly: Bool?
    public var capabilities: FixtureCapabilities?
    /// Fields present on disk but not modeled above; preserved verbatim.
    public var extra: [String: JSONValue]

    private static let knownKeys: Set<String> = [
        "uuid", "mac_address", "code", "name", "node_address", "device_key",
        "device_uuid", "composition_data", "element_count", "update_time", "state",
        "friendly_name", "mac_address_source", "control_only", "capabilities"
    ]

    public init(
        uuid: String,
        macAddress: String = "",
        code: String = "",
        name: String,
        nodeAddress: Int,
        deviceKey: String? = nil,
        deviceUUID: String? = nil,
        compositionData: String = "",
        elementCount: Int? = nil,
        updateTime: String,
        state: Int = 0,
        friendlyName: String? = nil,
        macAddressSource: String? = nil,
        controlOnly: Bool? = nil,
        capabilities: FixtureCapabilities? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.uuid = uuid
        self.macAddress = macAddress
        self.code = code
        self.name = name
        self.nodeAddress = nodeAddress
        self.deviceKey = deviceKey
        self.deviceUUID = deviceUUID
        self.compositionData = compositionData
        self.elementCount = elementCount
        self.updateTime = updateTime
        self.state = state
        self.friendlyName = friendlyName
        self.macAddressSource = macAddressSource
        self.controlOnly = controlOnly
        self.capabilities = capabilities
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ rawKey: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: rawKey) }

        uuid = try container.decode(String.self, forKey: key("uuid"))
        nodeAddress = try container.decode(Int.self, forKey: key("node_address"))
        macAddress = try container.decodeIfPresent(String.self, forKey: key("mac_address")) ?? ""
        code = try container.decodeIfPresent(String.self, forKey: key("code")) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: key("name")) ?? ""
        deviceKey = try container.decodeIfPresent(String.self, forKey: key("device_key"))
        deviceUUID = try container.decodeIfPresent(String.self, forKey: key("device_uuid"))
        compositionData = try container.decodeIfPresent(String.self, forKey: key("composition_data")) ?? ""
        elementCount = try container.decodeIfPresent(Int.self, forKey: key("element_count"))
        updateTime = try container.decodeIfPresent(String.self, forKey: key("update_time")) ?? ""
        state = try container.decodeIfPresent(Int.self, forKey: key("state")) ?? 0
        friendlyName = try container.decodeIfPresent(String.self, forKey: key("friendly_name"))
        macAddressSource = try container.decodeIfPresent(String.self, forKey: key("mac_address_source"))
        controlOnly = try container.decodeIfPresent(Bool.self, forKey: key("control_only"))
        capabilities = try container.decodeIfPresent(FixtureCapabilities.self, forKey: key("capabilities"))

        var extra: [String: JSONValue] = [:]
        for codingKey in container.allKeys where !Self.knownKeys.contains(codingKey.stringValue) {
            extra[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ rawKey: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: rawKey) }

        try container.encode(uuid, forKey: key("uuid"))
        try container.encode(macAddress, forKey: key("mac_address"))
        try container.encode(code, forKey: key("code"))
        try container.encode(name, forKey: key("name"))
        try container.encode(nodeAddress, forKey: key("node_address"))
        try container.encodeIfPresent(deviceKey, forKey: key("device_key"))
        try container.encodeIfPresent(deviceUUID, forKey: key("device_uuid"))
        try container.encode(compositionData, forKey: key("composition_data"))
        try container.encodeIfPresent(elementCount, forKey: key("element_count"))
        try container.encode(updateTime, forKey: key("update_time"))
        try container.encode(state, forKey: key("state"))
        try container.encodeIfPresent(friendlyName, forKey: key("friendly_name"))
        try container.encodeIfPresent(macAddressSource, forKey: key("mac_address_source"))
        try container.encodeIfPresent(controlOnly, forKey: key("control_only"))
        try container.encodeIfPresent(capabilities, forKey: key("capabilities"))

        for (name, value) in extra {
            try container.encode(value, forKey: key(name))
        }
    }
}

public struct Source: Codable, Equatable {
    public var type: String
    public var provisionedAt: String?
    public var joinedAt: String?
    public var deviceUUID: String?
    public var nodeAddress: Int?
    public var controlOnly: Bool?
    /// Fields present on disk but not modeled above; preserved verbatim.
    public var extra: [String: JSONValue]

    private static let knownKeys: Set<String> = [
        "type", "provisioned_at", "joined_at", "device_uuid", "node_address", "control_only"
    ]

    public init(
        type: String,
        provisionedAt: String? = nil,
        joinedAt: String? = nil,
        deviceUUID: String? = nil,
        nodeAddress: Int? = nil,
        controlOnly: Bool? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.provisionedAt = provisionedAt
        self.joinedAt = joinedAt
        self.deviceUUID = deviceUUID
        self.nodeAddress = nodeAddress
        self.controlOnly = controlOnly
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ rawKey: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: rawKey) }

        type = try container.decode(String.self, forKey: key("type"))
        provisionedAt = try container.decodeIfPresent(String.self, forKey: key("provisioned_at"))
        joinedAt = try container.decodeIfPresent(String.self, forKey: key("joined_at"))
        deviceUUID = try container.decodeIfPresent(String.self, forKey: key("device_uuid"))
        nodeAddress = try container.decodeIfPresent(Int.self, forKey: key("node_address"))
        controlOnly = try container.decodeIfPresent(Bool.self, forKey: key("control_only"))

        var extra: [String: JSONValue] = [:]
        for codingKey in container.allKeys where !Self.knownKeys.contains(codingKey.stringValue) {
            extra[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ rawKey: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: rawKey) }

        try container.encode(type, forKey: key("type"))
        try container.encodeIfPresent(provisionedAt, forKey: key("provisioned_at"))
        try container.encodeIfPresent(joinedAt, forKey: key("joined_at"))
        try container.encodeIfPresent(deviceUUID, forKey: key("device_uuid"))
        try container.encodeIfPresent(nodeAddress, forKey: key("node_address"))
        try container.encodeIfPresent(controlOnly, forKey: key("control_only"))

        for (name, value) in extra {
            try container.encode(value, forKey: key(name))
        }
    }
}

public struct Scene: Codable, Equatable {
    public var capturedAt: String
    public var fixtures: [SceneFixture]

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case fixtures
    }

    public init(capturedAt: String, fixtures: [SceneFixture]) {
        self.capturedAt = capturedAt
        self.fixtures = fixtures
    }
}

public struct SceneFixture: Codable, Equatable {
    public var nodeAddress: Int
    public var name: String
    public var macSuffix: String
    public var intensity: Double?
    public var cct: Int?
    public var greenMagenta: Int?
    public var sleepMode: Int?

    enum CodingKeys: String, CodingKey {
        case nodeAddress = "node_address"
        case name
        case macSuffix = "mac_suffix"
        case intensity, cct
        case greenMagenta = "gm"
        case sleepMode = "sleep_mode"
    }

    public init(
        nodeAddress: Int,
        name: String,
        macSuffix: String,
        intensity: Double? = nil,
        cct: Int? = nil,
        greenMagenta: Int? = nil,
        sleepMode: Int? = nil
    ) {
        self.nodeAddress = nodeAddress
        self.name = name
        self.macSuffix = macSuffix
        self.intensity = intensity
        self.cct = cct
        self.greenMagenta = greenMagenta
        self.sleepMode = sleepMode
    }
}
