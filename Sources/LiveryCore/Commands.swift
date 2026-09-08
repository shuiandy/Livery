import AppKit
import Foundation

public enum Version {
    public static let string = "0.4.0"
}

public struct CheckReport {
    public var ok = 0
    public var fixed = 0
    public var failed = 0
    public var missing = 0

    public init() {}
}

public enum Commands {
    // MARK: search

    public static func search(query: String, page: Int, limit: Int, preview: Bool, raw: Bool, source: IconSource = .iconic) throws {
        let response = try IconCatalog.search(query, page: page, source: source, raw: raw)
        let pageSize = response.hitsPerPage ?? 50
        let firstIndex = (page - 1) * pageSize + 1
        let cache = SearchCache(query: query, page: page, firstIndex: firstIndex, hits: response.hits)
        try cache.save()

        let shown = Array(response.hits.prefix(limit))
        let pages = response.totalPages.map { " of \($0)" } ?? ""
        print("\(response.hits.count) hits on page \(page)\(pages), \(response.totalHits ?? response.hits.count) total for \"\(query)\"; showing \(shown.count)")
        for (index, hit) in shown.enumerated() {
            let number = String(format: "%3d", firstIndex + index)
            let name = (hit.appName ?? "?").padding(toLength: 34, withPad: " ", startingAt: 0)
            let credit = hit.author.padding(toLength: 18, withPad: " ", startingAt: 0)
            let downloads = String(format: "%6d", hit.downloads ?? 0)
            let format = hit.icnsUrl == nil ? "  (no icns)" : ""
            print("#\(number)  \(name) \(credit) \(downloads) dl\(format)")
        }
        guard preview, !shown.isEmpty else { return }
        let slug = query.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let sheet = Paths.caches.appendingPathComponent("search-\(slug)-p\(page).png")
        try ContactSheet.render(hits: shown, firstIndex: firstIndex, to: sheet)
        try Shell.run("/usr/bin/open", [sheet.path])
        print("preview: \(sheet.path)")
        print("apply one with: livery set <App> --pick <#>")
    }

    // MARK: set / reset / info

    public static func set(appQuery: String, pick: Int?, file: String?, urlString: String?, restartDock: Bool) throws {
        let app = try AppLocator.resolve(appQuery)
        var data: Data
        var source: String
        var credit: String?

        if let pick {
            let hit = try SearchCache.load().hit(number: pick)
            guard let icns = hit.icnsUrl ?? hit.lowResPngUrl else { throw LiveryError("#\(pick) has no downloadable icon") }
            data = try MacOSIcons.download(icns)
            source = hit.iconPageURL ?? icns
            credit = hit.author
        } else if let file {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            data = try Data(contentsOf: url)
            source = url.path
        } else if let urlString {
            data = try MacOSIcons.download(urlString)
            source = urlString
        } else {
            throw LiveryError("give one of --pick <#>, --file <path>, --url <url>")
        }

        let entry = try store(data: data, for: app, source: source, credit: credit)
        try ManifestStore.mutate { $0.upsert(entry) }
        print("applied to \(app.path) [\(app.bundleID)]")
        if restartDock { Dock.restart() }
    }

    /// One transaction under the manifest lock. The kept icon and the manifest entry are settled first, the bundle is
    /// written last, and a failed bundle write puts both back. So the library never records an icon Finder does not
    /// show, Finder never shows one the library does not record, and two writers cannot race on the same app because
    /// the lock covers the bundle write too. If the process dies between the checkpoint and the write, the entry is
    /// already there and `check --fix` completes the job.
    public static func store(data: Data, for app: AppRef, source: String?, credit: String?) throws -> IconEntry {
        try ManifestStore.transaction { manifest, checkpoint in
            try storeLocked(data: data, for: app, source: source, credit: credit, into: &manifest, checkpoint: checkpoint)
        }
    }

