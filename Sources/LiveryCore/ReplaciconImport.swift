import Foundation
import SQLite3

public struct ReplaciconRecord {
    public var bundleID: String
    public var name: String
    public var appPath: String
    public var iconUUID: String
    public var sourceURL: String?
    public var sourceName: String?

    public init(bundleID: String, name: String, appPath: String, iconUUID: String, sourceURL: String?, sourceName: String?) {
        self.bundleID = bundleID
        self.name = name
        self.appPath = appPath
        self.iconUUID = iconUUID
        self.sourceURL = sourceURL
        self.sourceName = sourceName
    }
}

public enum ReplaciconImport {
    /// Reads Replacicon's Core Data store. The files are copied first so its root daemon never sees a competing reader.
    public static func records() throws -> [ReplaciconRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.replaciconDB.path) else {
            throw LiveryError("Replacicon database not found at \(Paths.replaciconDB.path)")
        }
        let scratch = fm.temporaryDirectory.appendingPathComponent("livery-replacicon-\(getpid())", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: Paths.replaciconDB.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: scratch.appendingPathComponent("Replacicon.sqlite" + suffix))
        }

        var db: OpaquePointer?
        let dbPath = scratch.appendingPathComponent("Replacicon.sqlite").path
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw LiveryError("sqlite open failed for \(dbPath)")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT a.ZBUNDLEID, a.ZNAME, a.ZURL, hex(a.ZCURRENTUUID), r.ZURL, r.ZSOURCE
        FROM ZAPP a
        LEFT JOIN ZREPLACEMENTICON r ON r.ZDATAUUID = a.ZCURRENTUUID
        WHERE a.ZCURRENTUUID IS NOT NULL AND (a.ZISHIDDEN IS NULL OR a.ZISHIDDEN = 0)
        ORDER BY a.ZNAME
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LiveryError("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }

        var seen = Set<String>()
        var out: [ReplaciconRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func column(_ index: Int32) -> String? {
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            }
            guard let bundleID = column(0), let hexUUID = column(3), !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            let urlString = column(2) ?? ""
            var path = URL(string: urlString)?.path ?? urlString
            if path.hasSuffix("/") { path.removeLast() }
            out.append(ReplaciconRecord(bundleID: bundleID, name: column(1) ?? bundleID, appPath: path,
                                        iconUUID: formatUUID(hexUUID), sourceURL: column(4), sourceName: column(5)))
        }
        return out
    }

    public static func formatUUID(_ hex: String) -> String {
        let characters = Array(hex)
        guard characters.count == 32 else { return hex }
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            .map { String(characters[$0]) }
            .joined(separator: "-")
    }

    /// Full-resolution file has no extension; the .png sibling is only a 144 px preview.
    public static func iconFile(for uuid: String) -> (url: URL, lowRes: Bool)? {
        let full = Paths.replaciconIcons.appendingPathComponent(uuid)
        if FileManager.default.fileExists(atPath: full.path) { return (full, false) }
        let preview = Paths.replaciconIcons.appendingPathComponent(uuid + ".png")
        if FileManager.default.fileExists(atPath: preview.path) { return (preview, true) }
        return nil
    }
}
