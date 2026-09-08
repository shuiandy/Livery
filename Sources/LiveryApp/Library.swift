import AppKit
import LiveryCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum SidebarSection: String, Hashable, CaseIterable {
    case all, custom, attention, recent, discover

    var title: String {
        switch self {
        case .all: return String(localized: "All apps")
        case .custom: return String(localized: "Custom icons")
        case .attention: return String(localized: "Needs attention")
        case .recent: return String(localized: "Recently changed")
        case .discover: return String(localized: "Find icons")
        }
    }
}

enum LayoutMode: String, CaseIterable {
    case grid, list
}

enum PermissionState {
    case unknown, allowed, denied
}

/// What Livery knows about one app: untracked apps just sit in the grid with their own icon.
enum AppState {
    case untracked, healthy, folderIcon, reverted, missing

    var needsFix: Bool { self == .folderIcon || self == .reverted }
    var needsAttention: Bool { needsFix || self == .missing }

    var title: String {
        switch self {
        case .untracked: return String(localized: "Stock icon")
        case .healthy: return String(localized: "Healthy")
        case .folderIcon: return String(localized: "Folder in Finder")
        case .reverted: return String(localized: "Stock icon is back")
        case .missing: return String(localized: "App not found")
        }
    }

    var explanation: String {
        switch self {
        case .untracked: return String(localized: "Finder draws the app's own icon. Livery is not tracking this app.")
        case .healthy: return String(localized: "Finder draws the kept icon.")
        case .folderIcon: return String(localized: "An update rewrote the bundle in place. The flag survived, the icon data did not, so Finder draws a folder.")
        case .reverted: return String(localized: "The bundle was replaced wholesale, which cleared the custom-icon flag. The app shows its stock icon.")
        case .missing: return String(localized: "The app is not at its recorded path and Launch Services does not know it. The kept icon stays in the library.")
        }
    }
}

struct AppItem: Identifiable {
    var ref: AppRef
    var entry: IconEntry?
    var inspection: IconInspection?

    var id: String { ref.bundleID }
    var name: String { ref.name }
    var path: String { ref.path }
    var isTracked: Bool { entry != nil }
    var installed: Bool { entry == nil || inspection != nil }

    var state: AppState {
        guard entry != nil else { return .untracked }
        guard let inspection else { return .missing }
        switch inspection.health {
        case .ok: return .healthy
        case .folderIcon: return .folderIcon
        case .reverted: return .reverted
        case .appMissing: return .missing
        }
    }

    var sourceURL: URL? {
        guard let source = entry?.source, source.hasPrefix("http") else { return nil }
        return URL(string: source)
    }

    var sourceDescription: String {
        guard let entry else { return "" }
        guard let source = entry.source else { return String(localized: "Local file") }
        if source == "replacicon" || source.contains("replacicon.app") { return String(localized: "Imported from Replacicon") }
        if source.contains("macosicons.com") {
            let author = entry.credit ?? ""
            return author.isEmpty || author == "macosicons.com" ? "macosicons.com" : "macosicons.com · \(author)"
        }
        if source.hasPrefix("/") { return String(localized: "Local file") }
        return source
    }

    var iconFileDescription: String {
        guard let entry else { return "" }
        let ext = (entry.iconFile as NSString).pathExtension
        let size = (try? FileManager.default.attributesOfItem(atPath: entry.iconURL.path)[.size] as? Int) ?? 0
        return "\(ext) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
}

struct CheckOutcome {
    var fixed = 0
    var errors: [String] = []
    var ownership: [(name: String, path: String)] = []
}

/// A write that failed because the bundle belongs to root; the same write can run as an administrator.
struct OwnershipPrompt: Identifiable {
    let id = UUID()
    let names: [String]
    let asAdministrator: @MainActor () async -> Void
}


struct PendingHit: Identifiable {
    let id = UUID()
    let hit: IconHit
}

/// Actions that discard work or interrupt a running app, so every entry point asks before doing them.
enum PendingConfirmation: Identifiable {
    case reset(AppItem)
    case stopTracking(AppItem)
    case relaunch(AppItem)
    case resetAll(Int)

