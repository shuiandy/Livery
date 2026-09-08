import Foundation
import LiveryCore

let usage = """
livery \(Version.string): custom app icons that survive app updates

  search <query> [--page N] [--limit N] [--no-preview] [--raw] [--source iconic|macosicons]
        query the icon catalog (50 per page); opens a numbered contact sheet of the first N (default 24)
        iconic (default) needs no key; macosicons needs one and allows 50 calls a month on the free plan
  set <app> --pick <#> | --file <icns|png> | --url <url> [--restart-dock]
        apply an icon and start tracking the app
  reset <app> | --all    put the app back to its own icon and stop tracking; --all does every tracked app
  info <app>             show flag, resource fork, health
  list                   tracked apps with current health
  check [--fix] [--verbose] [--restart-dock]
        verify every tracked app; --fix rewrites the ones Finder would draw wrong
  import-replacicon [--apply]
        pull current icons out of Replacicon's store; --apply also repairs broken ones
  watch [--debounce S] [--interval S] [--restart-dock]
        foreground watcher (what the launch agent runs)
  agent install|uninstall|start|status [--restart-dock]
  key <KEY>              store the macosicons API key (or export MACOSICONS_API_KEY)
  apply-raw <app path> <icns|png> [--owner UID]
        write one icon into a bundle and nothing else; the app runs this as root for root-owned bundles
  reset-raw <app path> [--owner UID]
  refit [--apply]        rescale kept icons that fill the whole canvas onto the macOS icon grid

<app> is a display name (Google Chrome), a bundle id, or a path to the .app
"""

struct Args {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["page", "limit", "pick", "file", "url", "debounce", "interval", "owner", "source"]
    static let known: Set<String> = ["fix", "verbose", "apply", "all", "no-preview", "raw", "restart-dock",
                                     "version", "help"]

    /// Unknown options are refused rather than ignored: a mistyped `--fixx` that silently did nothing would look like
    /// the command had run.
    init(_ raw: [String]) throws {
        var iterator = raw.makeIterator()
        while let token = iterator.next() {
            guard token.hasPrefix("--") else {
                positionals.append(token)
                continue
            }
            let name = String(token.dropFirst(2))
            if let equals = name.firstIndex(of: "=") {
                let key = String(name[..<equals])
                guard Args.valued.contains(key) else { throw LiveryError("unknown option --\(key)") }
                options[key] = String(name[name.index(after: equals)...])
            } else if Args.valued.contains(name) {
                guard let value = iterator.next() else { throw LiveryError("--\(name) needs a value") }
                options[name] = value
            } else if Args.known.contains(name) {
                flags.insert(name)
            } else {
                throw LiveryError("unknown option --\(name)")
            }
        }
    }

    /// A value that does not parse is an error, not the default: `--limit ten` quietly showing 24 would look like
    /// the command had done what was asked.
    func int(_ name: String, default value: Int) throws -> Int {
        try optionalInt(name) ?? value
    }

    func optionalInt(_ name: String) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let parsed = Int(raw) else { throw LiveryError("--\(name) needs a whole number, got '\(raw)'") }
        return parsed
    }

    func double(_ name: String, default value: Double) throws -> Double {
        guard let raw = options[name] else { return value }
        guard let parsed = Double(raw), parsed.isFinite, parsed >= 0 else {
            throw LiveryError("--\(name) needs a number of seconds, got '\(raw)'")
        }
        return parsed
    }

    /// A process owner: a whole number that fits a uid.
    func owner() throws -> uid_t? {
        guard let value = try optionalInt("owner") else { return nil }
        guard value >= 0, value <= Int(UInt32.max) else { throw LiveryError("--owner needs a uid, got \(value)") }
        return uid_t(value)
    }

    /// Everything from `index` on, joined: `livery set Google Chrome --pick 1` names one app, not two.
    func rest(from index: Int, _ what: String) throws -> String {
        guard index < positionals.count else { throw LiveryError("missing \(what)\n\n\(usage)") }
        return positionals[index...].joined(separator: " ")
    }

    func positional(_ index: Int, _ what: String) throws -> String {
        guard index < positionals.count else { throw LiveryError("missing \(what)\n\n\(usage)") }
        return positionals[index]
    }
}

