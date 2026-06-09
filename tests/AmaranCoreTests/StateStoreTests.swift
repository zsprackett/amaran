import Foundation
import Testing
@testable import AmaranCore

struct StateStoreTests {
    private func sampleState() -> State {
        State(
            syncedAt: "2024-01-15T10:30:45Z",
            source: Source(type: "native_provisioning", provisionedAt: "2024-01-15T10:30:45Z"),
            mesh: Mesh(
                uuid: "studio-mesh-001",
                netKey: "0123456789abcdef0123456789abcdef",
                appKey: "fedcba9876543210fedcba9876543210",
                updateTime: "2024-01-15T10:30:45Z"
            ),
            fixtures: [
                Fixture(uuid: "f1", name: "key-light", nodeAddress: 6,
                        deviceKey: "11223344556677889900aabbccddeeff",
                        deviceUUID: "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7",
                        updateTime: "2024-01-15T10:30:45Z")
            ],
            runtime: Runtime(ivIndex: 0, sourceAddress: 3, telinkSourceAddress: 1,
                             sequenceNext: 1, updatedAt: "2024-01-15T10:30:45Z")
        )
    }

    private func tempPath() -> String {
        let dir = NSTemporaryDirectory() + "amaran-store-" + UUID().uuidString
        return dir + "/nested/state.json"
    }

    @Test func saveThenLoadRoundTrips() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let state = sampleState()
        try StateStore.save(state, to: path)
        let loaded = try StateStore.load(path)
        #expect(loaded == state)
    }

    @Test func createsParentDirectoryAndSetsPermissions() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try StateStore.save(sampleState(), to: path)
        #expect(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test func outputIsSortedDeterministicAndNewlineTerminated() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let state = sampleState()
        try StateStore.save(state, to: path)
        let first = try Data(contentsOf: URL(fileURLWithPath: path))
        try StateStore.save(state, to: path)
        let second = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(first == second)
        let text = String(data: first, encoding: .utf8)!
        #expect(text.hasSuffix("}\n"))
        // sorted keys: app_key appears before net_key within mesh
        let appIdx = text.range(of: "\"app_key\"")!.lowerBound
        let netIdx = text.range(of: "\"net_key\"")!.lowerBound
        #expect(appIdx < netIdx)
    }

    @Test func loadMissingFileThrows() {
        #expect(throws: (any Error).self) {
            try StateStore.load(NSTemporaryDirectory() + "does-not-exist-\(UUID().uuidString).json")
        }
    }
}
