import AppKit
import LiveryCore
import SwiftUI

struct DiscoverView: View {
    enum Mode {
        case browse
        case pick(AppRef)
    }

    @Environment(Library.self) private var library
    let mode: Mode

    @State private var query = ""
    @State private var hits: [IconHit] = []
    @State private var page = 1
    @State private var totalPages: Int?
    @State private var totalHits: Int?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var needsKey = false
    @State private var keyDraft = ""
    @State private var hasSearched = false

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search the icon catalog", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search(fresh: true) }
                Button("Search") { search(fresh: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider()
            content
        }
        .task {
            if case .pick(let target) = mode, query.isEmpty {
                query = target.name
                search(fresh: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if needsKey {
            keyForm
        } else if let searchError {
            ContentUnavailableView {
                Label("Search failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(searchError)
            } actions: {
                Button("Try again") { search(fresh: true) }
            }
        } else if hits.isEmpty {
            ContentUnavailableView {
                Label(hasSearched ? "No icons for “\(query)”" : "Search the icon catalog", systemImage: "sparkle")
            } description: {
                Text(hasSearched ? "Try the app's short name or a different spelling." : "Type an app name. Every result can be used for any app you track.")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let totalHits {
                        Text(totalHits == 1 ? "1 icon" : "\(totalHits) icons")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(hits) { hit in
                            HitTile(hit: hit, mode: mode)
                        }
                    }
                    if let totalPages, page < totalPages {
                        HStack {
                            Spacer()
                            Button("Load more") { search(fresh: false) }
                                .disabled(isSearching)
                            Spacer()
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var keyForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macosicons.com needs an API key")
                .font(.headline)
            Text("The Iconic catalog serves the same icons without a key; switch to it in Settings. Or get a free key at macosicons.com/developers (50 calls a month), paste it here, and it is stored in ~/.config/livery/api-key.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Link("Open macosicons.com/developers", destination: URL(string: "https://macosicons.com/developers")!)
                .font(.system(size: 12))
        }
        .frame(maxWidth: 440)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func saveKey() {
        do {
            try MacOSIcons.saveKey(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            keyDraft = ""
            needsKey = false
            if !query.isEmpty { search(fresh: true) }
        } catch {
            searchError = "\(error)"
        }
    }

    private func search(fresh: Bool) {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !isSearching else { return }
        let nextPage = fresh ? 1 : page + 1
        isSearching = true
        searchError = nil
        Task {
            do {
                let response = try await library.search(term, page: nextPage)
                if fresh { hits = response.hits } else { hits += response.hits }
                page = nextPage
                totalPages = response.totalPages
                totalHits = response.totalHits
                hasSearched = true
                needsKey = false
            } catch {
                let text = "\(error)"
                if text.contains("no API key") {
                    needsKey = true
                } else {
                    searchError = text
                }
            }
            isSearching = false
        }
    }
}

struct HitTile: View {
    @Environment(Library.self) private var library
    let hit: IconHit
    let mode: DiscoverView.Mode

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let preview = library.preview(for: hit) {
                    Image(nsImage: preview).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(Color.hairline)
                }
            }
            .frame(width: 84, height: 84)
            .task { await library.loadPreview(for: hit) }
            Text(hit.appName ?? "Untitled")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            useControl
                .controlSize(.small)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hairline))
    }

    private var caption: String {
        var parts: [String] = []
        if !hit.author.isEmpty { parts.append(hit.author) }
        if let downloads = hit.downloads, downloads > 0 { parts.append("\(downloads) dl") }
        if hit.icnsUrl == nil { parts.append("png only") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var useControl: some View {
        switch mode {
        case .pick(let target):
            Button("Use for \(target.name)") {
                Task { await library.apply(hit: hit, to: target) }
            }
            .disabled(library.isBusy)
        case .browse:
            Button("Use for…") { library.pendingHit = PendingHit(hit: hit) }
            .disabled(library.isBusy)
        }
    }
}

struct ChooseIconSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let target: AppRef

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: target.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose an icon for \(target.name)")
                        .font(.headline)
                    Text(tildePath(target.path))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose file…") {
                    dismiss()
                    library.chooseIconFile(for: target)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            DiscoverView(mode: .pick(target))
        }
        .frame(width: 780, height: 580)
    }
}

/// Which app should get a search result. Searchable because the library lists every installed app.
struct AppPickerSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let hit: IconHit
    @State private var filter = ""

    private var candidates: [AppItem] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return library.apps }
        return library.apps.filter { $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    if let preview = library.preview(for: hit) {
                        Image(nsImage: preview).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color.hairline)
                    }
                }
                .frame(width: 36, height: 36)
                .task { await library.loadPreview(for: hit) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use “\(hit.appName ?? "this icon")” for which app?")
                        .font(.headline)
                    Text(hit.author.isEmpty ? "icon catalog" : "by \(hit.author)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Other app…") {
                    guard let target = library.pickApp(named: "Which app should get this icon?") else { return }
                    Task { await library.apply(hit: hit, to: target) }
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            TextField("Filter apps", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            List(candidates) { app in
                Button {
                    Task { await library.apply(hit: hit, to: app.ref) }
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: library.keptIcon(for: app) ?? library.finderIcon(for: app))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 24, height: 24)
                        Text(app.name)
                        Spacer()
                        if app.isTracked {
                            Text("custom icon")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(width: 520, height: 520)
        .disabled(library.isBusy)
    }
}
