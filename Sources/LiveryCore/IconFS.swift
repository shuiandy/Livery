import AppKit
import CryptoKit
import Foundation

/// What Finder will actually draw for a bundle right now.
public enum IconHealth: String {
    /// kHasCustomIcon set and Icon\r carries a resource fork.
    case ok
    /// kHasCustomIcon set but Icon\r is gone or its resource fork is empty. Finder draws a folder.
    case folderIcon
    /// kHasCustomIcon cleared: the bundle was replaced wholesale, app shows its own icon.
    case reverted
    case appMissing

    public var needsFix: Bool { self == .folderIcon || self == .reverted }
}

public struct IconInspection {
    public var health: IconHealth
    public var flagSet: Bool
    public var rsrcSize: Int
    public var rsrcSHA256: String?

    public init(health: IconHealth, flagSet: Bool, rsrcSize: Int, rsrcSHA256: String?) {
        self.health = health
        self.flagSet = flagSet
        self.rsrcSize = rsrcSize
        self.rsrcSHA256 = rsrcSHA256
    }
}

/// Why a write into an app bundle was refused. Unix ownership and TCC look identical from setIcon's Bool.
public enum WriteBlock: Equatable {
    /// The bundle folder belongs to another user (App Store and pkg installers often leave root:wheel).
    case ownership(owner: String)
    /// Owned by this user but without the write bit.
    case mode
    case readOnlyVolume
    /// Unix permissions allow the write, so TCC "App Management" is what said no.
    case appManagement
}

public struct IconWriteError: Error, CustomStringConvertible {
    public let appPath: String
    public let block: WriteBlock
    public let operation: String

    public init(appPath: String, block: WriteBlock, operation: String) {
        self.appPath = appPath
        self.block = block
        self.operation = operation
    }

    public var description: String {
        let name = (appPath as NSString).lastPathComponent
        let process = ProcessInfo.processInfo.processName
        switch block {
        case .ownership(let owner):
            return "\(name) is owned by \(owner), so \(process) cannot \(operation) it as a normal user. Run the write as an administrator: sudo livery apply-raw '\(appPath)' <icon> --owner \(getuid())"
        case .mode:
            return "\(name) is not writable by you, so \(process) cannot \(operation) it. Fix with: chmod u+w '\(appPath)'"
        case .readOnlyVolume:
            return "\(name) sits on a read-only volume, so \(process) cannot \(operation) it."
        case .appManagement:
            if getuid() == 0 {
                return "macOS refused to let \(process) \(operation) \(name) even as root: App Management is judged for the app that launched it. Run the same command from Terminal, which holds its own App Management grant."
            }
            return "macOS refused to let \(process) \(operation) \(name). Allow \(process) under System Settings > Privacy & Security > App Management, then quit and reopen it."
        }
    }
}

public enum IconFS {
    public static func iconFilePath(_ appPath: String) -> String { appPath + "/Icon\r" }

    /// Classifies a refused write. Unix permissions are checked first; only when they pass is TCC blamed.
    public static func writeBlock(for appPath: String) -> WriteBlock {
        if access(appPath, W_OK) == 0 { return .appManagement }
        if errno == EROFS { return .readOnlyVolume }
        // root never fails a permission-bit check; only a policy (TCC App Management) says no.
        if getuid() == 0 { return .appManagement }
        var info = stat()
        guard stat(appPath, &info) == 0 else { return .appManagement }
        if info.st_uid != getuid() {
            let owner = getpwuid(info.st_uid).map { String(cString: $0.pointee.pw_name) } ?? "uid \(info.st_uid)"
            return .ownership(owner: owner)
        }
        return .mode
    }
    public static func rsrcPath(_ appPath: String) -> String { iconFilePath(appPath) + "/..namedfork/rsrc" }

    /// FinderInfo is 32 bytes; Finder flags are the big-endian UInt16 at offset 8, kHasCustomIcon is 0x0400.
    public static func hasCustomIconFlag(_ appPath: String) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 32)
        let length = getxattr(appPath, "com.apple.FinderInfo", &buffer, 32, 0, 0)
        guard length >= 10 else { return false }
        return buffer[8] & 0x04 != 0
    }

    public static func rsrcSize(_ appPath: String) -> Int {
        var info = stat()
        guard stat(rsrcPath(appPath), &info) == 0 else { return 0 }
        return Int(info.st_size)
    }

    public static func rsrcSHA256(_ appPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: rsrcPath(appPath)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return nil }
        return sha256(data)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func inspect(_ appPath: String, withHash: Bool = false) -> IconInspection {
        guard FileManager.default.fileExists(atPath: appPath) else {
            return IconInspection(health: .appMissing, flagSet: false, rsrcSize: 0, rsrcSHA256: nil)
        }
        let flag = hasCustomIconFlag(appPath)
        let size = rsrcSize(appPath)
        let hash = (withHash && size > 0) ? rsrcSHA256(appPath) : nil
        let health: IconHealth
        if !flag {
            health = .reverted
        } else if size == 0 {
            health = .folderIcon
        } else {
            health = .ok
        }
        return IconInspection(health: health, flagSet: flag, rsrcSize: size, rsrcSHA256: hash)
    }

    public static func apply(iconFile: URL, to appPath: String) throws -> IconInspection {
        guard let image = NSImage(contentsOf: iconFile) else {
            throw LiveryError("cannot read image \(iconFile.path)")
        }
        guard NSWorkspace.shared.setIcon(image, forFile: appPath, options: []) else {
            throw IconWriteError(appPath: appPath, block: writeBlock(for: appPath), operation: "write the icon into")
        }
        let after = inspect(appPath, withHash: true)
        guard after.health == .ok else {
            throw LiveryError("icon written but \(appPath) reads back as \(after.health.rawValue)")
        }
        return after
    }

    /// After a root write, hand the icon file and the bundle folder back to the user so later repairs need no password. Best effort.
    public static func giveOwnership(of appPath: String, to uid: uid_t) {
        _ = chown(iconFilePath(appPath), uid, gid_t.max)
        _ = chown(appPath, uid, gid_t.max)
    }

    public static func reset(_ appPath: String) throws {
        guard NSWorkspace.shared.setIcon(nil, forFile: appPath, options: []) else {
            throw IconWriteError(appPath: appPath, block: writeBlock(for: appPath), operation: "reset the icon on")
        }
        try? FileManager.default.removeItem(atPath: iconFilePath(appPath))
    }

    /// "icns" or "png" from magic bytes; anything else is refused up front.
    public static func imageExtension(for data: Data) throws -> String {
        if data.starts(with: [0x69, 0x63, 0x6E, 0x73]) { return "icns" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        throw LiveryError("icon data is neither icns nor png")
    }
}

public enum Dock {
    public static func restart() {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            let cache = String(cString: buffer) + "com.apple.dock.iconcache"
            try? FileManager.default.removeItem(atPath: cache)
        }
        _ = try? Shell.run("/usr/bin/killall", ["Dock"])
    }
}
