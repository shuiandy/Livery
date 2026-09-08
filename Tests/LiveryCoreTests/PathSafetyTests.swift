import Foundation
import Testing
@testable import LiveryCore

/// A bundle identifier comes out of another app's Info.plist, so it is attacker-controlled and must never be able to
/// steer a write out of the icon folder.
struct PathSafetyTests {
    @Test func ordinaryIdentifiersAreUnchanged() {
        // Existing libraries name their files after the identifier; that must keep working byte for byte.
        #expect(Paths.safeStem("com.apple.Safari") == "com.apple.Safari")
        #expect(Paths.safeStem("so.amie.electron-app-setapp") == "so.amie.electron-app-setapp")
        #expect(Paths.safeStem("com.microsoft.VSCode") == "com.microsoft.VSCode")
    }

    @Test func traversalIsFolded() {
        for hostile in ["../../etc/passwd", "..", "../evil", "a/../../b", "/etc/passwd"] {
            let stem = Paths.safeStem(hostile)
            #expect(!stem.contains("/"))
            #expect(!stem.contains(".."))
            #expect(!stem.hasPrefix("."))
        }
    }

    @Test func distinctHostileIdentifiersStayDistinct() {
        // Folding to `_` alone would collide; the appended digest keeps them apart.
        #expect(Paths.safeStem("../a") != Paths.safeStem("../b"))
        #expect(Paths.safeStem("a/b") != Paths.safeStem("a:b"))
    }

    @Test func emptyAndOverlongIdentifiersAreUsable() {
        #expect(!Paths.safeStem("").isEmpty)
        #expect(Paths.safeStem(String(repeating: "x", count: 4000)).count <= 140)
    }

    @Test func onlyPlainFileNamesAreAccepted() {
        for bad in ["../escaped.png", "../../escaped.png", "/etc/passwd", "sub/dir.png", "", ".", "..", ".hidden"] {
            #expect(!Paths.isPlainIconFileName(bad), "\(bad) should be refused")
            #expect(throws: (any Error).self) { try Paths.iconURL(forFile: bad) }
        }
        for good in ["com.apple.Safari.icns", "notion.id.png", "a-b_c.png"] {
            #expect(Paths.isPlainIconFileName(good))
        }
    }

    @Test func iconURLStaysInTheIconFolder() throws {
        // Checked by shape rather than by absolute path, so it does not depend on where the library happens to be.
        let url = try Paths.iconURL(forFile: "com.apple.Safari.icns")
        #expect(url.lastPathComponent == "com.apple.Safari.icns")
        #expect(url.deletingLastPathComponent().lastPathComponent == "icons")
    }
}
