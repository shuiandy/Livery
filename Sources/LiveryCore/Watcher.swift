import CoreServices
import Foundation

public final class Watcher {
    private var stream: FSEventStreamRef?
    private var watching: [String] = []
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let interval: TimeInterval
    private let restartDock: Bool

    public init(debounce: TimeInterval, interval: TimeInterval, restartDock: Bool) {
        self.debounce = debounce
        self.interval = interval
        self.restartDock = restartDock
    }

    /// /Applications, ~/Applications, plus the parent of every tracked app that lives elsewhere (Setapp, vendor folders).
    public static func watchRoots() -> [String] {
        var roots = Set(["/Applications", NSHomeDirectory() + "/Applications"])
        for entry in Manifest.load().entries {
            let parent = (entry.appPath as NSString).deletingLastPathComponent
            if !roots.contains(where: { parent.hasPrefix($0 + "/") || parent == $0 }) { roots.insert(parent) }
        }
        return roots.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
    }

    /// The application folders plus the library itself: a change to the manifest (an app tracked from the GUI, in a
    /// folder nobody was watching yet) is picked up within `debounce` seconds instead of at the next periodic sweep.
    private static func streamPaths() -> [String] {
        watchRoots() + [Paths.support.path].filter { FileManager.default.fileExists(atPath: $0) }
    }

    public func run() -> Never {
        Log.info("livery \(Version.string) starting; debounce \(Int(debounce))s, sweep every \(Int(interval))s")
        if !restartStream(paths: Watcher.streamPaths()) {
            Log.error("file system events are unavailable; relying on the periodic sweep alone")
        }
        DispatchQueue.main.async { self.sweep(reason: "startup") }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in self.sweep(reason: "periodic") }
        RunLoop.main.run()
        exit(0)
    }

    /// Replaces the event stream so it covers `paths`. False when events cannot be delivered.
    private func restartStream(paths: [String]) -> Bool {
        stopStream()
        watching = paths
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            watcher.changed(paths: (array as? [String]) ?? [], count: count)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            Log.error("FSEventStreamCreate failed for \(paths.joined(separator: ", "))")
            return false
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            Log.error("FSEventStreamStart failed for \(paths.joined(separator: ", "))")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        Log.info("watching \(paths.joined(separator: ", "))")
        return true
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func changed(paths: [String], count: Int) {
        let touched = paths.first { $0.contains(".app") } ?? paths.first ?? "?"
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sweep(reason: "fs change near \(touched)") }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func sweep(reason: String) {
        let report = Commands.check(fix: true, verbose: false, quiet: true)
        if report.fixed > 0 || report.failed > 0 {
            Log.info("sweep (\(reason)): fixed \(report.fixed), failed \(report.failed), ok \(report.ok)")
            if report.fixed > 0, restartDock { Dock.restart() }
        }
        // The manifest may name a folder that was not watched yet, or one that no longer needs to be.
        let paths = Watcher.streamPaths()
        if paths != watching, !restartStream(paths: paths) {
            Log.error("file system events are unavailable; relying on the periodic sweep alone")
        }
    }
}
