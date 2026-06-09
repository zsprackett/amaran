import Foundation
import AmaranCore

public enum DaemonClientError: Error, CustomStringConvertible {
    case metadataMissing
    case connectFailed(String)
    case ioFailed(String)
    case emptyResponse

    public var description: String {
        switch self {
        case .metadataMissing: return "daemon metadata file is missing"
        case .connectFailed(let message): return "daemon connect failed: \(message)"
        case .ioFailed(let message): return "daemon io failed: \(message)"
        case .emptyResponse: return "daemon returned an empty response"
        }
    }
}

/// Decoded form of the daemon metadata file (`daemon.json`).
private struct DaemonMetadata: Decodable {
    let socketPath: String
    enum CodingKeys: String, CodingKey { case socketPath = "socket_path" }
}

/// Talks to the runtime daemon over its Unix domain socket. The socket path is
/// read from the daemon metadata file (`daemon.json`); framing comes from
/// `AmaranCore.DaemonProtocol`. Auto-start spawns the signed app bundle in
/// `--daemon` mode (the same `open -g` path the zsh dispatcher used).
public struct DaemonClient {
    public let metadataPath: String
    public let appPath: String

    public init(metadataPath: String, appPath: String) {
        self.metadataPath = (metadataPath as NSString).expandingTildeInPath
        self.appPath = appPath
    }

    private func readSocketPath() throws -> String {
        guard let data = FileManager.default.contents(atPath: metadataPath),
            let metadata = try? JSONDecoder().decode(DaemonMetadata.self, from: data),
            !metadata.socketPath.isEmpty
        else {
            throw DaemonClientError.metadataMissing
        }
        return (metadata.socketPath as NSString).expandingTildeInPath
    }

    /// Sends one request and returns the decoded response.
    public func exchange(_ request: DaemonRequest, timeout: TimeInterval) throws -> DaemonResponse {
        let socketPath = try readSocketPath()
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw DaemonClientError.connectFailed("socket() failed")
        }
        defer { close(fileDescriptor) }

        setTimeout(fileDescriptor, SO_RCVTIMEO, timeout)
        setTimeout(fileDescriptor, SO_SNDTIMEO, timeout)

        try connect(fileDescriptor, to: socketPath)
        try writeAll(fileDescriptor, try DaemonProtocol.encodeRequest(request))
        let responseData = try readLine(fileDescriptor)
        guard !responseData.isEmpty else {
            throw DaemonClientError.emptyResponse
        }
        return try DaemonProtocol.decodeResponse(responseData)
    }

    /// True if a daemon is reachable and answers `ping` with `ok`.
    public func ping(timeout: TimeInterval = 0.5) -> Bool {
        (try? exchange(.ping, timeout: timeout))?.succeeded ?? false
    }

    /// Ensures a daemon is running, spawning one and polling up to `deadline`
    /// seconds if needed. Returns true once reachable.
    @discardableResult
    public func ensureRunning(deadline: TimeInterval = 5.0) -> Bool {
        if ping() { return true }
        spawnDaemon()
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if ping() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func spawnDaemon() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", appPath, "--args", "--daemon", "--daemon-port-file", metadataPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - POSIX socket helpers

    private func setTimeout(_ fileDescriptor: Int32, _ option: Int32, _ seconds: TimeInterval) {
        var timeoutValue = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fileDescriptor, SOL_SOCKET, option, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
    }

    private func connect(_ fileDescriptor: Int32, to path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr, pathCapacity - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, len)
            }
        }
        guard result == 0 else {
            throw DaemonClientError.connectFailed(String(cString: strerror(errno)))
        }
    }

    private func writeAll(_ fileDescriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            let base = raw.baseAddress!
            while offset < data.count {
                let written = Darwin.write(fileDescriptor, base + offset, data.count - offset)
                if written <= 0 {
                    throw DaemonClientError.ioFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    private func readLine(_ fileDescriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count < 0 {
                throw DaemonClientError.ioFailed(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            result.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(DaemonProtocol.terminator) { break }
        }
        return result
    }
}