func main() -> Int32 {
    let raw = Array(CommandLine.arguments.dropFirst())
    if raw.isEmpty {
        print(usage)
        return 0
    }
    let args: Args
    do {
        args = try Args(raw)
    } catch {
        Log.error("\(error)")
        return 2
    }
    // Asking for help or the version is a successful run, once the whole line has parsed: `--version --bogus` is a
    // mistake worth reporting, not a success.
    if args.flags.contains("help") || ["help", "-h"].contains(args.positionals.first) {
        print(usage)
        return 0
    }
    if args.flags.contains("version") || args.positionals.first == "version" {
        print(Version.string)
        return 0
    }
    guard let command = args.positionals.first else {
        print(usage)
        return 2
    }
    do {
        switch command {
        case "search":
            let query = args.positionals.dropFirst().joined(separator: " ")
            guard !query.isEmpty else { throw LiveryError("missing query") }
            let source = try args.options["source"].map { name -> IconSource in
                guard let parsed = IconSource(rawValue: name) else { throw LiveryError("--source must be iconic or macosicons") }
                return parsed
            } ?? .iconic
            try Commands.search(query: query, page: try args.int("page", default: 1), limit: try args.int("limit", default: 24),
                                preview: !args.flags.contains("no-preview"), raw: args.flags.contains("raw"), source: source)
        case "set":
            try Commands.set(appQuery: try args.rest(from: 1, "app"), pick: try args.optionalInt("pick"),
                             file: args.options["file"], urlString: args.options["url"],
                             restartDock: args.flags.contains("restart-dock"))
        case "reset":
            if args.flags.contains("all") {
                try Commands.resetAll()
            } else {
                try Commands.reset(appQuery: try args.rest(from: 1, "app"))
            }
        case "info":
            try Commands.info(appQuery: try args.rest(from: 1, "app"))
        case "list":
            Commands.list()
        case "check":
            let report = Commands.check(fix: args.flags.contains("fix"), verbose: args.flags.contains("verbose"))
            if report.fixed > 0, args.flags.contains("restart-dock") { Dock.restart() }
            // An app Livery can no longer find is a problem worth a non-zero status, not just a line of output.
            return (report.failed > 0 || report.missing > 0) ? 1 : 0
        case "import-replacicon":
            try Commands.importReplacicon(apply: args.flags.contains("apply"))
        case "watch":
            Watcher(debounce: try args.double("debounce", default: 5), interval: try args.double("interval", default: 600),
                    restartDock: args.flags.contains("restart-dock")).run()
        case "agent":
            switch try args.positional(1, "install|uninstall|start|status") {
            case "start":
                try LaunchAgent.start()
                LaunchAgent.status()
            case "install":
                let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
                try LaunchAgent.install(binary: binary, restartDock: args.flags.contains("restart-dock"))
            case "uninstall":
                try LaunchAgent.uninstall()
            case "status":
                LaunchAgent.status()
            default:
                throw LiveryError("agent install|uninstall|start|status")
            }
        case "refit":
            try Commands.refit(apply: args.flags.contains("apply"))
        case "apply-raw":
            let appPath = (try args.positional(1, "app path") as NSString).standardizingPath
            let iconPath = (try args.positional(2, "icon file") as NSString).expandingTildeInPath
            let state = try IconFS.apply(iconFile: URL(fileURLWithPath: iconPath), to: appPath)
            if let owner = try args.owner() { IconFS.giveOwnership(of: appPath, to: owner) }
            print("ok \(state.rsrcSize) \(state.rsrcSHA256 ?? "-")")
        case "reset-raw":
            let appPath = (try args.positional(1, "app path") as NSString).standardizingPath
            try IconFS.reset(appPath)
            if let owner = try args.owner() { _ = chown(appPath, owner, gid_t.max) }
            print("ok")
        case "key":
            try MacOSIcons.saveKey(try args.positional(1, "API key"))
            print("saved to \(Paths.apiKeyFile.path)")
        default:
            throw LiveryError("unknown command '\(command)'\n\n\(usage)")
        }
    } catch {
        Log.error("\(error)")
        return 1
    }
    return 0
}

exit(main())
