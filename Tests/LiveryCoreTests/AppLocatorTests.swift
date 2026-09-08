import Foundation
import Testing
@testable import LiveryCore

/// A tracked app is identified by its bundle identifier, not by whatever happens to sit at its old path.
struct AppLocatorTests {
    private func bundle(named name: String, identifier: String) throws -> (root: URL, path: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livery-locator-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent(name + ".app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return (root, app.path)
    }

    private func entry(bundleID: String, path: String) -> IconEntry {
        IconEntry(bundleID: bundleID, name: "Test", appPath: path, iconFile: "x.png", source: nil, credit: nil,
                  iconSHA256: "0", appliedRsrcSize: nil, appliedRsrcSHA256: nil, updatedAt: Date())
    }

    @Test func theRecordedPathWinsWhileTheSameAppIsThere() throws {
        let made = try bundle(named: "Same", identifier: "com.livery.tests.same")
        defer { try? FileManager.default.removeItem(at: made.root) }
        #expect(AppLocator.currentPath(for: entry(bundleID: "com.livery.tests.same", path: made.path)) == made.path)
    }

    @Test func aDifferentAppAtTheOldPathIsNotMistakenForTheTrackedOne() throws {
        // Before this check, a new app dropped in under the old name would have had the old icon written into it.
        let made = try bundle(named: "Replaced", identifier: "com.livery.tests.other")
        defer { try? FileManager.default.removeItem(at: made.root) }
        #expect(AppLocator.currentPath(for: entry(bundleID: "com.livery.tests.absent", path: made.path)) == nil)
    }

    @Test func aBundleWithoutAnIdentifierIsNotAnApp() throws {
        let made = try bundle(named: "Blank", identifier: "")
        defer { try? FileManager.default.removeItem(at: made.root) }
        #expect(AppLocator.currentPath(for: entry(bundleID: "com.livery.tests.blank", path: made.path)) == nil)
    }
}
