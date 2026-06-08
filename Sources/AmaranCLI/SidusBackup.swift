import Foundation
import SQLite3
import AmaranCore

/// Sources of Sidus mesh JSON files from a backup, ported from
/// `scripts/sidus-backup-import`. Extracted-container and unencrypted backups are
/// read natively; encrypted backups are decrypted by the thin Python helper.
public enum SidusBackup {
    static let appDomains = ["AppDomain-com.aputure.cn.SidusLink", "AppDomain-com.siduslink.cn.Acrux.hd"]

    enum SourceError: Error { case notADatabase }

    public static func loadMeshFiles(backupPath: String) throws -> [SidusMeshFile] {
        let extracted = extractedMeshFiles(backupPath)
        if !extracted.isEmpty { return extracted }

        guard let backupDir = findBackupDir(backupPath) else {
            throw CLIError("backup path does not look like an iPad backup or extracted Sidus app container")
        }
        do {
            return try unencryptedMeshFiles(backupDir)
        } catch SourceError.notADatabase {
            return try encryptedMeshFiles(backupDir: backupDir)
        }
    }

    // MARK: - Extracted app container

    static func extractedMeshFiles(_ backupPath: String) -> [SidusMeshFile] {
        let root = URL(fileURLWithPath: (backupPath as NSString).expandingTildeInPath).standardizedFileURL
        let fm = FileManager.default
        var rows: [SidusMeshFile] = []

        for domain in appDomains {
            let meshDir = root.appendingPathComponent(domain).appendingPathComponent("Documents/mesh")
            guard let names = try? fm.contentsOfDirectory(atPath: meshDir.path) else { continue }
            for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
                let url = meshDir.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url) {
                    rows.append(SidusMeshFile(domain: domain, relativePath: "Documents/mesh/\(name)", data: data))
                }
            }
        }
        if !rows.isEmpty { return rows }

        // Fallback: recursively find any Documents/mesh/*.json.
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return rows }
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let parent = url.deletingLastPathComponent()
            guard parent.lastPathComponent == "mesh",
                parent.deletingLastPathComponent().lastPathComponent == "Documents",
                let data = try? Data(contentsOf: url)
            else { continue }
            let domain = url.pathComponents.first { appDomains.contains($0) } ?? "extracted"
            rows.append(SidusMeshFile(domain: domain, relativePath: url.path, data: data))
        }
        return rows
    }

    // MARK: - Backup directory discovery

    static func findBackupDir(_ path: String) -> URL? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        func isBackup(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("Manifest.plist").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("Manifest.db").path)
        }
        if isBackup(root) { return root }
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        let candidates = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && fm.fileExists(atPath: $0.appendingPathComponent("Manifest.plist").path)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: - Unencrypted backup (SQLite)

    static func unencryptedMeshFiles(_ backupDir: URL) throws -> [SidusMeshFile] {
        let manifest = backupDir.appendingPathComponent("Manifest.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(manifest, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw SourceError.notADatabase
        }
        defer { sqlite3_close(db) }

        let sql = """
        select fileID, domain, relativePath from Files
        where flags = 1 and domain in (?, ?) and relativePath like 'Documents/mesh/%.json'
        order by domain, relativePath
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SourceError.notADatabase
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, appDomains[0], -1, transient)
        sqlite3_bind_text(stmt, 2, appDomains[1], -1, transient)

        var rows: [SidusMeshFile] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SourceError.notADatabase }
            guard let fileIDc = sqlite3_column_text(stmt, 0),
                let domainc = sqlite3_column_text(stmt, 1),
                let relc = sqlite3_column_text(stmt, 2) else { continue }
            let fileID = String(cString: fileIDc)
            let domain = String(cString: domainc)
            let relativePath = String(cString: relc)
            let fileURL = backupDir.appendingPathComponent(String(fileID.prefix(2)))
                .appendingPathComponent(fileID)
            if let data = try? Data(contentsOf: fileURL) {
                rows.append(SidusMeshFile(domain: domain, relativePath: relativePath, data: data))
            }
        }
        return rows
    }

    // MARK: - Encrypted backup (native CommonCrypto)

    static func encryptedMeshFiles(backupDir: URL) throws -> [SidusMeshFile] {
        let password = ProcessInfo.processInfo.environment["AMARAN_IOS_BACKUP_PASSWORD"]
            ?? String(cString: getpass("iPad backup password: "))
        return try IosBackupDecrypt.meshFiles(
            backupDir: backupDir, passphrase: password, domains: appDomains)
    }
}
