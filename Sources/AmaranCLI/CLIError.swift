import Foundation

/// A user-facing CLI failure. ArgumentParser prints the description and exits
/// non-zero.
public struct CLIError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