    static func storeLocked(data: Data, for app: AppRef, source: String?, credit: String?,
                            into manifest: inout Manifest, checkpoint: (Manifest) throws -> Void) throws -> IconEntry {
        let staged = try stage(data: data, for: app)
        let stem = Paths.safeStem(app.bundleID)
        let fileName = stem + "." + staged.pathExtension
        let destination = try Paths.iconURL(forFile: fileName)
        let previous = manifest.entry(for: app.bundleID)

        // Whatever was kept before moves aside rather than being deleted, so it can come back if the write fails.
        var displaced: [(from: URL, to: URL)] = []
        do {
            for ext in ["icns", "png"] {
                let old = try Paths.iconURL(forFile: stem + "." + ext)
                guard FileManager.default.fileExists(atPath: old.path) else { continue }
                let aside = try Paths.iconURL(forFile: "\(stem).previous-\(UUID().uuidString).\(ext)")
                try FileManager.default.moveItem(at: old, to: aside)
                displaced.append((old, aside))
            }
            try FileManager.default.moveItem(at: staged, to: destination)
            let stored = try Data(contentsOf: destination)
            var entry = IconEntry(bundleID: app.bundleID, name: app.name, appPath: app.path, iconFile: fileName,
                                  source: source, credit: credit, iconSHA256: IconFS.sha256(stored),
                                  appliedRsrcSize: nil, appliedRsrcSHA256: nil, updatedAt: Date())
            manifest.upsert(entry)
            try checkpoint(manifest)
            let applied = try IconWriter.apply(iconFile: destination, to: app.path)
            entry.appliedRsrcSize = applied.rsrcSize
            entry.appliedRsrcSHA256 = applied.rsrcSHA256
            manifest.upsert(entry)
            for item in displaced { try? FileManager.default.removeItem(at: item.to) }
            return entry
        } catch {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: destination)
            for item in displaced { try? FileManager.default.moveItem(at: item.to, to: item.from) }
            if let previous { manifest.upsert(previous) } else { manifest.remove(bundleID: app.bundleID) }
            try? checkpoint(manifest)
            throw error
        }
    }

    /// Writes the icon under a name of its own, so two apps being set at the same time cannot pick up each other's
    /// bytes. Full-bleed artwork is scaled onto the macOS icon grid first, so a catalog icon never renders larger than
    /// its neighbours in the Dock.
    public static func stage(data: Data, for app: AppRef, fitToGrid: Bool = true) throws -> URL {
        try Paths.ensureDirectories()
        var data = data
        var ext = try IconFS.imageExtension(for: data)
        if fitToGrid, let fitted = IconGrid.fitted(data) {
            data = fitted
            ext = "png"
        }
        let staged = try Paths.iconURL(forFile: "\(Paths.safeStem(app.bundleID)).staging-\(UUID().uuidString).\(ext)")
        try data.write(to: staged, options: .atomic)
        return staged
    }

    /// Removes staging files and set-aside copies an interrupted write left behind.
    public static func sweepStagingFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Paths.icons.path) else { return }
        for name in names where name.contains(".staging-") || name.contains(".previous-") {
            try? FileManager.default.removeItem(at: Paths.icons.appendingPathComponent(name))
        }
    }

    public static func reset(appQuery: String) throws {
        let app = try AppLocator.resolve(appQuery)
        try IconWriter.reset(app.path)
        try ManifestStore.mutate { $0.remove(bundleID: app.bundleID) }
        print("reset \(app.path); no longer tracked")
    }

    /// Puts every tracked app back to the icon inside its own bundle and forgets all of them. This is the clean way
    /// to undo everything Livery did, so it reports what it could not reach rather than stopping at the first one.
    public static func resetAll() throws {
        let entries = Manifest.load().entries
        guard !entries.isEmpty else {
            print("nothing tracked")
            return
        }
        var restored = 0
        var failed: [String] = []
        var missing: [String] = []
        for entry in entries {
            guard let path = AppLocator.currentPath(for: entry) else {
                missing.append(entry.name)
                continue
            }
            do {
                try IconWriter.reset(path)
                restored += 1
            } catch {
                failed.append("\(entry.name): \(error)")
            }
        }
        // Apps that are no longer installed cannot be reset, but keeping them tracked would serve no purpose either.
        let restoredOrGone = Set(entries.filter { entry in
            guard let path = AppLocator.currentPath(for: entry) else { return true }
            return !IconFS.inspect(path).flagSet
        }.map(\.bundleID))
        try ManifestStore.mutate { manifest in
            manifest.entries.removeAll { restoredOrGone.contains($0.bundleID) }
        }
        print("restored \(restored) apps to their own icons")
        if !missing.isEmpty { print("no longer installed, untracked: \(missing.joined(separator: ", "))") }
        for line in failed { print("failed  \(line)") }
        print("icon files are still in \(Paths.icons.path) if you want them back")
    }

    public static func info(appQuery: String) throws {
        let app = try AppLocator.resolve(appQuery)
        let state = IconFS.inspect(app.path, withHash: true)
        print("app:        \(app.path)")
        print("bundle id:  \(app.bundleID)")
        print("flag set:   \(state.flagSet)")
        print("rsrc bytes: \(state.rsrcSize)")
        print("rsrc sha:   \(state.rsrcSHA256 ?? "-")")
        print("health:     \(state.health.rawValue)")
        if let entry = Manifest.load().entry(for: app.bundleID) {
            print("tracked:    \(entry.iconURL.path)")
            print("source:     \(entry.source ?? "-")")
            print("applied:    \(entry.appliedRsrcSize ?? 0) bytes, \(entry.appliedRsrcSHA256 ?? "-")")
        } else {
            print("tracked:    no")
        }
    }

    // MARK: list / check

    public static func list() {
        let manifest = Manifest.load()
        if manifest.entries.isEmpty {
            print("nothing tracked yet")
            return
        }
        for entry in manifest.entries {
            let path = AppLocator.currentPath(for: entry)
            let health = path.map { IconFS.inspect($0).health } ?? .appMissing
            let name = entry.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            print("\(health.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(name) \(entry.bundleID)")
        }
    }

    @discardableResult
    public static func check(fix: Bool, verbose: Bool, quiet: Bool = false) -> CheckReport {
        var report = CheckReport()
        if fix {
            // One exclusive lock around the whole pass, so a repair cannot lose an edit the app makes meanwhile.
            do {
                try ManifestStore.mutate { report = inspect(&$0, fix: true, verbose: verbose, quiet: quiet) }
            } catch {
                Log.error("\(error)")
                report.failed += 1
            }
        } else {
            var manifest = Manifest.load()
            report = inspect(&manifest, fix: false, verbose: verbose, quiet: quiet)
        }
        if !quiet {
            print("ok \(report.ok), fixed \(report.fixed), broken \(report.failed), missing \(report.missing)")
        }
        return report
    }

    private static func inspect(_ manifest: inout Manifest, fix: Bool, verbose: Bool, quiet: Bool) -> CheckReport {
        var report = CheckReport()
        for (index, entry) in manifest.entries.enumerated() {
            guard let path = AppLocator.currentPath(for: entry) else {
                report.missing += 1
                if !quiet { print("missing    \(entry.name)") }
                continue
            }
            let state = IconFS.inspect(path)
            if !state.health.needsFix {
                report.ok += 1
                if verbose { print("ok         \(entry.name)") }
                continue
            }
            guard fix else {
                report.failed += 1
                print("\(state.health.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(entry.name)  \(path)")
                continue
            }
            do {
                let applied = try IconWriter.apply(iconFile: entry.iconURL, to: path)
                manifest.entries[index].appPath = path
                manifest.entries[index].appliedRsrcSize = applied.rsrcSize
                manifest.entries[index].appliedRsrcSHA256 = applied.rsrcSHA256
                manifest.entries[index].updatedAt = Date()
                report.fixed += 1
                Log.info("fixed \(entry.name): was \(state.health.rawValue), rewrote \(entry.iconFile) into \(path)")
            } catch {
                report.failed += 1
                Log.error("\(entry.name): \(error)")
            }
        }
        return report
    }

    // MARK: refit

    /// Re-scales already stored icons that were saved before grid fitting, or that came from an import, and writes the
    /// corrected artwork back into the bundle. Icons that already sit on the grid are left alone.
    public static func refit(apply: Bool) throws {
        guard apply else {
            let manifest = Manifest.load()
            let stale = manifest.entries.filter {
                (try? Data(contentsOf: $0.iconURL)).flatMap { IconGrid.fitted($0) } != nil
            }
            for entry in stale { print("would refit  \(entry.name)") }
            print(stale.isEmpty ? "every icon already sits on the macOS icon grid"
                                : "\(stale.count) icons miss the grid; run: livery refit --apply")
            return
        }
        try ManifestStore.mutate { try refitLocked(&$0) }
    }

    private static func refitLocked(_ manifest: inout Manifest) throws {
        var changed = 0
        for (index, entry) in manifest.entries.enumerated() {
            guard let data = try? Data(contentsOf: entry.iconURL), let fitted = IconGrid.fitted(data) else { continue }
            changed += 1
            let stem = Paths.safeStem(entry.bundleID)
            let fileName = stem + ".png"
            let destination = try Paths.iconURL(forFile: fileName)
            // Written beside the kept icon first: the kept icon and the entry change only once the bundle has, so a
            // refused write leaves the library and the bundle agreeing with each other, as they did before.
            let staged = try Paths.iconURL(forFile: "\(stem).staging-\(UUID().uuidString).png")
            try fitted.write(to: staged, options: .atomic)
            let path = AppLocator.currentPath(for: entry)
            var applied: IconInspection?
            if let path {
                do {
                    applied = try IconWriter.apply(iconFile: staged, to: path)
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    print("refit \(entry.name) failed, left as it was: \(error)")
                    continue
                }
            }
            if entry.iconFile != fileName { try? FileManager.default.removeItem(at: entry.iconURL) }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staged, to: destination)
            manifest.entries[index].iconFile = fileName
            manifest.entries[index].iconSHA256 = IconFS.sha256(fitted)
            manifest.entries[index].updatedAt = Date()
            if let applied, let path {
                manifest.entries[index].appPath = path
                manifest.entries[index].appliedRsrcSize = applied.rsrcSize
                manifest.entries[index].appliedRsrcSHA256 = applied.rsrcSHA256
                print("refit \(entry.name)")
            } else {
                print("refit \(entry.name) (app not installed, icon updated in the library)")
            }
        }
        if changed == 0 { print("every icon already sits on the macOS icon grid") }
    }

    // MARK: import

    public static func importReplacicon(apply: Bool) throws {
        try Paths.ensureDirectories()
        let records = try ReplaciconImport.records()
        try ManifestStore.mutate { try importLocked(records, into: &$0, apply: apply) }
    }

    private static func importLocked(_ records: [ReplaciconRecord], into manifest: inout Manifest, apply: Bool) throws {
        var imported = 0
        var lowRes = 0
        var broken: [String] = []
        var skipped: [String] = []
        var untouched = 0

        for record in records {
            guard let icon = ReplaciconImport.iconFile(for: record.iconUUID) else {
                // Replacicon points apps without a custom icon at a shared placeholder UUID that has no file.
                if record.sourceURL == nil, record.sourceName == nil {
                    untouched += 1
                } else {
                    skipped.append("\(record.name): icon file \(record.iconUUID) not in Replacicon store")
                }
                continue
            }
            var path = record.appPath
            if !FileManager.default.fileExists(atPath: path) {
                guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.bundleID)?.path else {
                    skipped.append("\(record.name): app not installed")
                    continue
                }
                path = found
            }
            var data = try Data(contentsOf: icon.url)
            var ext = try IconFS.imageExtension(for: data)
            if let fitted = IconGrid.fitted(data) {
                data = fitted
                ext = "png"
            }
            let fileName = Paths.safeStem(record.bundleID) + "." + ext
            let stored = try Paths.iconURL(forFile: fileName)
            try data.write(to: stored, options: .atomic)
            if icon.lowRes { lowRes += 1 }

            var state = IconFS.inspect(path, withHash: true)
            if state.health.needsFix {
                if apply {
                    state = try IconWriter.apply(iconFile: stored, to: path)
                } else {
                    broken.append("\(record.name): \(state.health.rawValue)")
                }
            }
            let existing = manifest.entry(for: record.bundleID)
            manifest.upsert(IconEntry(
                bundleID: record.bundleID, name: record.name, appPath: path, iconFile: fileName,
                source: record.sourceURL ?? "replacicon", credit: record.sourceName,
                iconSHA256: IconFS.sha256(data),
                appliedRsrcSize: state.health == .ok ? state.rsrcSize : existing?.appliedRsrcSize,
                appliedRsrcSHA256: state.health == .ok ? state.rsrcSHA256 : existing?.appliedRsrcSHA256,
                updatedAt: Date()))
            imported += 1
        }

        print("imported \(imported) apps into \(Paths.icons.path); \(untouched) apps had no custom icon in Replacicon")
        if lowRes > 0 { print("\(lowRes) only had the 144 px preview in Replacicon's store; re-pick those from macosicons for full quality") }
        for line in skipped { print("skipped  \(line)") }
        if !broken.isEmpty {
            print("currently broken in Finder (run `livery check --fix`):")
            for line in broken { print("  \(line)") }
        }
    }
}