    var id: String {
        switch self {
        case .reset(let app): return "reset-" + app.id
        case .stopTracking(let app): return "stop-" + app.id
        case .relaunch(let app): return "relaunch-" + app.id
        case .resetAll: return "reset-all"
        }
    }

    var title: String {
        switch self {
        case .reset(let app): return String(localized: "Reset \(app.name) to its stock icon?")
        case .stopTracking(let app): return String(localized: "Stop tracking \(app.name)?")
        case .relaunch(let app): return String(localized: "Relaunch \(app.name)?")
        case .resetAll(let count): return String(localized: "Restore stock icons for all \(count) apps?")
        }
    }

    var message: String {
        switch self {
        case .reset(let app):
            return String(localized: "The custom icon is removed from the bundle and Livery stops tracking \(app.name). The icon file stays in the library folder.")
        case .stopTracking(let app):
            return String(localized: "\(app.name) keeps whatever icon it has now, but Livery stops repairing it after updates.")
        case .relaunch(let app):
            return String(localized: "\(app.name) is asked to quit and is opened again so the Dock picks up the new icon. Anything unsaved in it is up to the app to handle.")
        case .resetAll:
            return String(localized: "Every app goes back to the icon inside its own bundle and Livery stops tracking all of them. The icon files stay in the library folder, so the icons can be applied again later.")
        }
    }

    var actionTitle: String {
        switch self {
        case .reset: return String(localized: "Reset")
        case .stopTracking: return String(localized: "Stop tracking")
        case .relaunch: return String(localized: "Relaunch")
        case .resetAll: return String(localized: "Restore all")
        }
    }

    var isDestructive: Bool {
        if case .relaunch = self { return false }
        return true
    }
}

struct LibrarySnapshot {
    var apps: [AppItem]
    var agent: LaunchAgent.Info
    var watchRoots: [String]
    var agentStarted: Date?
    var lastRefusal: Date?
    var permission: PermissionState
}

@MainActor
@Observable
final class Library {
    var apps: [AppItem] = []
    var selection: String?
    var section: SidebarSection? = .all
    var layout: LayoutMode = .grid
    var searchText = ""
    var isBusy = false
    var isLoading = false
    var errorMessage: String?
    var iconPickerTarget: AppRef?
    var pendingHit: PendingHit?
    var ownershipPrompt: OwnershipPrompt?
    /// The guided setup for the privileged helper: one status light per approval macOS wants.
    var helperSetupPresented = false
    var confirm: PendingConfirmation?
    /// Guards against an earlier catalog reply landing after a later one and replacing it.
    @ObservationIgnored private var suggestionGeneration: [String: Int] = [:]
    var rateLimitedUntil: Date?
    /// macosicons meters by month, so a 429 there is not going to clear on its own today.
    var quotaExhausted = false
    var suggestions: [String: [IconHit]] = [:]
    var suggestionsLoading: Set<String> = []
    var suggestionErrors: [String: String] = [:]
    var previews: [String: NSImage] = [:]
    @ObservationIgnored private var previewsLoading: Set<String> = []

    var agent = LaunchAgent.Info(installed: false, loaded: false)
    var watchRoots: [String] = []
    var agentStarted: Date?
    var lastRefusal: Date?
    var permission: PermissionState = .unknown

    @ObservationIgnored private var directorySource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingReload: DispatchWorkItem?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var keptIcons: [String: NSImage] = [:]
    @ObservationIgnored private var finderIcons: [String: NSImage] = [:]
    @ObservationIgnored private var timer: Timer?

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
    /// The command line tool the background agent runs: the copy install.sh put in ~/.local/bin when there is one,
    /// otherwise the copy inside this bundle, so an app installed from the disk image can run the agent too.
    nonisolated static var cliBinary: String {
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/livery").path
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/livery").path
    }
    nonisolated static let applicationRoots = ["/Applications", NSHomeDirectory() + "/Applications"]

