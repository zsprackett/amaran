import Foundation
import AmaranCore

/// Redacted fixture view for `fixture` command output. Field names match the zsh
/// `safe_fixture`.
public struct SafeFixture: Codable, Equatable {
    public let name: String
    public let friendlyName: String?
    public let sourceName: String?
    public let address: Int
    public let mac: String

    enum CodingKeys: String, CodingKey {
        case name
        case friendlyName = "friendly_name"
        case sourceName = "source_name"
        case address, mac
    }

    init(_ fixture: Fixture) {
        name = Capabilities.label(fixture)
        friendlyName = fixture.friendlyName.flatMap { $0.isEmpty ? nil : $0 }
        sourceName = fixture.name.isEmpty ? nil : fixture.name
        address = fixture.nodeAddress
        mac = MacAddress.display(fixture.macAddress)
    }
}

public struct RenameResult: Codable, Equatable {
    public let renamed: Bool
    public let previousFriendlyName: String?
    public let fixture: SafeFixture
    enum CodingKeys: String, CodingKey {
        case renamed
        case previousFriendlyName = "previous_friendly_name"
        case fixture
    }
}

public struct ClearResult: Codable, Equatable {
    public let cleared: Bool
    public let previousFriendlyName: String?
    public let fixture: SafeFixture
    enum CodingKeys: String, CodingKey {
        case cleared
        case previousFriendlyName = "previous_friendly_name"
        case fixture
    }
}

/// `fixture rename` / `fixture clear-name` logic, ported from the zsh heredoc.
public enum FixtureOps {
    /// Selector strings for the fixture command: address (decimal and hex),
    /// friendly name, and source name (no derived label).
    static func selectorValues(_ fixture: Fixture) -> [String] {
        var values = [String(fixture.nodeAddress), "0x" + String(fixture.nodeAddress, radix: 16)]
        if let friendly = fixture.friendlyName, !friendly.isEmpty { values.append(friendly) }
        if !fixture.name.isEmpty { values.append(fixture.name) }
        return values
    }

    public static func selectIndex(_ fixtures: [Fixture], selector: String) throws -> Int {
        let matches = fixtures.indices.filter { selectorValues(fixtures[$0]).contains(selector) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw CLIError("fixture selector is ambiguous: \(selector)") }
        throw CLIError("fixture not found: \(selector)")
    }

    static func looksNumeric(_ name: String) -> Bool {
        if Int(name) != nil { return true }
        let lower = name.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] {
            if lower.hasPrefix(prefix), Int(lower.dropFirst(2), radix: radix) != nil {
                return true
            }
        }
        return false
    }

    static func validFriendlyNameCharacters(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: ".:_-")
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || allowed.contains($0)
        }
    }

    static func validateFriendlyName(_ fixtures: [Fixture], targetIndex: Int, name rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw CLIError("friendly name cannot be empty") }
        guard name.count <= 64 else { throw CLIError("friendly name must be 64 characters or fewer") }
        guard validFriendlyNameCharacters(name) else {
            throw CLIError("friendly name may contain only letters, numbers, dot, underscore, colon, and hyphen")
        }
        guard !looksNumeric(name) else {
            throw CLIError("friendly name cannot look like a numeric node address")
        }
        for (index, fixture) in fixtures.enumerated() where index != targetIndex {
            if selectorValues(fixture).contains(name) {
                throw CLIError("friendly name conflicts with existing fixture selector: \(name)")
            }
        }
        return name
    }

    public static func rename(state: inout State, selector: String, name rawName: String) throws -> RenameResult {
        let index = try selectIndex(state.fixtures, selector: selector)
        let name = try validateFriendlyName(state.fixtures, targetIndex: index, name: rawName)
        let previous = state.fixtures[index].friendlyName.flatMap { $0.isEmpty ? nil : $0 }
        state.fixtures[index].friendlyName = name
        state.fixtures[index].extra["updated_at"] = .string(Timestamp.nowISO8601())
        return RenameResult(renamed: true, previousFriendlyName: previous,
                            fixture: SafeFixture(state.fixtures[index]))
    }

    public static func clearName(state: inout State, selector: String) throws -> ClearResult {
        let index = try selectIndex(state.fixtures, selector: selector)
        let previous = state.fixtures[index].friendlyName.flatMap { $0.isEmpty ? nil : $0 }
        state.fixtures[index].friendlyName = nil
        state.fixtures[index].extra["updated_at"] = .string(Timestamp.nowISO8601())
        return ClearResult(cleared: previous != nil, previousFriendlyName: previous,
                           fixture: SafeFixture(state.fixtures[index]))
    }
}
