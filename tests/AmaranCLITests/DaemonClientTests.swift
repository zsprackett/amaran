import Foundation
import Testing
import AmaranCore
@testable import AmaranCLI

/// A minimal in-process AF_UNIX server that accepts one connection, reads a
/// newline-terminated request, and writes back a canned response line. Used to
/// exercise DaemonClient's socket exchange without the real daemon.
final class StubUnixServer {
    let socketPath: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "stub-unix-server")
    private(set) var receivedRequest: String?

    init(responseLine: String) {
        socketPath = NSTemporaryDirectory() + "amaran-stub-\(UUID().uuidString).sock"
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, 104)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        listen(listenFD, 1)

        queue.async { [listenFD] in
            let conn = accept(listenFD, nil, nil)
            guard conn >= 0 else { return }
            var request = Data()
            var byte: UInt8 = 0
            while read(conn, &byte, 1) == 1 {
                request.append(byte)
                if byte == 0x0a { break }
            }
            self.receivedRequest = String(data: request, encoding: .utf8)
            let response = responseLine.data(using: .utf8)!
            _ = response.withUnsafeBytes { Darwin.write(conn, $0.baseAddress, response.count) }
            Darwin.close(conn)
        }
    }

    /// Writes a daemon.json pointing at this stub socket and returns its path.
    func writeMetadata() -> String {
        let path = NSTemporaryDirectory() + "amaran-stub-meta-\(UUID().uuidString).json"
        let json = "{\"pid\":1,\"socket_path\":\"\(socketPath)\",\"started_at\":\"t\"}"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func stop() {
        if listenFD >= 0 { Darwin.close(listenFD) }
        unlink(socketPath)
    }
}

struct DaemonClientTests {
    @Test func exchangeSendsRequestAndDecodesResponse() throws {
        let server = StubUnixServer(
            responseLine: "{\"ok\":true,\"data\":{\"central_state\":\"poweredOn\"}}\n")
        defer { server.stop() }
        let metadataPath = server.writeMetadata()
        defer { try? FileManager.default.removeItem(atPath: metadataPath) }

        let client = DaemonClient(metadataPath: metadataPath, appPath: "/nonexistent")
        let response = try client.exchange(.ping, timeout: 2.0)

        #expect(response.succeeded == true)
        // round-trip: the stub saw exactly our framed ping request
        #expect(server.receivedRequest == "{\"action\":\"ping\"}\n")
    }

    @Test func exchangeThrowsWhenMetadataMissing() {
        let client = DaemonClient(
            metadataPath: NSTemporaryDirectory() + "missing-\(UUID().uuidString).json",
            appPath: "/nonexistent")
        #expect(throws: (any Error).self) { try client.exchange(.ping, timeout: 1.0) }
    }
}