    init() {
        reload()
        watchManifestDirectory()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    // MARK: Derived state

    var trackedCount: Int { apps.filter(\.isTracked).count }
    var attentionCount: Int { apps.filter { $0.state.needsAttention }.count }
    var fixableApps: [AppItem] { apps.filter { $0.state.needsFix } }

    var visibleApps: [AppItem] {
        var list: [AppItem]
        switch section ?? .all {
        case .all, .discover: list = apps
        case .custom: list = apps.filter(\.isTracked)
        case .attention: list = apps.filter { $0.state.needsAttention }
        case .recent:
            list = apps.filter(\.isTracked).sorted { ($0.entry?.updatedAt ?? .distantPast) > ($1.entry?.updatedAt ?? .distantPast) }
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            list = list.filter { $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
        }
        return list
    }

    /// Only an app that is currently shown counts as selected: acting on one the filter has hidden would surprise.
    var selectedApp: AppItem? { visibleApps.first { $0.id == selection } }

    func app(for bundleID: String) -> AppItem? { apps.first { $0.id == bundleID } }

    // MARK: Loading

    /// Re-reads the manifest, every Applications folder and the agent. Runs off the main thread; the UI keeps the old list until it lands.
    func reload() {
        reloadTask?.cancel()
        isLoading = true
        reloadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) { Library.snapshot() }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        apps = snapshot.apps
        agent = snapshot.agent
        watchRoots = snapshot.watchRoots
        agentStarted = snapshot.agentStarted
        lastRefusal = snapshot.lastRefusal
        permission = snapshot.permission
        isLoading = false
        // The key carries what the icon depends on, so a reload keeps every icon that cannot have changed instead of
        // making the grid ask Finder for a hundred of them again on the main thread.
        let live = Set(apps.map(Library.finderIconKey))
        finderIcons = finderIcons.filter { live.contains($0.key) }
        let validHashes = Set(apps.compactMap { $0.entry?.iconSHA256 })
        keptIcons = keptIcons.filter { validHashes.contains($0.key) }
        if selection == nil || !apps.contains(where: { $0.id == selection }) {
            selection = apps.first(where: { $0.state.needsAttention })?.id
                ?? apps.first(where: \.isTracked)?.id
                ?? apps.first?.id
        }
    }

    func refreshAgent() {
        reload()
    }

    nonisolated static func snapshot() -> LibrarySnapshot {
        var byID: [String: AppItem] = [:]
        for ref in installedApps() where byID[ref.bundleID] == nil {
            byID[ref.bundleID] = AppItem(ref: ref, entry: nil, inspection: nil)
        }
        for entry in Manifest.load().entries {
            let path = AppLocator.currentPath(for: entry)
            let inspection = path.map { IconFS.inspect($0) }
            let ref = AppRef(path: path ?? entry.appPath, bundleID: entry.bundleID, name: entry.name)
            byID[entry.bundleID] = AppItem(ref: ref, entry: entry, inspection: inspection)
        }
        let apps = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let log = parseLog()
        return LibrarySnapshot(apps: apps, agent: LaunchAgent.probe(), watchRoots: Watcher.watchRoots(),
                               agentStarted: log.started, lastRefusal: log.refusedAt, permission: log.permission)
    }

    /// Every .app in /Applications and ~/Applications, one vendor folder deep (Setapp, Utilities, Chrome Apps).
    nonisolated static func installedApps() -> [AppRef] {
        let fm = FileManager.default
        var refs: [AppRef] = []
        for root in applicationRoots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items.sorted() where !item.hasPrefix(".") {
                let full = root + "/" + item
                if item.hasSuffix(".app") {
                    if let ref = try? AppLocator.ref(forPath: full) { refs.append(ref) }
                } else if let children = try? fm.contentsOfDirectory(atPath: full) {
                    for child in children.sorted() where child.hasSuffix(".app") {
                        if let ref = try? AppLocator.ref(forPath: full + "/" + child) { refs.append(ref) }
                    }
                }
            }
        }
        return refs
    }

    func keptIcon(for app: AppItem) -> NSImage? {
        guard let entry = app.entry else { return nil }
        if let cached = keptIcons[entry.iconSHA256] { return cached }
        guard let image = NSImage(contentsOf: entry.iconURL) else { return nil }
        keptIcons[entry.iconSHA256] = image
        return image
    }

    /// What Finder draws for the bundle right now.
    nonisolated static func finderIconKey(_ app: AppItem) -> String {
        "\(app.path)|\(app.state.title)|\(app.inspection?.rsrcSize ?? -1)|\(app.inspection?.rsrcSHA256 ?? "")"
    }

