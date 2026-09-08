import Foundation

public struct IconEntry: Codable {
    public var bundleID: String
    public var name: String
    public var appPath: String
    public var iconFile: String
    public var source: String?
    public var credit: String?
    public var iconSHA256: String
    public var appliedRsrcSize: Int?
    public var appliedRsrcSHA256: String?
    public var updatedAt: Date

    public init(bundleID: String, name: String, appPath: String, iconFile: String, source: String?, credit: String?,
                iconSHA256: String, appliedRsrcSize: Int?, appliedRsrcSHA256: String?, updatedAt: Date) {
        self.bundleID = bundleID
        self.name = name
        self.appPath = appPath
        self.iconFile = iconFile
        self.source = source
        self.credit = credit
        self.iconSHA256 = iconSHA256
        self.appliedRsrcSize = appliedRsrcSize
        self.appliedRsrcSHA256 = appliedRsrcSHA256
        self.updatedAt = updatedAt
    }

    /// Nil when the stored name would resolve outside the icon folder, which a hostile bundle identifier could ask for.
    public var iconURL: URL { (try? Paths.iconURL(forFile: iconFile)) ?? Paths.icons.appendingPathComponent("invalid") }
}

public struct Manifest: Codable {
    /// Bumped when the on-disk shape changes. A file claiming a higher number is left alone rather than rewritten.
    public static let currentVersion = 1

    public var version: Int = currentVersion
    public var entries: [IconEntry] = []

    public init() {}

    public mutating func upsert(_ entry: IconEntry) {
        if let index = entries.firstIndex(where: { $0.bundleID == entry.bundleID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func remove(bundleID: String) {
        entries.removeAll { $0.bundleID == bundleID }
    }

    public func entry(for bundleID: String) -> IconEntry? {
        entries.first { $0.bundleID == bundleID }
    }

    /// Convenience for read-only callers. A manifest that cannot be read comes back empty, but never silently: the
    /// unreadable file has been moved aside by then, so the next write starts from a known state instead of a guess.
    public static func load() -> Manifest {
        (try? ManifestStore.read()) ?? Manifest()
    }

    /// Replaces the whole file. Prefer `ManifestStore.mutate`, which reads and writes under one lock.
    public func save() throws {
        try ManifestStore.write(self)
    }
}

/// Serialises every read-modify-write of the manifest across the app, the CLI and the watcher. Without this the three
/// of them interleave `load → change → save` and the last writer silently drops the others' entries.
public enum ManifestStore {
    private static let processLock = NSLock()

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func read() throws -> Manifest {
        try locked(exclusive: false) { try readUnlocked() }
    }

    public static func write(_ manifest: Manifest) throws {
        try locked(exclusive: true) { try writeUnlocked(manifest) }
    }

    /// Reads, applies `body`, and writes back, all inside one exclusive lock.
    @discardableResult
    public static func mutate<T>(_ body: (inout Manifest) throws -> T) throws -> T {
        try locked(exclusive: true) {
            var manifest = try readUnlocked()
            let result = try body(&manifest)
            try writeUnlocked(manifest)
            return result
        }
    }

    /// Like `mutate`, but `checkpoint` writes the manifest part-way through, with the lock still held. A step that
    /// changes the world outside the manifest (writing into an app bundle) records its intent first, does the step, then
    /// records the result: whichever half fails, the file on disk describes a state `check --fix` can act on.
    @discardableResult
    public static func transaction<T>(_ body: (inout Manifest, _ checkpoint: (Manifest) throws -> Void) throws -> T) throws -> T {
        try locked(exclusive: true) {
            var manifest = try readUnlocked()
            let result = try body(&manifest) { try writeUnlocked($0) }
            try writeUnlocked(manifest)
            return result
        }
    }

    // MARK: Locking

    /// `flock` blocks other processes; the in-process lock covers threads, which share the file lock and would
    /// otherwise deadlock on a second descriptor. Never nest these calls.
    private static func locked<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        try Paths.ensureDirectories()
        processLock.lock()
        defer { processLock.unlock() }
        let descriptor = open(Paths.manifestLock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else { return try body() }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func readUnlocked() throws -> Manifest {
        guard let data = try? Data(contentsOf: Paths.manifest), !data.isEmpty else { return Manifest() }
        do {
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.version <= Manifest.currentVersion else {
                throw LiveryError("""
                    \(Paths.manifest.path) was written by a newer Livery (format \(manifest.version), this build \
                    understands \(Manifest.currentVersion)). Update Livery rather than letting it overwrite the file.
                    """)
            }
            return manifest
        } catch let failure as LiveryError {
            throw failure
        } catch {
            // Corrupt, not merely absent: keep the bytes so nothing is lost, and let the caller start from empty.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = Paths.support.appendingPathComponent("manifest.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: Paths.manifest, to: quarantine)
            if let backup = try? Data(contentsOf: Paths.manifestBackup),
               let recovered = try? decoder.decode(Manifest.self, from: backup) {
                // Put the recovered bytes where the manifest lives. Without this the next read finds nothing, starts
                // empty, and the next write copies that emptiness over the backup: the recovery would undo itself.
                try? backup.write(to: Paths.manifest, options: .atomic)
                Log.error("manifest.json was unreadable (\(error)); kept it as \(quarantine.lastPathComponent) and recovered the previous copy")
                return recovered
            }
            Log.error("manifest.json was unreadable (\(error)); kept it as \(quarantine.lastPathComponent) and started empty")
            return Manifest()
        }
    }

    private static func writeUnlocked(_ manifest: Manifest) throws {
        var manifest = manifest
        manifest.version = Manifest.currentVersion
        let data = try encoder.encode(manifest)
        // An unchanged manifest is not rewritten: the watcher reacts to changes in this folder, and a sweep that
        // touched nothing must not look like one.
        if let current = try? Data(contentsOf: Paths.manifest), current == data { return }
        try data.write(to: Paths.manifest, options: .atomic)
        // Copy after the write, not before: a library that has only ever been written once would otherwise have no
        // known-good copy to fall back on when something later corrupts the file.
        try? FileManager.default.removeItem(at: Paths.manifestBackup)
        try? FileManager.default.copyItem(at: Paths.manifest, to: Paths.manifestBackup)
    }
}
