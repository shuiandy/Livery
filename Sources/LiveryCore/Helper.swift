import Foundation
import Security

/// App and helper share this interface. Only fixed operations: a path is only ever written as an icon, never executed.
@objc public protocol LiveryHelperProtocol {
    /// Writes the icon file (icns or png) into the app bundle as its custom icon.
    func applyIcon(atPath iconPath: String, toApp appPath: String, reply: @escaping (Bool, String?) -> Void)
    /// Removes the custom icon from the app bundle.
    func resetIcon(ofApp appPath: String, reply: @escaping (Bool, String?) -> Void)
    /// Whether macOS lets the helper write into a bundle owned by root right now. Changes nothing visible.
    func probeAppManagement(reply: @escaping (Bool, String?) -> Void)
    func helperVersion(reply: @escaping (String) -> Void)
}

public enum HelperInfo {
    /// Label of the LaunchDaemon, key under MachServices, and the mach service name the clients dial.
    public static let machServiceName = "com.shuiandy.Livery.helper"
    public static let plistName = "com.shuiandy.Livery.helper.plist"
    /// Bump when the helper's behaviour changes; the app re-registers when the running one is older.
    public static let version = "2"
    /// The identifiers allowed to drive the helper, derived from the helper's own: the app it lives in (its identifier
    /// without the `.helper` suffix) and the command line tool the watcher runs (the app's identifier lowercased). A
    /// fork that renames the app keeps that relation in its install scripts and needs no change here.
    public static func clientIdentifiers(forHelper identifier: String) -> [String] {
        let app = identifier.hasSuffix(".helper") ? String(identifier.dropLast(".helper".count)) : identifier
        return app == app.lowercased() ? [app] : [app, app.lowercased()]
    }

    private static func signingInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }

    /// The team that signed the running binary, read from its own signature rather than written into the source, so a
    /// build signed with somebody else's certificate trusts that person's copy of the app instead of this one's.
    public static func signingTeam() -> String? {
        let team = signingInformation()?[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty ?? true) ? nil : team
    }

    /// The identifier the running binary was signed with.
    public static func signingIdentifier() -> String? {
        let identifier = signingInformation()?[kSecCodeInfoIdentifier as String] as? String
        return (identifier?.isEmpty ?? true) ? nil : identifier
    }

    /// The requirement an incoming XPC connection must satisfy. Nil when this build is ad-hoc signed: without a team
    /// there is nothing to bind to, and anyone can ad-hoc sign a binary claiming these identifiers.
    public static func clientRequirement() -> String? {
        guard let team = signingTeam(), let own = signingIdentifier() else { return nil }
        let identifiers = clientIdentifiers(forHelper: own).map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(identifiers))"
    }
}

/// Sanity checks the helper applies before touching anything as root. The helper is the only part of Livery that
/// can write where the user cannot, so it accepts the narrowest input that still does the job: an installed
/// application, in a folder applications live in, and a file that really is an icon.
public enum HelperGuard {
    /// Where third-party applications live, for the user whose home is `home`. Links are resolved so the comparison
    /// below is made between real locations.
    public static func applicationRoots(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", home + "/Applications"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// The real location of the bundle when it is one Livery manages, nil otherwise. Every link in the path is
    /// resolved first, so a link inside /Applications pointing anywhere else is judged, and written, by where it leads.
    public static func resolvedAppBundle(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let standardized = (path as NSString).standardizingPath
        guard standardized == path, !path.contains("..") else { return nil }
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard resolved.hasSuffix(".app"),
              !resolved.hasPrefix("/System/"), !resolved.hasPrefix("/usr/"), !resolved.hasPrefix("/bin/"),
              FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: resolved + "/Contents/Info.plist") else { return nil }
        // One vendor folder deep covers Setapp and the like; deeper nesting is not something Livery manages.
        let inRoot = applicationRoots(home: home).contains { root in
            guard resolved.hasPrefix(root + "/") else { return false }
            return resolved.dropFirst(root.count + 1).filter { $0 == "/" }.count <= 1
        }
        return inRoot ? resolved : nil
    }

    public static func isAppBundle(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        resolvedAppBundle(path, home: home) != nil
    }

    /// A regular file whose first bytes are an icns or PNG header. Anything else, a pipe included, is not read.
    public static func isIconFile(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path), let head = try? handle.read(upToCount: 8) else { return false }
        try? handle.close()
        return (try? IconFS.imageExtension(for: head)) != nil
    }
}

/// Answers "may this process write into app bundles it does not own?" without changing anything a user can see: it
/// adds a private extended attribute to a bundle owned by root and removes it again. TCC's App Management gate is
/// what refuses such a write, so the outcome of this one is the state of the grant. The setup panel uses it to show a
/// real status light instead of a guess.
public enum HelperProbe {
    public static let attribute = "com.shuiandy.livery.probe"

