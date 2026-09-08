import AppKit
import LiveryCore
import SwiftUI

struct InspectorView: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let app = library.selectedApp {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch app.state {
                    case .untracked: untracked(app)
                    case .healthy: healthy(app)
                    case .missing: missing(app)
                    case .folderIcon, .reverted: broken(app)
                    }
                    if app.isTracked {
                        Divider()
                        details(app)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 22)
            }
        } else {
            ContentUnavailableView {
                Label("No app selected", systemImage: "app.dashed")
            } description: {
                Text("Pick an app to see how Finder draws it right now.")
            }
        }
    }

    // MARK: Variants

    @ViewBuilder
    private func untracked(_ app: AppItem) -> some View {
        bigIcon(library.finderIcon(for: app))
        header(app)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "app")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stock icon")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(app.state.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.hairline))
        SuggestionsSection(app: app)
    }

    @ViewBuilder
    private func broken(_ app: AppItem) -> some View {
        HStack(spacing: 12) {
            PreviewCard(image: library.finderIcon(for: app), caption: "In Finder now")
            PreviewCard(image: library.keptIcon(for: app), caption: "Kept by Livery")
        }
        header(app)
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("WHY IT BROKE")
            let flagSet = app.inspection?.flagSet ?? false
            let size = app.inspection?.rsrcSize ?? 0
            DiagnosisRow(ok: flagSet, label: "Custom-icon flag", value: flagSet ? String(localized: "set") : String(localized: "cleared"))
            DiagnosisRow(ok: size > 0, label: "Icon resource fork", value: size > 0 ? bytes(size) : String(localized: "missing, 0 bytes"))
            Text(app.state.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 8) {
            Button {
                library.repair(app)
            } label: {
                Text("Repair icon").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(library.isBusy)
            resetButton
        }
        runningNote(app)
        SuggestionsSection(app: app)
    }

    @ViewBuilder
    private func healthy(_ app: AppItem) -> some View {
        bigIcon(library.keptIcon(for: app) ?? library.finderIcon(for: app))
        header(app)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.healthy)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Healthy")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(healthyDetail(app))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.healthy.opacity(0.12)))
        runningNote(app)
        SuggestionsSection(app: app)
        resetButton
    }

    @ViewBuilder
    private func missing(_ app: AppItem) -> some View {
        HStack(spacing: 12) {
            PreviewCard(image: library.finderIcon(for: app), caption: "Not installed")
            PreviewCard(image: library.keptIcon(for: app), caption: "Kept by Livery")
        }
        header(app)
        Text(app.state.explanation)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 8) {
            Button {
                library.locate(app)
            } label: {
                Text("Locate app…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                library.confirm = .stopTracking(app)
            } label: {
                Text("Stop tracking").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    // MARK: Pieces

    /// The Dock draws a running app with the icon it loaded at launch; only a relaunch refreshes that tile.
    @ViewBuilder
    private func runningNote(_ app: AppItem) -> some View {
        if app.isTracked, library.runningApplication(for: app) != nil {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "dock.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(app.name) is running")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("The Dock keeps the icon it loaded at launch, even after the Dock restarts. Relaunch \(app.name) to update its tile.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch \(app.name)") { library.confirm = .relaunch(app) }
                        .controlSize(.small)
                        .disabled(library.isBusy)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.hairline))
        }
    }

    private func bigIcon(_ image: NSImage) -> some View {
        HStack {
            Spacer()
            RoundedRectangle(cornerRadius: 26)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.hairline))
                .frame(width: 168, height: 168)
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 128, height: 128)
                }
            Spacer()
        }
    }

    private func header(_ app: AppItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(app.name)
                .font(.system(size: 17, weight: .semibold))
            Text(app.id)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(tildePath(app.path))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)

        }
    }

    private var resetButton: some View {
        Button("Reset to stock icon") { library.confirm = library.selectedApp.map { .reset($0) } }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func details(_ app: AppItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Source").foregroundStyle(.tertiary)
                if let url = app.sourceURL {
                    Link(app.sourceDescription, destination: url)
                        .foregroundStyle(.primary)
                } else {
                    Text(app.sourceDescription)
                }
            }
            GridRow {
                Text("Icon").foregroundStyle(.tertiary)
                Text(app.iconFileDescription)
            }
            GridRow {
                Text("Applied").foregroundStyle(.tertiary)
                Text(app.entry?.updatedAt.shortDay ?? "")
            }
        }
        .font(.system(size: 12))
    }

    private func healthyDetail(_ app: AppItem) -> String {
        let size = bytes(app.inspection?.rsrcSize ?? 0)
        guard app.installed else { return String(localized: "Flag set, \(size) icon resource.") }
        let live = IconFS.inspect(app.path, withHash: true)
        if let applied = app.entry?.appliedRsrcSHA256, let now = live.rsrcSHA256 {
            return applied == now
                ? String(localized: "Flag set, \(size) icon resource, matches the kept file.")
                : String(localized: "Flag set, \(size) icon resource, but it is not the one Livery wrote. Repair to bring the kept icon back.")
        }
        return String(localized: "Flag set, \(size) icon resource.")
    }
}

