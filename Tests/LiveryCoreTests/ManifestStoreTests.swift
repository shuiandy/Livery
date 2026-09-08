import AppKit
import Foundation
import Testing
@testable import LiveryCore

/// The manifest is written by three processes (app, command line tool, watcher). These cover the two ways state was
/// lost before: interleaved read-modify-write, and an unreadable file being treated as an empty library.
@Suite(.serialized)
struct ManifestStoreTests {
    /// Points the library at a fresh directory for the duration of one test. Serialised because it moves a global.
    private func inTemporaryLibrary(_ body: () throws -> Void) rethrows {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livery-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("LIVERY_SUPPORT_DIR", directory.path, 1)
        defer {
            unsetenv("LIVERY_SUPPORT_DIR")
            try? FileManager.default.removeItem(at: directory)
        }
        try body()
    }

    private func entry(_ id: String, name: String? = nil) -> IconEntry {
        IconEntry(bundleID: id, name: name ?? id, appPath: "/Applications/\(id).app", iconFile: "\(id).png",
                  source: nil, credit: nil, iconSHA256: "0", appliedRsrcSize: nil, appliedRsrcSHA256: nil,
                  updatedAt: Date())
    }

    @Test func writesAndReadsBack() throws {
        try inTemporaryLibrary {
            try ManifestStore.mutate { $0.upsert(entry("com.a")) }
            #expect(try ManifestStore.read().entries.map(\.bundleID) == ["com.a"])
        }
    }

    @Test func concurrentWritersKeepEveryEntry() throws {
        try inTemporaryLibrary {
            // Before locking, these interleaved and the last writer dropped everyone else's entries.
            let count = 24
            DispatchQueue.concurrentPerform(iterations: count) { index in
                try? ManifestStore.mutate { $0.upsert(entry("com.app\(index)")) }
            }
            let stored = try ManifestStore.read().entries
            #expect(stored.count == count)
            #expect(Set(stored.map(\.bundleID)).count == count)
        }
    }

    @Test func concurrentAddAndRemoveLeaveAConsistentFile() throws {
        try inTemporaryLibrary {
            try ManifestStore.mutate { manifest in
                for index in 0..<10 { manifest.upsert(entry("com.app\(index)")) }
            }
            DispatchQueue.concurrentPerform(iterations: 10) { index in
                if index.isMultiple(of: 2) {
                    try? ManifestStore.mutate { $0.remove(bundleID: "com.app\(index)") }
                } else {
                    try? ManifestStore.mutate { $0.upsert(entry("com.extra\(index)")) }
                }
            }
            let stored = try ManifestStore.read()
            #expect(stored.entries.allSatisfy { !$0.bundleID.isEmpty })
            #expect(Set(stored.entries.map(\.bundleID)).count == stored.entries.count)
        }
    }

