import Foundation
import Testing
@testable import LiveryCore

/// The helper is the one component that writes where the user cannot, so what it accepts is the security boundary.
@Suite(.serialized)
struct HelperGuardTests {
    private func withBundle(at path: String, _ body: () throws -> Void) rethrows {
        let contents = path + "/Contents"
        try? FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: contents + "/Info.plist", contents: Data("<plist/>".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body()
    }

    @Test func refusesPathsOutsideApplicationFolders() {
        for path in ["/tmp/Evil.app", "/System/Applications/Mail.app", "/usr/local/Evil.app",
                     "/Users/Shared/Evil.app", "/etc"] {
            #expect(!HelperGuard.isAppBundle(path), "\(path) should be refused")
        }
    }

    @Test func refusesTraversalAndUnnormalisedPaths() {
        for path in ["/Applications/../tmp/Evil.app", "/Applications/./Evil.app", "/Applications//Evil.app"] {
            #expect(!HelperGuard.isAppBundle(path), "\(path) should be refused")
        }
    }

    @Test func refusesSomethingThatIsNotABundle() throws {
        let plain = NSHomeDirectory() + "/Applications/livery-test-plain.app"
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Applications",
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plain, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: plain) }
        // A file rather than a directory, and no Info.plist inside it.
        #expect(!HelperGuard.isAppBundle(plain))
    }

    @Test func acceptsAnAppInUserApplications() throws {
        let path = NSHomeDirectory() + "/Applications/LiveryGuardTest.app"
        withBundle(at: path) {
            #expect(HelperGuard.isAppBundle(path))
        }
    }

    @Test func acceptsOneVendorFolderDeepButNotDeeper() throws {
        let shallow = NSHomeDirectory() + "/Applications/Vendor/LiveryGuardTest.app"
        withBundle(at: shallow) {
            #expect(HelperGuard.isAppBundle(shallow))
        }
        let deep = NSHomeDirectory() + "/Applications/Vendor/Nested/LiveryGuardTest.app"
        withBundle(at: deep) {
            #expect(!HelperGuard.isAppBundle(deep))
        }
    }

    @Test func onlyRealImagesCountAsIcons() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livery-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("payload.sh")
        try Data("#!/bin/sh\nrm -rf /\n".utf8).write(to: script)
        #expect(!HelperGuard.isIconFile(script.path))

        let png = directory.appendingPathComponent("real.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        #expect(HelperGuard.isIconFile(png.path))

        let icns = directory.appendingPathComponent("real.icns")
        try Data([0x69, 0x63, 0x6E, 0x73, 0, 0, 0, 8]).write(to: icns)
        #expect(HelperGuard.isIconFile(icns.path))

        #expect(!HelperGuard.isIconFile(directory.appendingPathComponent("absent.png").path))
    }

    @Test func aLinkLeadingOutOfTheApplicationsFolderIsRefused() throws {
        // The link sits in ~/Applications; the bundle it points at does not. Judged by where it leads.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livery-guard-\(UUID().uuidString)/Evil.app", isDirectory: true)
        try withBundle(at: outside.path) {
            let link = NSHomeDirectory() + "/Applications/LiveryGuardLink.app"
            try? FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside.path)
            defer { try? FileManager.default.removeItem(atPath: link) }
            #expect(!HelperGuard.isAppBundle(link))
        }
        try? FileManager.default.removeItem(at: outside.deletingLastPathComponent())
    }

    @Test func aLinkWithinTheApplicationsFolderResolvesToItsTarget() throws {
        let real = NSHomeDirectory() + "/Applications/LiveryGuardReal.app"
        try withBundle(at: real) {
            let link = NSHomeDirectory() + "/Applications/LiveryGuardAlias.app"
            try? FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            defer { try? FileManager.default.removeItem(atPath: link) }
            // The write goes to the real bundle, not through the link.
            #expect(HelperGuard.resolvedAppBundle(link) == URL(fileURLWithPath: real).resolvingSymlinksInPath().path)
        }
    }

    @Test func theCallersOwnApplicationsFolderCounts() throws {
        // The helper runs as root, whose home is /var/root; it judges paths against the caller's home instead.
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livery-home-\(UUID().uuidString)", isDirectory: true)
        let app = home.appendingPathComponent("Applications/Theirs.app").path
        withBundle(at: app) {
            #expect(HelperGuard.isAppBundle(app, home: home.path))
            #expect(!HelperGuard.isAppBundle(app))
        }
        try? FileManager.default.removeItem(at: home)
    }

    @Test func aPipeIsNotAnIconAndIsNotRead() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livery-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = directory.appendingPathComponent("icon.png").path
        #expect(mkfifo(pipe, 0o600) == 0)
        // Reading a FIFO with no writer would block forever; the guard must refuse it by type first.
        #expect(!HelperGuard.isIconFile(pipe))
    }

    @Test func theProbeLeavesNoTraceWhereItIsAllowed() throws {
        let path = NSHomeDirectory() + "/Applications/LiveryProbeTest.app"
        try withBundle(at: path) {
            let result = HelperProbe.run(on: path)
            #expect(result.allowed)
            // The attribute it wrote is gone again. (The bundle may carry others, such as provenance.)
            #expect(getxattr(path, HelperProbe.attribute, nil, 0, 0, 0) == -1)
        }
    }

    @Test func theProbeReportsARefusalByName() {
        let result = HelperProbe.run(on: "/nonexistent/Nothing.app")
        #expect(!result.allowed)
        #expect(result.message.contains("Nothing.app"))
    }

    @Test func theProbeTargetIsOwnedByRootOrAbsent() {
        guard let target = HelperProbe.target() else { return }
        var info = stat()
        #expect(stat(target, &info) == 0)
        #expect(info.st_uid == 0)
        #expect(target.hasSuffix(".app"))
    }

    @Test func clientIdentifiersFollowTheHelpersOwn() {
        #expect(HelperInfo.clientIdentifiers(forHelper: "com.shuiandy.Livery.helper") == ["com.shuiandy.Livery", "com.shuiandy.livery"])
        #expect(HelperInfo.clientIdentifiers(forHelper: "org.example.tool.helper") == ["org.example.tool"])
        #expect(HelperInfo.clientIdentifiers(forHelper: "org.example.Odd") == ["org.example.Odd", "org.example.odd"])
    }
}