    func finderIcon(for app: AppItem) -> NSImage {
        let key = Library.finderIconKey(app)
        if let cached = finderIcons[key] { return cached }
        let image: NSImage
        switch app.state {
        case .folderIcon: image = NSWorkspace.shared.icon(for: .folder)
        case .missing: image = NSWorkspace.shared.icon(for: .applicationBundle)
        default: image = NSWorkspace.shared.icon(forFile: app.path)
        }
        finderIcons[key] = image
        return image
    }

    private func watchManifestDirectory() {
        try? Paths.ensureDirectories()
        let fd = open(Paths.support.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Checking and repairing

    func checkNow() {
        reload()
    }

    func fixAll() {
        Task { await runFix(only: nil) }
    }

    func repair(_ app: AppItem) {
        Task { await runFix(only: [app.id]) }
    }

    private func runFix(only: Set<String>?) async {
        isBusy = true
        defer { isBusy = false }
        let outcome = await Task.detached { Library.performFix(only: only) }.value
        reload()
        if !outcome.errors.isEmpty {
            errorMessage = outcome.errors.joined(separator: "\n\n")
        } else if !outcome.ownership.isEmpty {
            ownershipPrompt = OwnershipPrompt(names: outcome.ownership.map(\.name)) { [weak self] in
                await self?.ensureHelper { await self?.runFix(only: only) }
            }
        }
        if outcome.fixed > 0, UserDefaults.standard.bool(forKey: "restartDockAfterRepair") {
            Dock.restart()
        }
    }

    nonisolated static func performFix(only: Set<String>?) -> CheckOutcome {
        var outcome = CheckOutcome()
        do {
            try ManifestStore.mutate { outcome = fixLocked(&$0, only: only) }
        } catch {
            outcome.errors.append("\(error)")
        }
        return outcome
    }

    private nonisolated static func fixLocked(_ manifest: inout Manifest, only: Set<String>?) -> CheckOutcome {
        var outcome = CheckOutcome()
        for (index, entry) in manifest.entries.enumerated() {
            if let only, !only.contains(entry.bundleID) { continue }
            guard let path = AppLocator.currentPath(for: entry) else { continue }
            let state = IconFS.inspect(path)
            guard state.health.needsFix || only != nil else { continue }
            do {
                let applied = try IconWriter.apply(iconFile: entry.iconURL, to: path)
                manifest.entries[index].appPath = path
                manifest.entries[index].appliedRsrcSize = applied.rsrcSize
                manifest.entries[index].appliedRsrcSHA256 = applied.rsrcSHA256
                manifest.entries[index].updatedAt = Date()
                outcome.fixed += 1
            } catch let failure as IconWriteError {
                if case .ownership = failure.block {
                    outcome.ownership.append((entry.name, failure.appPath))
                } else {
                    outcome.errors.append("\(entry.name): \(failure)")
                }
            } catch {
                outcome.errors.append("\(entry.name): \(error)")
            }
        }
        return outcome
    }

    // MARK: Applying icons

    func apply(data: Data, to app: AppRef, source: String?, credit: String?) async {
        isBusy = true
        defer { isBusy = false }
        do {
            // One transaction in the core: kept icon, manifest entry and bundle write settle together or not at all.
            _ = try await Task.detached { try Commands.store(data: data, for: app, source: source, credit: credit) }.value
            iconPickerTarget = nil
            pendingHit = nil
            reload()
            selection = app.bundleID
            if section == .discover { section = .custom }
            if UserDefaults.standard.bool(forKey: "restartDockAfterRepair") { Dock.restart() }
        } catch let failure as IconWriteError {
            if case .ownership = failure.block {
                iconPickerTarget = nil
                pendingHit = nil
                try? await Task.sleep(for: .milliseconds(450))
                ownershipPrompt = OwnershipPrompt(names: [app.name]) { [weak self] in
                    await self?.ensureHelper { await self?.apply(data: data, to: app, source: source, credit: credit) }
                }
            } else {
                await report(failure)
            }
        } catch {
            await report(error)
        }
    }

    // MARK: Privileged helper

    var helperState: HelperManager.State = .unknown

    /// Registration and reachability are two different facts, and neither proves TCC will let the helper write. The
    /// third fact only becomes known when a write is actually attempted, so it is remembered rather than guessed.
    var helperReachable = false

    var helperStatusText: String {
        switch helperState {
        case .notInstalled, .unknown: return helperState.title
        case .requiresApproval: return helperState.title
        case .enabled:
            guard helperReachable else { return String(localized: "Registered, not answering yet") }
            switch helperGrant {
            case .allowed: return String(localized: "Enabled, last write succeeded")
            case .denied: return String(localized: "Enabled, but macOS refused its last write")
            case .unknown: return String(localized: "Enabled, no write attempted yet")
            }
        }
    }

    var helperGrant: PermissionState {
        get {
            switch UserDefaults.standard.string(forKey: "helperGrant") {
            case "allowed": return .allowed
            case "denied": return .denied
            default: return .unknown
            }
        }
        set {
            UserDefaults.standard.set(newValue == .allowed ? "allowed" : newValue == .denied ? "denied" : "unknown",
                                      forKey: "helperGrant")
        }
    }

    func refreshHelperState() {
        Task { await refreshHelperStateNow() }
    }

    func refreshHelperStateNow() async {
        let probe = await Task.detached { () -> (HelperManager.State, Bool) in
            let state = HelperManager.state()
            HelperClient.forget()
            return (state, state == .enabled && HelperClient.version(timeout: 3) != nil)
        }.value
        helperState = probe.0
        helperReachable = probe.1
    }

    /// Registers the root helper (SMAppService daemon inside this bundle) and runs `retry` once it answers.
    /// First time round macOS wants the daemon approved under Login Items; that is a one-time step.
    func ensureHelper(then retry: @escaping @MainActor () async -> Void) async {
        isBusy = true
        let state = await Task.detached { HelperManager.install() }.value
        isBusy = false
        helperState = state
        switch state {
        case .enabled:
            HelperClient.forget()
            let alive = await Task.detached { HelperClient.version(timeout: 8) != nil }.value
            guard alive else {
                errorMessage = String(localized: "The helper is registered but does not answer yet. Give it a moment, then try the icon again.")
                return
            }
            helperReachable = true
            await retry()
            // Still refused: the helper runs, so what is missing is the App Management grant on the helper itself.
            if let message = errorMessage, message.contains("App Management") {
                errorMessage = nil
                helperGrant = .denied
                helperSetupPresented = true
            } else if errorMessage == nil {
                helperGrant = .allowed
            }
        case .requiresApproval:
            HelperManager.openApprovalSettings()
            helperSetupPresented = true
        case .notInstalled, .unknown:
            errorMessage = String(localized: "The helper could not be registered (\(state.title)). Reinstall Livery.app and try again.")
        }
    }

    func uninstallHelper() {
        Task {
            let state = await Task.detached { HelperManager.uninstall() }.value
            helperState = state
        }
    }

    /// Whether any app on this Mac is owned by root. When none is, the helper has nothing to do and the setup panel
    /// says so instead of asking for an approval that would never be exercised.
    var helperNeeded = true

    /// What the last probe said, for the setup panel: the bundle it tried, or why it was refused.
    var helperProbeMessage: String?

    /// Asks the helper to prove it may write where the user cannot. The answer is the real state of the App
    /// Management grant, which macOS offers no API to read.
    func probeHelperGrant() async {
        let target = await Task.detached { HelperProbe.target() }.value
        guard target != nil else {
            helperNeeded = false
            return
        }
        helperNeeded = true
        guard helperState == .enabled, helperReachable else { return }
        let result = await Task.detached { HelperClient.probeAppManagement() }.value
        helperGrant = result.allowed ? .allowed : .denied
        helperProbeMessage = result.message
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Dismisses any sheet first: an alert raised while a sheet is up never shows on macOS.
    private func report(_ error: Error) async {
        let hadSheet = iconPickerTarget != nil || pendingHit != nil
        iconPickerTarget = nil
        pendingHit = nil
        if hadSheet { try? await Task.sleep(for: .milliseconds(450)) }
        errorMessage = "\(error)"
    }

    func apply(hit: IconHit, to app: AppRef) async {
        guard let urlString = hit.icnsUrl ?? hit.lowResPngUrl else {
            errorMessage = String(localized: "This icon has no downloadable file.")
            return
        }
        isBusy = true
        let download: Data
        do {
            download = try await Task.detached { try MacOSIcons.download(urlString) }.value
        } catch {
            isBusy = false
            await report(error)
            return
        }
        isBusy = false
        let credit = hit.author.isEmpty ? nil : hit.author
        await apply(data: download, to: app, source: hit.iconPageURL ?? urlString, credit: credit)
    }

    /// Where searches go; the Iconic catalog needs no key and is the default.
    /// Whether selecting an app sends its name to the catalog straight away. Off, nothing leaves the machine until the
    /// user asks for a lookup. Stored, so the choice outlives the process.
    var autoSuggest: Bool = UserDefaults.standard.object(forKey: "autoSuggestIcons") == nil
        ? true : UserDefaults.standard.bool(forKey: "autoSuggestIcons") {
        didSet { UserDefaults.standard.set(autoSuggest, forKey: "autoSuggestIcons") }
    }

    var iconSource: IconSource {
        get { UserDefaults.standard.string(forKey: "iconSource").flatMap(IconSource.init) ?? .iconic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "iconSource")
            rateLimitedUntil = nil
            quotaExhausted = false
        }
    }

    func search(_ query: String, page: Int) async throws -> SearchResponse {
        let source = iconSource
        return try await Task.detached { try IconCatalog.search(query, page: page, source: source) }.value
    }

    // MARK: Suggestions

    /// The first page of macosicons.com results for the app's name, exact name matches first, cached in memory and on disk.
    func loadSuggestions(for app: AppItem, force: Bool = false) async {
        let key = app.id
        if !force, suggestions[key] != nil || suggestionsLoading.contains(key) { return }
        if !force, let cached = Library.cachedSuggestions(for: key) {
            suggestions[key] = cached
            return
        }
        if !force, let until = rateLimitedUntil, until > Date() { return }
        let generation = (suggestionGeneration[key] ?? 0) + 1
        suggestionGeneration[key] = generation
        suggestionsLoading.insert(key)
        defer { suggestionsLoading.remove(key) }
        do {
            let response = try await search(Library.searchTerm(for: app), page: 1)
            let ranked = Library.rank(response.hits, for: app)
            // A slower earlier request must not overwrite what a later one already produced.
            guard suggestionGeneration[key] == generation else { return }
            suggestions[key] = ranked
            suggestionErrors[key] = nil
            rateLimitedUntil = nil
            quotaExhausted = false
            Library.storeSuggestions(ranked, for: key)
        } catch let limit as RateLimited {
            switch limit.source {
            case .macosicons:
                quotaExhausted = true
                rateLimitedUntil = Date().addingTimeInterval(24 * 3600)
            case .iconic:
                quotaExhausted = false
                rateLimitedUntil = Date().addingTimeInterval(limit.retryAfter ?? 300)
            }
            suggestionErrors[key] = nil
        } catch {
            guard suggestionGeneration[key] == generation else { return }
            suggestionErrors[key] = "\(error)"
        }
    }

    func perform(_ confirmation: PendingConfirmation) {
        switch confirmation {
        case .reset(let app): reset(app)
        case .stopTracking(let app): stopTracking(app)
        case .relaunch(let app): relaunch(app)
        case .resetAll: resetAll()
        }
    }

    /// Puts every tracked app back to its own icon. The write can go through the helper, so it stays off the main actor.
    func resetAll() {
        Task {
            isBusy = true
            defer { isBusy = false }
            let failure = await Task.detached { () -> Error? in
                do {
                    try Commands.resetAll()
                    return nil
                } catch {
                    return error
                }
            }.value
            reload()
            if let failure { errorMessage = "\(failure)" }
            if UserDefaults.standard.bool(forKey: "restartDockAfterRepair") { Dock.restart() }
        }
    }

    // MARK: Catalog previews

    /// Thumbnails are rendered through the same grid fitting the write uses, so a square sticker previews as the
    /// rounded tile it will become. Cached small; catalog art is 1024 px and there are nine of them per app.
    func preview(for hit: IconHit) -> NSImage? {
        previewKey(for: hit).flatMap { previews[$0] }
    }

    func loadPreview(for hit: IconHit) async {
        guard let key = previewKey(for: hit), previews[key] == nil, !previewsLoading.contains(key) else { return }
        previewsLoading.insert(key)
        defer { previewsLoading.remove(key) }
        let image = await Task.detached { () -> NSImage? in
            // The same guarded transport as every other download: HTTPS only, no private addresses, capped, timed.
            guard let data = try? MacOSIcons.download(key) else { return nil }
            return Library.thumbnail(IconGrid.fitted(data) ?? data)
        }.value
        if let image { previews[key] = image }
    }

    private func previewKey(for hit: IconHit) -> String? { hit.lowResPngUrl ?? hit.icnsUrl }

    nonisolated static func thumbnail(_ data: Data, side: Int = 160) -> NSImage? {
        guard let source = NSImage(data: data),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    func hasCachedSuggestions(for app: AppItem) -> Bool {
        suggestions[app.id] != nil || Library.cachedSuggestions(for: app.id) != nil
    }

    var isRateLimited: Bool {
        guard let until = rateLimitedUntil else { return false }
        return until > Date()
    }

    private nonisolated static let suggestionTTL: TimeInterval = 3 * 24 * 3600
    private nonisolated static var suggestionsDirectory: URL { Paths.caches.appendingPathComponent("suggestions", isDirectory: true) }

    nonisolated static func cachedSuggestions(for bundleID: String) -> [IconHit]? {
        let url = suggestionsDirectory.appendingPathComponent(Paths.safeStem(bundleID) + ".json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < suggestionTTL,
              let data = try? Data(contentsOf: url),
              let hits = try? JSONDecoder().decode([IconHit].self, from: data) else { return nil }
        return hits
    }

    nonisolated static func storeSuggestions(_ hits: [IconHit], for bundleID: String) {
        try? FileManager.default.createDirectory(at: suggestionsDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(hits) else { return }
        try? data.write(to: suggestionsDirectory.appendingPathComponent(Paths.safeStem(bundleID) + ".json"), options: .atomic)
    }

    nonisolated static func searchTerm(for app: AppItem) -> String {
        var name = app.name
        for suffix in [" for Mac", " for macOS", ".app"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func rank(_ hits: [IconHit], for app: AppItem) -> [IconHit] {
        let wanted = searchTerm(for: app).lowercased()
        let usable = hits.filter { $0.icnsUrl != nil || $0.lowResPngUrl != nil }
        let exact = usable.filter { ($0.appName ?? "").lowercased() == wanted }
            .sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
        let rest = usable.filter { ($0.appName ?? "").lowercased() != wanted }
        return Array((exact + rest).prefix(9))
    }

    func chooseIcon(for app: AppItem) {
        iconPickerTarget = app.ref
    }

    func chooseIconFile(for target: AppRef) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.icns, .png]
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose an .icns or .png for \(target.name)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                await apply(data: data, to: target, source: url.path, credit: nil)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    func addApp() {
        guard let ref = pickApp(named: String(localized: "Choose the app that should get a custom icon")) else { return }
        iconPickerTarget = ref
    }

    func pickApp(named title: String) -> AppRef? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = title
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try AppLocator.ref(forPath: url.path)
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    // MARK: Removing

    /// Removing the icon talks to the helper, which can take seconds, so it never runs on the main actor.
    func reset(_ app: AppItem) {
        Task {
            isBusy = true
            defer { isBusy = false }
            let path = app.path, installed = app.installed, id = app.id
            let failure: Error? = await Task.detached {
                do {
                    if installed { try IconWriter.reset(path) }
                    try ManifestStore.mutate { $0.remove(bundleID: id) }
                    return nil
                } catch {
                    return error
                }
            }.value
            reload()
            guard let failure else { return }
            if let write = failure as? IconWriteError, case .ownership = write.block {
                ownershipPrompt = OwnershipPrompt(names: [app.name]) {
                    await self.ensureHelper { self.reset(app) }
                }
            } else {
                errorMessage = "\(failure)"
            }
        }
    }

    func stopTracking(_ app: AppItem) {
        Task {
            let id = app.id
            let failure: Error? = await Task.detached {
                do {
                    try ManifestStore.mutate { $0.remove(bundleID: id) }
                    return nil
                } catch {
                    return error
                }
            }.value
            reload()
            if let failure { errorMessage = "\(failure)" }
        }
    }

    func locate(_ app: AppItem) {
        guard let ref = pickApp(named: String(localized: "Where is \(app.name) now?")) else { return }
        guard ref.bundleID == app.id else {
            errorMessage = String(localized: "\(ref.name) is \(ref.bundleID), not \(app.id).")
            return
        }
        Task {
            let id = app.id, path = ref.path
            let failure: Error? = await Task.detached {
                do {
                    try ManifestStore.mutate { manifest in
                        guard let index = manifest.entries.firstIndex(where: { $0.bundleID == id }) else { return }
                        manifest.entries[index].appPath = path
                    }
                    return nil
                } catch {
                    return error
                }
            }.value
            if let failure {
                errorMessage = "\(failure)"
                return
            }
            await runFix(only: [app.id])
        }
    }

    func runningApplication(for app: AppItem) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first { !$0.isTerminated }
    }

    /// Quit and reopen, so the Dock picks up the new icon for its tile.
    func relaunch(_ app: AppItem) {
        guard let running = runningApplication(for: app) else { return }
        let url = URL(fileURLWithPath: app.path)
        isBusy = true
        running.terminate()
        Task {
            defer { isBusy = false }
            for _ in 0..<50 where !running.isTerminated {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard running.isTerminated else {
                errorMessage = String(localized: "\(app.name) did not quit (it may have unsaved work). Quit it yourself, then open it again.")
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func revealInFinder(_ app: AppItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }

    // MARK: Agent

    /// `launchctl` is a synchronous round trip that has been seen to take seconds, so it stays off the main actor.
    func installAgent() {
        guard FileManager.default.isExecutableFile(atPath: Library.cliBinary) else {
            errorMessage = String(localized: "The command line tool is not installed at \(Library.cliBinary). Reinstall Livery, or run ./install.sh in the project.")
            return
        }
        Task {
            isBusy = true
            let failure = await Task.detached { () -> Error? in
                do {
                    try LaunchAgent.install(binary: Library.cliBinary, restartDock: false)
                    return nil
                } catch {
                    return error
                }
            }.value
            isBusy = false
            if let failure { errorMessage = "\(failure)" }
            reload()
        }
    }

    /// For an agent launchd has stopped. Same shape as install: launchctl stays off the main actor.
    func startAgent() {
        Task {
            isBusy = true
            let failure = await Task.detached { () -> Error? in
                do {
                    try LaunchAgent.start()
                    return nil
                } catch {
                    return error
                }
            }.value
            isBusy = false
            if let failure { errorMessage = "\(failure)" }
            reload()
        }
    }

    func uninstallAgent() {
        Task {
            isBusy = true
            let failure = await Task.detached { () -> Error? in
                do {
                    try LaunchAgent.uninstall(quiet: true)
                    return nil
                } catch {
                    return error
                }
            }.value
            isBusy = false
            if let failure { errorMessage = "\(failure)" }
            reload()
        }
    }

    // MARK: Log

    /// What the log says about the *agent*, which is its own TCC principal. It says nothing about the app or the
    /// helper, and the sidebar labels it as the agent's own state for that reason.
    nonisolated static func parseLog() -> (started: Date?, refusedAt: Date?, permission: PermissionState) {
        // The agent runs for months and the log grows with it; only the tail says anything about the present.
        guard let handle = FileHandle(forReadingAtPath: Paths.logFile.path) else { return (nil, nil, .unknown) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return (nil, nil, .unknown) }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if start > 0 { lines.removeFirst() }
        lines = Array(lines.suffix(400))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var started: Date?
        var refusedAt: Date?
        var permission = PermissionState.unknown
        for line in lines {
            let stamp = formatter.date(from: String(line.dropFirst().prefix(19)))
            if line.contains("NSWorkspace refused") || line.contains("App Management") {
                permission = .denied
                refusedAt = stamp ?? refusedAt
            } else if line.contains("] fixed ") {
                permission = .allowed
            }
            if line.contains(" watching "), let stamp { started = stamp }
        }
        return (started, refusedAt, permission)
    }
}