    @Test func corruptFileIsQuarantinedNotTreatedAsEmpty() throws {
        try inTemporaryLibrary {
            try ManifestStore.mutate { $0.upsert(entry("com.keep")) }
            try Data("this is not json".utf8).write(to: Paths.manifest)

            // Reading recovers from the backup rather than silently starting from nothing.
            let recovered = try ManifestStore.read()
            #expect(recovered.entries.map(\.bundleID) == ["com.keep"])
            // And the recovery is on disk: a second read must not start from nothing, and a write after it must not
            // copy an empty library over the backup.
            #expect(try ManifestStore.read().entries.map(\.bundleID) == ["com.keep"])
            try ManifestStore.mutate { $0.upsert(entry("com.more")) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backupAfter = try decoder.decode(Manifest.self, from: Data(contentsOf: Paths.manifestBackup))
            #expect(Set(backupAfter.entries.map(\.bundleID)) == ["com.keep", "com.more"])

            // The unreadable bytes are still on disk for inspection.
            let names = try FileManager.default.contentsOfDirectory(atPath: Paths.support.path)
            #expect(names.contains { $0.hasPrefix("manifest.unreadable-") })
        }
    }

    @Test func corruptFileWithoutBackupStartsEmptyButKeepsTheBytes() throws {
        try inTemporaryLibrary {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try Data("{ broken".utf8).write(to: Paths.manifest)
            #expect(try ManifestStore.read().entries.isEmpty)
            let names = try FileManager.default.contentsOfDirectory(atPath: Paths.support.path)
            #expect(names.contains { $0.hasPrefix("manifest.unreadable-") })
        }
    }

    @Test func aNewerSchemaIsRefusedRatherThanOverwritten() throws {
        try inTemporaryLibrary {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            let future = #"{"version": 99, "entries": []}"#
            try Data(future.utf8).write(to: Paths.manifest)

            #expect(throws: (any Error).self) { try ManifestStore.read() }
            #expect(throws: (any Error).self) { try ManifestStore.mutate { $0.upsert(entry("com.a")) } }
            // The file the newer build wrote is still exactly as it was.
            #expect(try String(contentsOf: Paths.manifest, encoding: .utf8) == future)
        }
    }

    @Test func upsertReplacesRatherThanDuplicates() throws {
        try inTemporaryLibrary {
            try ManifestStore.mutate { $0.upsert(entry("com.a", name: "First")) }
            try ManifestStore.mutate { $0.upsert(entry("com.a", name: "Second")) }
            let stored = try ManifestStore.read().entries
            #expect(stored.count == 1)
            #expect(stored[0].name == "Second")
        }
    }

    // MARK: Transactions around a bundle write

    /// A real app bundle in a scratch folder: a directory with an Info.plist naming the identifier.
    private func makeBundle(_ name: String, identifier: String) throws -> AppRef {
        let app = Paths.support.appendingPathComponent("apps/\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return AppRef(path: app.path, bundleID: identifier, name: name)
    }

    private func png(colour: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 48, height: 48), xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private struct Abort: Error {}

    @Test func aCheckpointSurvivesALaterFailure() throws {
        // The only throwing calls here sit inside macros, which closure inference cannot see, hence the annotation.
        try inTemporaryLibrary { () throws -> Void in
            #expect(throws: Abort.self) {
                try ManifestStore.transaction { manifest, checkpoint in
                    manifest.upsert(entry("com.recorded"))
                    try checkpoint(manifest)
                    manifest.upsert(entry("com.never"))
                    throw Abort()
                }
            }
            #expect(try ManifestStore.read().entries.map(\.bundleID) == ["com.recorded"])
        }
    }

    @Test func aSuccessfulStoreRecordsTheIconAndTheWrite() throws {
        try inTemporaryLibrary {
            let app = try makeBundle("Fresh", identifier: "com.livery.tests.fresh")
            let stored = try Commands.store(data: png(colour: .systemBlue), for: app, source: "test", credit: nil)
            #expect(stored.appliedRsrcSize ?? 0 > 0)
            #expect(FileManager.default.fileExists(atPath: stored.iconURL.path))
            #expect(IconFS.inspect(app.path).health == .ok)
            #expect(try ManifestStore.read().entry(for: app.bundleID)?.iconSHA256 == stored.iconSHA256)
            // Nothing set aside is left behind after a clean run.
            let names = try FileManager.default.contentsOfDirectory(atPath: Paths.icons.path)
            #expect(!names.contains { $0.contains(".previous-") || $0.contains(".staging-") })
        }
    }

    @Test func aFailedBundleWriteRollsTheLibraryBack() throws {
        try inTemporaryLibrary {
            let app = try makeBundle("Kept", identifier: "com.livery.tests.kept")
            let first = try Commands.store(data: png(colour: .systemBlue), for: app, source: "first", credit: nil)
            let firstBytes = try Data(contentsOf: first.iconURL)

            // Same identifier, but the bundle is gone: the write cannot succeed.
            let gone = AppRef(path: Paths.support.appendingPathComponent("apps/Gone.app").path,
                              bundleID: app.bundleID, name: "Kept")
            #expect(throws: (any Error).self) {
                try Commands.store(data: png(colour: .systemRed), for: gone, source: "second", credit: nil)
            }
            // Before this was one transaction, the second icon had replaced the kept file with nothing recorded.
            let after = try ManifestStore.read().entry(for: app.bundleID)
            #expect(after?.source == "first")
            #expect(try Data(contentsOf: first.iconURL) == firstBytes)
            let names = try FileManager.default.contentsOfDirectory(atPath: Paths.icons.path)
            #expect(!names.contains { $0.contains(".previous-") || $0.contains(".staging-") })
        }
    }

    @Test func restoreAllPutsEveryAppBackAndForgetsThem() throws {
        try inTemporaryLibrary {
            let one = try makeBundle("One", identifier: "com.livery.tests.one")
            let two = try makeBundle("Two", identifier: "com.livery.tests.two")
            _ = try Commands.store(data: png(colour: .systemBlue), for: one, source: nil, credit: nil)
            _ = try Commands.store(data: png(colour: .systemGreen), for: two, source: nil, credit: nil)
            #expect(IconFS.inspect(one.path).flagSet)
            #expect(IconFS.inspect(two.path).flagSet)

            try Commands.resetAll()

            #expect(try ManifestStore.read().entries.isEmpty)
            #expect(!IconFS.inspect(one.path).flagSet)
            #expect(!IconFS.inspect(two.path).flagSet)
            // The icon files stay, so the same icons can be applied again later.
            let names = try FileManager.default.contentsOfDirectory(atPath: Paths.icons.path)
            #expect(names.contains("com.livery.tests.one.png"))
            #expect(names.contains("com.livery.tests.two.png"))
        }
    }
}
