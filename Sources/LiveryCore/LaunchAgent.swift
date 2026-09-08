import Foundation

public enum LaunchAgent {
    public static let label = "com.shuiandy.livery"

    public static func install(binary: String, restartDock: Bool) throws {
        var arguments = [binary, "watch"]
        if restartDock { arguments.append("--restart-dock") }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": Paths.logFile.path,
            "StandardErrorPath": Paths.logFile.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? uninstall(quiet: true)
        try FileManager.default.createDirectory(at: Paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Paths.launchAgent)
        try Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", Paths.launchAgent.path])
        print("installed \(Paths.launchAgent.path)")
        print("running: \(arguments.joined(separator: " "))")
        print("log: \(Paths.logFile.path)")
    }

    public static func uninstall(quiet: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: Paths.launchAgent.path) else {
            if !quiet { print("not installed") }
            return
        }
        _ = try? Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try FileManager.default.removeItem(at: Paths.launchAgent)
        if !quiet { print("removed \(Paths.launchAgent.path)") }
    }

    /// Brings an installed agent back when launchd has it stopped: crashed past its restart budget, or booted out by hand.
    public static func start() throws {
        guard FileManager.default.fileExists(atPath: Paths.launchAgent.path) else { throw LiveryError("the agent is not installed") }
        // bootstrap fails harmlessly when the job is already loaded; kickstart then (re)starts the process either way.
        _ = try? Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", Paths.launchAgent.path])
        try Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    public struct Info {
        public var installed: Bool
        public var loaded: Bool
        public var pid: Int?
        public var state: String?
        public var program: String?

        public init(installed: Bool, loaded: Bool, pid: Int? = nil, state: String? = nil, program: String? = nil) {
            self.installed = installed
            self.loaded = loaded
            self.pid = pid
            self.state = state
            self.program = program
        }
    }

    /// What launchctl knows about the agent right now.
    public static func probe() -> Info {
        var info = Info(installed: FileManager.default.fileExists(atPath: Paths.launchAgent.path), loaded: false)
        guard let output = try? Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) else { return info }
        info.loaded = true
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") { info.pid = Int(trimmed.dropFirst(6)) }
            else if trimmed.hasPrefix("state = "), info.state == nil { info.state = String(trimmed.dropFirst(8)) }
            else if trimmed.hasPrefix("program = ") { info.program = String(trimmed.dropFirst(10)) }
        }
        return info
    }

    public static func status() {
        guard let output = try? Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) else {
            print("\(label): not loaded")
            return
        }
        let interesting = ["state =", "pid =", "last exit code =", "program ="]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if interesting.contains(where: { trimmed.hasPrefix($0) }) { print(trimmed) }
        }
    }
}
