import Foundation

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    /// `LIVERY_SUPPORT_DIR` moves the whole library elsewhere. Tests set it so they never touch the real one;
    /// it is read on every access rather than captured once so a test can point it at a fresh directory.
    public static var support: URL {
        if let override = ProcessInfo.processInfo.environment["LIVERY_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/Livery", isDirectory: true)
    }

    public static var icons: URL { support.appendingPathComponent("icons", isDirectory: true) }
    public static var manifest: URL { support.appendingPathComponent("manifest.json") }
    public static var manifestBackup: URL { support.appendingPathComponent("manifest.backup.json") }
    /// Advisory lock every reader and writer takes, so the app, the CLI and the watcher cannot lose each other's edits.
    public static var manifestLock: URL { support.appendingPathComponent(".manifest.lock") }

    public static var caches: URL {
        if let override = ProcessInfo.processInfo.environment["LIVERY_CACHE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Caches/Livery", isDirectory: true)
    }

    public static var lastSearch: URL { caches.appendingPathComponent("last-search.json") }
    public static let apiKeyFile = home.appendingPathComponent(".config/livery/api-key")
    public static let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.shuiandy.livery.plist")
    public static let logFile = home.appendingPathComponent("Library/Logs/livery.log")
    public static let replaciconDB = URL(fileURLWithPath: "/Users/Shared/.Replacicon/Replacicon.sqlite")
    public static let replaciconIcons = URL(fileURLWithPath: "/Users/Shared/.Replacicon/Icons", isDirectory: true)

    public static func ensureDirectories() throws {
        for dir in [support, icons, caches, apiKeyFile.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static let stemAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    /// A bundle identifier is read out of another app's Info.plist, so it is attacker-controlled, and Livery uses
    /// it as a file name. `../` in one would otherwise write outside the icon folder. Anything unusual is folded to
    /// `_` and a digest of the original is appended, which keeps distinct identifiers distinct; identifiers that were
    /// already safe (every real one) come back untouched, so existing files keep their names.
    public static func safeStem(_ bundleID: String) -> String {
        var cleaned = String(bundleID.map { stemAllowed.contains($0) ? $0 : "_" })
        // A dot run is legal in a file name but never appears in a real identifier, and folding it keeps the result
        // obviously incapable of naming a parent directory.
        while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: "__") }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
        if cleaned.isEmpty { cleaned = "app" }
        guard cleaned != bundleID else { return cleaned }
        return cleaned + "-" + String(IconFS.sha256(Data(bundleID.utf8)).prefix(8))
    }

    /// Whether a stored name is a single ordinary file inside the icon folder. Pure, so it can be reasoned about and
    /// tested without touching the filesystem.
    public static func isPlainIconFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"), !name.hasPrefix(".") else { return false }
        return true
    }

    /// Resolves a stored icon file name against the icon folder and refuses anything that escapes it.
    public static func iconURL(forFile name: String) throws -> URL {
        guard isPlainIconFileName(name) else {
            throw LiveryError("\(name) is not a plain icon file name")
        }
        // One read of the folder: it is computed, and reading it twice could straddle a change.
        let root = icons.standardizedFileURL
        let url = root.appendingPathComponent(name).standardizedFileURL
        guard url.deletingLastPathComponent().path == root.path else {
            throw LiveryError("icon file name \(name) points outside \(root.path)")
        }
        return url
    }
}

public struct LiveryError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func info(_ message: String) {
        print("[\(formatter.string(from: Date()))] \(message)")
        fflush(stdout)
    }

    public static func error(_ message: String) {
        FileHandle.standardError.write("[\(formatter.string(from: Date()))] error: \(message)\n".data(using: .utf8)!)
    }
}

public enum Shell {
    @discardableResult
    public static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LiveryError("\(launchPath) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
