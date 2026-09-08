import AppKit
import Foundation

public struct AppRef: Identifiable {
    public var id: String { bundleID }
    public let path: String
    public let bundleID: String
    public let name: String

    public init(path: String, bundleID: String, name: String) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
    }
}

public enum AppLocator {
    public static let searchRoots: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
    ]

    /// Accepts a path to a bundle, a bundle identifier, or a display name such as "Google Chrome".
    public static func resolve(_ query: String) throws -> AppRef {
        let expanded = (query as NSString).expandingTildeInPath
        if expanded.hasSuffix(".app"), FileManager.default.fileExists(atPath: expanded) {
            return try ref(forPath: (expanded as NSString).standardizingPath)
        }
        if query.contains("."), !query.contains("/"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            return try ref(forPath: url.path)
        }
        let wanted = query.lowercased().hasSuffix(".app") ? query.lowercased() : query.lowercased() + ".app"
        var candidates: [String] = []
        for root in searchRoots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let full = root + "/" + item
                if item.lowercased() == wanted {
                    candidates.append(full)
                    continue
                }
                // One level of vendor folders such as /Applications/Setapp.
                if !item.hasSuffix(".app"), let children = try? FileManager.default.contentsOfDirectory(atPath: full) {
                    for child in children where child.lowercased() == wanted {
                        candidates.append(full + "/" + child)
                    }
                }
            }
        }
        if let first = candidates.first { return try ref(forPath: first) }
        throw LiveryError("no app named '\(query)' under \(searchRoots.joined(separator: ", ")). Pass a full path or a bundle id.")
    }

    public static func ref(forPath path: String) throws -> AppRef {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else {
            throw LiveryError("\(path) is not an app bundle with a bundle identifier")
        }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return AppRef(path: path, bundleID: id, name: name)
    }

    /// Recorded path first, provided the bundle there still carries the same identifier: an app can be removed and
    /// another put in its place under the same name. Then LaunchServices, in case the app moved.
    public static func currentPath(for entry: IconEntry) -> String? {
        if bundleIdentifier(at: entry.appPath) == entry.bundleID { return entry.appPath }
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)?.path,
              bundleIdentifier(at: found) == entry.bundleID else { return nil }
        return found
    }

    /// Read from Info.plist directly: `Bundle(path:)` caches by path for the life of the process, and the watcher lives
    /// long enough to see a bundle replaced.
    public static func bundleIdentifier(at path: String) -> String? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
    }
}
