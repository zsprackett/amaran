import Foundation

/// Error thrown when composition data or a declared element count is malformed.
public enum CompositionError: Error, Equatable, CustomStringConvertible {
    case truncated(String)
    case noElements
    case invalidElementCount(Int)

    public var description: String {
        switch self {
        case .truncated(let what):
            return "composition data truncated: \(what)"
        case .noElements:
            return "composition data page 0 must include at least one element"
        case .invalidElementCount(let value):
            return "element_count must be 1..255: \(value)"
        }
    }
}

/// Composition Data Page 0 parsing, ported from `NativeMeshConfig`. Phase 1 only
/// needs the element count; the full model parse will move here when the app
/// folds onto AmaranCore.
public enum Composition {
    /// Number of elements in a Composition Data Page 0 blob. Mirrors
    /// `NativeMeshConfig.compositionDataPage0`, including the optional leading
    /// page-byte fallback.
    public static func page0ElementCount(_ data: [UInt8]) throws -> Int {
        do {
            return try elementCount(data)
        } catch {
            if data.first == 0x00 {
                return try elementCount(Array(data.dropFirst()))
            }
            throw error
        }
    }

    /// Derives a fixture's element count, mirroring
    /// `NativeMeshState.fixtureElementCount`: prefer a parseable composition,
    /// then an explicit (validated) declared count, otherwise 1.
    public static func derivedElementCount(
        compositionHex: String?,
        declaredElementCount: Int?
    ) throws -> Int {
        if let compositionHex, !compositionHex.isEmpty,
            let bytes = try? Hex.decode(compositionHex),
            let count = try? page0ElementCount(bytes) {
            return max(1, count)
        }
        if let declaredElementCount {
            guard (1...255).contains(declaredElementCount) else {
                throw CompositionError.invalidElementCount(declaredElementCount)
            }
            return declaredElementCount
        }
        return 1
    }

    private static func elementCount(_ data: [UInt8]) throws -> Int {
        guard data.count >= 10 else {
            throw CompositionError.truncated("page 0 header")
        }

        var index = 10 // skip cid/pid/vid/crpl/features
        var elements = 0
        while index < data.count {
            guard index + 4 <= data.count else {
                throw CompositionError.truncated("element header")
            }
            index += 2 // location
            let sigModelCount = Int(data[index]); index += 1
            let vendorModelCount = Int(data[index]); index += 1

            let modelBytes = sigModelCount * 2 + vendorModelCount * 4
            guard index + modelBytes <= data.count else {
                throw CompositionError.truncated("element model list")
            }
            index += modelBytes
            elements += 1
        }

        guard elements > 0 else {
            throw CompositionError.noElements
        }
        return elements
    }
}