struct PreviewCard: View {
    let image: NSImage?
    let caption: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 72, height: 72)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hairline))
    }
}

struct DiagnosisRow: View {
    let ok: Bool
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark" : "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ok ? Color.healthy : Color.attention)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 12.5))
            Spacer()
            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }
}

/// Icons macosicons.com has for this app, one click each. The manual search and a local file sit underneath.
struct SuggestionsSection: View {
    @Environment(Library.self) private var library
    let app: AppItem
    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(app.isTracked ? "OTHER ICONS FOR THIS APP" : "ICONS FOR THIS APP")
            content
            HStack(spacing: 8) {
                Button("Search more…") { library.chooseIcon(for: app) }
                Button("Choose file…") { library.chooseIconFile(for: app.ref) }
            }
            .controlSize(.small)
        }
        .task(id: app.id) {
            // With automatic lookups off, nothing is sent until the user clicks Look up icons.
            guard library.autoSuggest || library.hasCachedSuggestions(for: app) else { return }
            if !library.hasCachedSuggestions(for: app) {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
            }
            await library.loadSuggestions(for: app)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let hits = library.suggestions[app.id], !hits.isEmpty {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(hits) { hit in
                    SuggestionTile(hit: hit, app: app)
                }
            }
        } else if library.suggestionsLoading.contains(app.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up “\(Library.searchTerm(for: app))”…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else if library.isRateLimited {
            VStack(alignment: .leading, spacing: 6) {
                Text(library.quotaExhausted
                     ? "macosicons.com's monthly API quota is used up (50 calls on the free key). The Iconic catalog serves the same icons without a key."
                     : "The icon catalog is rate limiting right now. Cached icons still show; new lookups pause for a few minutes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if library.quotaExhausted {
                        Button("Use Iconic catalog") {
                            library.iconSource = .iconic
                            Task { await library.loadSuggestions(for: app, force: true) }
                        }
                        .controlSize(.small)
                    }
                    Button("Try again") { Task { await library.loadSuggestions(for: app, force: true) } }
                        .controlSize(.small)
                }
            }
        } else if let error = library.suggestionErrors[app.id] {
            if error.contains("no API key") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macosicons.com needs an API key. The Iconic catalog serves the same icons without one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Use Iconic catalog") {
                            library.iconSource = .iconic
                            Task { await library.loadSuggestions(for: app, force: true) }
                        }
                        .controlSize(.small)
                        SettingsLink { Text("Settings…") }
                            .controlSize(.small)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button("Try again") { Task { await library.loadSuggestions(for: app, force: true) } }
                        .controlSize(.small)
                }
            }
        } else if !library.autoSuggest, library.suggestions[app.id] == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Automatic lookups are off. Looking up sends “\(Library.searchTerm(for: app))” to \(library.iconSource.title).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Look up icons") { Task { await library.loadSuggestions(for: app, force: true) } }
                    .controlSize(.small)
            }
        } else {
            Text("Nothing in the catalog for “\(Library.searchTerm(for: app))”.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SuggestionTile: View {
    @Environment(Library.self) private var library
    let hit: IconHit
    let app: AppItem

    var body: some View {
        Button {
            Task { await library.apply(hit: hit, to: app.ref) }
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let preview = library.preview(for: hit) {
                        Image(nsImage: preview).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.hairline)
                    }
                }
                .frame(width: 60, height: 60)
                .task { await library.loadPreview(for: hit) }
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(library.isBusy)
        .help(hit.author.isEmpty ? String(localized: "Use this icon for \(app.name)") : String(localized: "Use this icon for \(app.name) (by \(hit.author))"))
    }

    private var caption: String {
        if let downloads = hit.downloads, downloads > 0 { return String(localized: "\(downloads) dl") }
        return hit.author.isEmpty ? "macosicons.com" : hit.author
    }
}
