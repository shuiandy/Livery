import AppKit
import Foundation
import Security
import LiveryCore

/// Root LaunchDaemon registered by Livery.app through SMAppService. It lives inside the app bundle, so TCC
/// attributes its writes to the app's own App Management grant, and it exposes exactly two fixed operations.
final class HelperDelegate: NSObject, NSXPCListenerDelegate, LiveryHelperProtocol {
    private let lock = NSLock()
    private var lastActivity = Date()

    /// launchd starts the daemon on demand; exiting when idle means a reinstalled bundle's new binary takes over by itself.
    func touch() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    var idleSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    private typealias AuditSessionPort = @convention(c) (au_asid_t, UnsafeMutablePointer<mach_port_name_t>) -> Int32
    private typealias AuditSessionJoin = @convention(c) (mach_port_name_t) -> au_asid_t

    /// The audit session is state of this whole process, so writes happen one at a time: a second caller waits rather
    /// than having its write attributed to the first caller's session.
    private let operationLock = NSLock()

    private struct SessionError: Error, CustomStringConvertible {
        let description: String
    }

    /// A LaunchDaemon runs with audit user 0, so TCC resolves App Management against the *system* database, while a
    /// grant made in System Settings is written to the *user's* database. The lookup can never see it, which is why
    /// tccd answers "auth_value absent" no matter what the user approves. Joining the calling user's audit session
    /// moves the lookup into their database, where their grant lives. Root is allowed to do this; the symbols ship in
    /// libSystem but are not declared in the public headers, so they are resolved at runtime. A join that does not
    /// happen is an error, not a shrug: the write would otherwise run in whatever session this process was left in.
    private func joinSession(of connection: NSXPCConnection) throws {
        let asid = connection.auditSessionIdentifier
        guard asid != 0 else { throw SessionError(description: "the caller has no audit session") }
        guard let portSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "audit_session_port"),
              let joinSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "audit_session_join") else {
            throw SessionError(description: "audit session functions are unavailable on this system")
        }
        let sessionPort = unsafeBitCast(portSymbol, to: AuditSessionPort.self)
        let sessionJoin = unsafeBitCast(joinSymbol, to: AuditSessionJoin.self)
        var port = mach_port_name_t(MACH_PORT_NULL)
        guard sessionPort(asid, &port) == 0, port != mach_port_name_t(MACH_PORT_NULL) else {
            throw SessionError(description: "could not open audit session \(asid)")
        }
        defer { mach_port_deallocate(mach_task_self_, port) }
        guard sessionJoin(port) == asid else { throw SessionError(description: "could not join audit session \(asid)") }
    }

    /// Joins the session of the connection the current message arrived on, immediately before the write it authorises.
    /// Doing it at connection time instead would change this process's audit session before any message had been
    /// checked, and would leave the process sitting in a caller's session long after that caller went away.
    private func joinSessionOfCurrentCall() throws {
        guard let connection = NSXPCConnection.current() else { throw SessionError(description: "no current connection") }
        try joinSession(of: connection)
    }

    /// The caller's home folder, so its own ~/Applications counts as a place apps live. This process's home is /var/root.
    private func callerHome() -> String {
        guard let connection = NSXPCConnection.current(),
              let record = getpwuid(connection.effectiveUserIdentifier) else { return NSHomeDirectory() }
        return String(cString: record.pointee.pw_dir)
    }

    /// Whether the binary this process was started from is still the one on disk. A reinstall replaces the bundle
    /// while the old daemon keeps running; from then on its own signature no longer reads, so it could only refuse
    /// every caller, and each refused caller would have kept it alive. Exiting hands the next connection to launchd,
    /// which spawns the new binary.
    static func exitIfReplaced() {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess,
              HelperInfo.clientRequirement() != nil else {
            exit(0)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        HelperDelegate.exitIfReplaced()
        // The code-signing requirement is the only gate between "any local process" and root writes into app bundles.
        // It names the team that signed this helper, so a build made from a fork with another certificate trusts that
        // build's own app. An ad-hoc build has no team to bind to, and every connection is refused; a refused
        // connection does not count as activity, so a daemon nobody can talk to still goes away.
        guard let requirement = HelperInfo.clientRequirement() else { return false }
        touch()
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: LiveryHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func applyIcon(atPath iconPath: String, toApp appPath: String, reply: @escaping (Bool, String?) -> Void) {
        touch()
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let app = HelperGuard.resolvedAppBundle(appPath, home: callerHome()) else {
            reply(false, "\(appPath) is not an app bundle Livery manages")
            return
        }
        guard HelperGuard.isIconFile(iconPath) else { reply(false, "\(iconPath) is not an icns or png file"); return }
        do {
            try joinSessionOfCurrentCall()
            _ = try IconFS.apply(iconFile: URL(fileURLWithPath: iconPath), to: app)
            reply(true, nil)
        } catch {
            reply(false, "\(error)")
        }
    }

    func resetIcon(ofApp appPath: String, reply: @escaping (Bool, String?) -> Void) {
        touch()
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let app = HelperGuard.resolvedAppBundle(appPath, home: callerHome()) else {
            reply(false, "\(appPath) is not an app bundle Livery manages")
            return
        }
        do {
            try joinSessionOfCurrentCall()
            try IconFS.reset(app)
            reply(true, nil)
        } catch {
            reply(false, "\(error)")
        }
    }

    func probeAppManagement(reply: @escaping (Bool, String?) -> Void) {
        touch()
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let target = HelperProbe.target(home: callerHome()) else {
            reply(true, "no app owned by root")
            return
        }
        do {
            try joinSessionOfCurrentCall()
            let result = HelperProbe.run(on: target)
            reply(result.allowed, result.message)
        } catch {
            reply(false, "\(error)")
        }
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: HelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()
HelperDelegate.exitIfReplaced()
let idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
    HelperDelegate.exitIfReplaced()
    if delegate.idleSeconds > 90 { exit(0) }
}
RunLoop.main.run()
