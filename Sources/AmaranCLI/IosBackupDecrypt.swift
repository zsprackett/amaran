import Foundation
import CommonCrypto
import SQLite3

/// Native iOS encrypted-backup decryption (replaces the `iphone-backup-decrypt`
/// Python helper). Implements the documented backup crypto: keybag parse,
/// passphrase derivation (incl. the iOS 10.2+ double round), RFC-3394 key
/// unwrap, and AES-CBC file decryption, all via CommonCrypto.
///
/// The crypto primitives are unit-tested against RFC vectors; the end-to-end
/// path must be verified against a real encrypted backup.
public enum IosBackupDecrypt {
    public static func meshFiles(backupDir: URL, passphrase: String, domains: [String]) throws -> [SidusMeshFile] {
        let manifestPlist = try readPlist(backupDir.appendingPathComponent("Manifest.plist"))
        guard let keybagData = manifestPlist["BackupKeyBag"] as? Data,
            let manifestKeyBlob = manifestPlist["ManifestKey"] as? Data else {
            throw CLIError("encrypted iPad backup could not be read: missing keybag")
        }

        let keybag = try KeyBag.parse(keybagData)
        let classKeys = keybag.unwrapClassKeys(passphrase: passphrase)
        guard let manifestKey = unwrapFileKey(manifestKeyBlob, classKeys: classKeys) else {
            throw CLIError("encrypted iPad backup could not be read: wrong password?")
        }

        let encryptedDB = try Data(contentsOf: backupDir.appendingPathComponent("Manifest.db"))
        let manifestDB = BackupCrypto.aesCBCDecrypt(key: manifestKey, data: encryptedDB)
        guard manifestDB.starts(with: Array("SQLite format 3\0".utf8)) else {
            throw CLIError("encrypted iPad backup could not be read: wrong password?")
        }

        return try withDecryptedManifest(manifestDB) { database in
            try meshRows(db: database, domains: domains).compactMap { row in
                guard let entry = parseMBFile(row.fileBlob),
                    let classKey = classKeys[entry.clas],
                    let fileKey = BackupCrypto.aesUnwrap(kek: classKey, wrapped: entry.wrapped) else {
                    return nil
                }
                let fileURL = backupDir.appendingPathComponent(String(row.fileID.prefix(2)))
                    .appendingPathComponent(row.fileID)
                guard let encrypted = try? Data(contentsOf: fileURL) else { return nil }
                let decrypted = BackupCrypto.aesCBCDecrypt(key: fileKey, data: encrypted).prefix(entry.size)
                return SidusMeshFile(domain: row.domain, relativePath: row.relativePath, data: Data(decrypted))
            }
        }
    }

    // MARK: - Manifest.db (decrypted SQLite)

    private struct MeshRow { let fileID: String; let domain: String; let relativePath: String; let fileBlob: Data }

    /// Decoded EncryptionKey fields from a Manifest Files.file blob.
    struct MBFileKey { let clas: Int; let wrapped: Data; let size: Int }

    private static func withDecryptedManifest<T>(_ database: Data, _ body: (OpaquePointer) throws -> T) throws -> T {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amaran-manifest-\(UUID().uuidString).db")
        try database.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        // Open as immutable: the decrypted Manifest.db is often WAL-mode, and a
        // plain read-only open fails at first statement without the -wal sidecar.
        var handle: OpaquePointer?
        let uri = "file:\(temp.path)?immutable=1"
        let openStatus = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard openStatus == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(openStatus)"
            sqlite3_close(handle)
            throw CLIError("encrypted iPad backup Manifest.db could not be opened: \(message)")
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }

    private static func meshRows(db database: OpaquePointer, domains: [String]) throws -> [MeshRow] {
        let placeholders = domains.map { _ in "?" }.joined(separator: ", ")
        let sql = """
        select fileID, domain, relativePath, file from Files
        where flags = 1 and domain in (\(placeholders))
          and relativePath like 'Documents/mesh/%.json'
        order by domain, relativePath
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            throw CLIError("encrypted iPad backup Manifest.db query failed: \(message)")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, domain) in domains.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), domain, -1, transient)
        }

        var rows: [MeshRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idc = sqlite3_column_text(stmt, 0), let domainCol = sqlite3_column_text(stmt, 1),
                let relativePathCol = sqlite3_column_text(stmt, 2),
                let blob = sqlite3_column_blob(stmt, 3) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 3))
            rows.append(MeshRow(
                fileID: String(cString: idc), domain: String(cString: domainCol),
                relativePath: String(cString: relativePathCol),
                fileBlob: Data(bytes: blob, count: blobLen)))
        }
        return rows
    }

    // MARK: - MBFile (NSKeyedArchiver) parsing

    /// Extracts (class, wrapped-key, size) from a Manifest Files.file blob.
    /// Heuristic: the EncryptionKey is the 44-byte (`<class:4><wrapped:40>`) data
    /// object; Size is the MBFile's inline integer.
    static func parseMBFile(_ blob: Data) -> MBFileKey? {
        guard let plist = try? PropertyListSerialization.propertyList(from: blob, format: nil),
            let root = plist as? [String: Any],
            let objects = root["$objects"] as? [Any] else { return nil }

        var encKeyBlob: Data?
        var size: Int?
        for object in objects {
            if let dict = object as? [String: Any] {
                if dict["EncryptionKey"] != nil, let sizeValue = (dict["Size"] as? NSNumber)?.intValue {
                    size = sizeValue
                }
                if let nsdata = dict["NS.data"] as? Data, nsdata.count == 44 {
                    encKeyBlob = nsdata
                }
            } else if let data = object as? Data, data.count == 44 {
                encKeyBlob = data
            }
        }
        guard let encKeyBlob, let size else { return nil }
        let clas = Int(littleEndianUInt32(encKeyBlob.prefix(4)))
        return MBFileKey(clas: clas, wrapped: Data(encKeyBlob.dropFirst(4)), size: size)
    }

    private static func unwrapFileKey(_ blob: Data, classKeys: [Int: Data]) -> Data? {
        guard blob.count >= 4 else { return nil }
        let clas = Int(littleEndianUInt32(blob.prefix(4)))
        guard let classKey = classKeys[clas] else { return nil }
        return BackupCrypto.aesUnwrap(kek: classKey, wrapped: Data(blob.dropFirst(4)))
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any] else {
            throw CLIError("encrypted iPad backup Manifest.plist could not be read")
        }
        return dict
    }

    static func littleEndianUInt32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in data.prefix(4).enumerated() { value |= UInt32(byte) << (8 * index) }
        return value
    }

    static func bigEndianInt(_ data: Data) -> Int {
        var value = 0
        for byte in data { value = (value << 8) | Int(byte) }
        return value
    }
}

/// iOS backup keybag (TLV), parsed enough to unwrap protection-class keys.
struct KeyBag {
    var salt = Data()
    var iterations = 0
    var doubleSalt: Data?
    var doubleIterations: Int?
    var classes: [Int: Data] = [:]  // class number -> wrapped class key (WPKY)

    static func parse(_ data: Data) throws -> KeyBag {
        var bag = KeyBag()
        var offset = data.startIndex
        var sawHeaderUUID = false
        var currentClass: Int?

        while offset + 8 <= data.endIndex {
            let tag = String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let length = IosBackupDecrypt.bigEndianInt(data[offset + 4..<offset + 8])
            let valueStart = offset + 8
            guard valueStart + length <= data.endIndex else { break }
            let value = data[valueStart..<valueStart + length]
            offset = valueStart + length
            bag.applyTLV(tag: tag, value: value, sawHeaderUUID: &sawHeaderUUID, currentClass: &currentClass)
        }
        guard !bag.salt.isEmpty, bag.iterations > 0, !bag.classes.isEmpty else {
            throw CLIError("encrypted iPad backup keybag is malformed")
        }
        return bag
    }

    /// Applies one keybag TLV record, mutating the bag and the running parse cursor.
    private mutating func applyTLV(
        tag: String, value: Data.SubSequence, sawHeaderUUID: inout Bool, currentClass: inout Int?
    ) {
        switch tag {
        case "SALT": salt = Data(value)
        case "ITER": iterations = IosBackupDecrypt.bigEndianInt(value)
        case "DPSL": doubleSalt = Data(value)
        case "DPIC": doubleIterations = IosBackupDecrypt.bigEndianInt(value)
        case "UUID":
            if !sawHeaderUUID { sawHeaderUUID = true } else { currentClass = nil }
        case "CLAS": currentClass = IosBackupDecrypt.bigEndianInt(value)
        case "WPKY":
            if let clas = currentClass { classes[clas] = Data(value) }
        default:
            break
        }
    }

    /// Derives the passcode key and unwraps each class key.
    func unwrapClassKeys(passphrase: String) -> [Int: Data] {
        let passwordData = Data(passphrase.utf8)
        let firstStage: Data
        if let doubleSalt, let doubleIterations {
            firstStage = BackupCrypto.pbkdf2(
                password: passwordData, salt: doubleSalt, rounds: doubleIterations,
                prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), keyLength: 32)
        } else {
            firstStage = passwordData
        }
        let passcodeKey = BackupCrypto.pbkdf2(
            password: firstStage, salt: salt, rounds: iterations,
            prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), keyLength: 32)

        var result: [Int: Data] = [:]
        for (clas, wrapped) in classes {
            if let key = BackupCrypto.aesUnwrap(kek: passcodeKey, wrapped: wrapped) {
                result[clas] = key
            }
        }
        return result
    }
}

/// CommonCrypto primitives used by the backup decryptor.
enum BackupCrypto {
    static func pbkdf2(password: Data, salt: Data, rounds: Int, prf: CCPseudoRandomAlgorithm, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let password = password.isEmpty ? Data([0]) : password  // baseAddress must be non-nil
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress!.assumingMemoryBound(to: CChar.self),
                        password.isEmpty ? 0 : password.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        prf, UInt32(rounds),
                        derivedPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        return status == kCCSuccess ? derived : Data()
    }

    static func aesUnwrap(kek: Data, wrapped: Data) -> Data? {
        var outLength = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var out = Data(count: outLength)
        let status = out.withUnsafeMutableBytes { outPtr in
            wrapped.withUnsafeBytes { wrappedPtr in
                kek.withUnsafeBytes { kekPtr in
                    CCSymmetricKeyUnwrap(
                        CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                        kekPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), kek.count,
                        wrappedPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), wrapped.count,
                        outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), &outLength)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return out.prefix(outLength)
    }

    /// AES-CBC decrypt with a zero IV and no padding (iOS backup file scheme).
    static func aesCBCDecrypt(key: Data, data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let ivData = Data(count: kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return Data() }
        return out.prefix(moved)
    }
}
