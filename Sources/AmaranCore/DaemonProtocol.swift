import Foundation

/// A request sent from a client to the runtime daemon. Field names match the
/// existing wire contract (`state_path`, `node_id`). Nil fields are omitted so
/// `ping`/`shutdown` serialize to just `{"action":"..."}`.
public struct DaemonRequest: Codable, Equatable, Sendable {
    public var action: String
    public var spec: String?
    public var specs: [String]?
    public var statePath: String?
    public var timeout: Double?
    public var nodeID: String?

    enum CodingKeys: String, CodingKey {
        case action, spec, specs
        case statePath = "state_path"
        case timeout
        case nodeID = "node_id"
    }

    public init(
        action: String,
        spec: String? = nil,
        specs: [String]? = nil,
        statePath: String? = nil,
        timeout: Double? = nil,
        nodeID: String? = nil
    ) {
        self.action = action
        self.spec = spec
        self.specs = specs
        self.statePath = statePath
        self.timeout = timeout
        self.nodeID = nodeID
    }

    public static let ping = DaemonRequest(action: "ping")
    public static let shutdown = DaemonRequest(action: "shutdown")

    public static func control(
        spec: String, statePath: String, timeout: Double, nodeID: String?
    ) -> DaemonRequest {
        DaemonRequest(action: "control", spec: spec, statePath: statePath, timeout: timeout, nodeID: nodeID)
    }

    public static func controlSequence(
        specs: [String], statePath: String, timeout: Double, nodeID: String?
    ) -> DaemonRequest {
        DaemonRequest(action: "control_sequence", specs: specs, statePath: statePath,
                      timeout: timeout, nodeID: nodeID)
    }

    public static func status(
        statePath: String, timeout: Double, nodeID: String?
    ) -> DaemonRequest {
        DaemonRequest(action: "status", statePath: statePath, timeout: timeout, nodeID: nodeID)
    }
}

/// A response from the runtime daemon. `data` is free-form (`JSONValue`) since
/// its shape varies by action.
public struct DaemonResponse: Codable, Equatable, Sendable {
    public var succeeded: Bool
    public var error: String?
    public var data: JSONValue?

    enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case error
        case data
    }

    public init(succeeded: Bool, error: String? = nil, data: JSONValue? = nil) {
        self.succeeded = succeeded
        self.error = error
        self.data = data
    }
}

/// Line-framed JSON wire protocol for the daemon socket: one compact-JSON
/// message terminated by a newline. Shared by the daemon listener and the CLI
/// client so the contract has a single source of truth.
public enum DaemonProtocol {
    public static let terminator: UInt8 = 0x0a

    private static func compactEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public static func encodeRequest(_ request: DaemonRequest) throws -> Data {
        var data = try compactEncoder().encode(request)
        data.append(terminator)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> DaemonRequest {
        try JSONDecoder().decode(DaemonRequest.self, from: trimmed(data))
    }

    public static func encodeResponse(_ response: DaemonResponse) throws -> Data {
        var data = try compactEncoder().encode(response)
        data.append(terminator)
        return data
    }

    public static func decodeResponse(_ data: Data) throws -> DaemonResponse {
        try JSONDecoder().decode(DaemonResponse.self, from: trimmed(data))
    }

    /// Drops a single trailing newline (and any surrounding whitespace) before decoding.
    private static func trimmed(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex {
            let byte = data[end - 1]
            if byte == terminator || byte == 0x20 || byte == 0x0d || byte == 0x09 {
                end -= 1
            } else {
                break
            }
        }
        return data[data.startIndex..<end]
    }
}