    /// The first bundle owned by root under an application folder, or nil when there is none, in which case the
    /// helper is never needed on this Mac.
    public static func target(home: String = NSHomeDirectory()) -> String? {
        for root in HelperGuard.applicationRoots(home: home) {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                let path = root + "/" + item
                var info = stat()
                guard stat(path, &info) == 0, info.st_uid == 0,
                      FileManager.default.fileExists(atPath: path + "/Contents/Info.plist") else { continue }
                return path
            }
        }
        return nil
    }

    public static func run(on path: String) -> (allowed: Bool, message: String) {
        let name = (path as NSString).lastPathComponent
        var flag: UInt8 = 1
        guard setxattr(path, attribute, &flag, 1, 0, 0) == 0 else {
            let code = errno
            return (false, "\(name): \(String(cString: strerror(code)))")
        }
        removexattr(path, attribute, 0)
        return (true, name)
    }
}

/// XPC client for the privileged helper. Synchronous with a timeout so the CLI, the agent and detached tasks can all use it.
public enum HelperClient {
    private static let lock = NSLock()
    private static var cachedAvailability: (value: Bool, at: Date)?

    /// Whether the daemon answers right now. Cached for a minute; `forget()` after registering it.
    public static var isAvailable: Bool {
        lock.lock()
        if let cached = cachedAvailability, Date().timeIntervalSince(cached.at) < 60 {
            lock.unlock()
            return cached.value
        }
        lock.unlock()
        let alive = version(timeout: 2) != nil
        lock.lock()
        cachedAvailability = (alive, Date())
        lock.unlock()
        return alive
    }

    public static func forget() {
        lock.lock()
        cachedAvailability = nil
        lock.unlock()
    }

    public static func version(timeout: TimeInterval = 5) -> String? {
        let (ok, value) = call(timeout: timeout) { proxy, finish in
            proxy.helperVersion { version in finish(true, version) }
        }
        return ok ? value : nil
    }

    public static func applyIcon(iconPath: String, appPath: String) throws {
        let (ok, message) = call(timeout: 30) { proxy, finish in
            proxy.applyIcon(atPath: iconPath, toApp: appPath, reply: finish)
        }
        guard ok else { throw LiveryError("helper: " + (message ?? "no answer")) }
    }

    /// True when the helper may write into root-owned bundles; the message names the bundle it tried, or the refusal.
    public static func probeAppManagement() -> (allowed: Bool, message: String?) {
        call(timeout: 10) { proxy, finish in proxy.probeAppManagement(reply: finish) }
    }

    public static func resetIcon(appPath: String) throws {
        let (ok, message) = call(timeout: 30) { proxy, finish in
            proxy.resetIcon(ofApp: appPath, reply: finish)
        }
        guard ok else { throw LiveryError("helper: " + (message ?? "no answer")) }
    }

    /// `.privileged` is mandatory for a LaunchDaemon; without it the lookup goes to the per-user bootstrap and fails.
    private static func call(timeout: TimeInterval,
                             _ body: (LiveryHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) -> (Bool, String?) {
        let connection = NSXPCConnection(machServiceName: HelperInfo.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LiveryHelperProtocol.self)
        let guardian = SyncGuard()
        connection.invalidationHandler = { guardian.finish(false, "the helper is not installed or not enabled") }
        connection.interruptionHandler = { guardian.finish(false, "the helper was interrupted") }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            guardian.finish(false, error.localizedDescription)
        }) as? LiveryHelperProtocol else {
            connection.invalidate()
            return (false, "helper interface unavailable")
        }
        body(proxy) { ok, message in guardian.finish(ok, message) }
        _ = guardian.wait(timeout: timeout)
        connection.invalidate()
        return guardian.result ?? (false, "the helper did not answer in time")
    }

    /// XPC callbacks arrive on arbitrary threads and several can fire for one failure; only the first counts.
    private final class SyncGuard: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var done = false
        private(set) var result: (Bool, String?)?

        func finish(_ ok: Bool, _ message: String?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            result = (ok, message)
            lock.unlock()
            semaphore.signal()
        }

        func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + timeout)
        }
    }
}

/// Direct write first: the calling process (app, CLI, agent) carries its own App Management grant. The root helper is
/// only a fallback for bundles the user does not own, and on a development-signed build TCC refuses it anyway, so the
/// caller shows the one-time `chown` route when both fail.
public enum IconWriter {
    public static func apply(iconFile: URL, to appPath: String) throws -> IconInspection {
        do {
            return try IconFS.apply(iconFile: iconFile, to: appPath)
        } catch let failure as IconWriteError {
            guard case .ownership = failure.block, HelperClient.isAvailable else { throw failure }
            try HelperClient.applyIcon(iconPath: iconFile.path, appPath: appPath)
            let after = IconFS.inspect(appPath, withHash: true)
            guard after.health == .ok else { throw failure }
            return after
        }
    }

    public static func reset(_ appPath: String) throws {
        do {
            try IconFS.reset(appPath)
        } catch let failure as IconWriteError {
            guard case .ownership = failure.block, HelperClient.isAvailable else { throw failure }
            try HelperClient.resetIcon(appPath: appPath)
        }
    }
}
