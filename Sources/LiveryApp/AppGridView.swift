import AppKit
import LiveryCore
import SwiftUI

struct AppGridView: View {
    @Environment(Library.self) private var library
    let apps: [AppItem]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            if apps.isEmpty {
                ContentUnavailableView.search(text: library.searchText)
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(apps) { app in
                        // A Button rather than a tap gesture: this is what gives the tile keyboard focus, the return
                        // key, and a VoiceOver role instead of an unlabelled image.
                        Button { library.selection = app.id } label: {
                            AppTile(app: app, selected: app.id == library.selection)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(app.name)
                        .accessibilityValue(app.state.title)
                        .accessibilityHint("Shows this app in the inspector")
                        .accessibilityAddTraits(app.id == library.selection ? [.isButton, .isSelected] : .isButton)
                        .contextMenu { AppContextMenu(app: app) }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

struct AppTile: View {
    @Environment(Library.self) private var library
    let app: AppItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: primaryIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .opacity(app.state == .missing ? 0.45 : 1)
                if app.state.needsFix, let kept = library.keptIcon(for: app) {
                    Image(nsImage: kept)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.card))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.card, lineWidth: 2))
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .offset(x: 8, y: 4)
                }
            }
            Text(app.name)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if app.state.needsAttention {
                Text(app.state.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(app.state == .missing ? Color.secondary : Color.attention)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
    }

    private var primaryIcon: NSImage {
        switch app.state {
        case .healthy, .missing: return library.keptIcon(for: app) ?? library.finderIcon(for: app)
        default: return library.finderIcon(for: app)
        }
    }
}

struct AppContextMenu: View {
    @Environment(Library.self) private var library
    let app: AppItem

    var body: some View {
        if app.state.needsFix {
            Button("Repair icon") { library.repair(app) }
        }
        Button(app.isTracked ? "Choose another icon…" : "Choose an icon…") { library.chooseIcon(for: app) }
        if app.installed {
            Button("Reveal in Finder") { library.revealInFinder(app) }
        }
        if let url = app.sourceURL {
            Link("Open icon page", destination: url)
        }
        if app.isTracked {
            Divider()
            if app.state == .missing {
                Button("Locate app…") { library.locate(app) }
                // Both of these throw away tracking, so they ask first here just as the inspector does.
                Button("Stop tracking…") { library.confirm = .stopTracking(app) }
            } else {
                Button("Reset to stock icon…") { library.confirm = .reset(app) }
            }
        }
    }
}

struct AppListView: View {
    @Environment(Library.self) private var library
    let apps: [AppItem]

    var body: some View {
        @Bindable var library = library
        Table(apps, selection: $library.selection) {
            TableColumn("App") { app in
                HStack(spacing: 8) {
                    Image(nsImage: library.keptIcon(for: app) ?? library.finderIcon(for: app))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                    Text(app.name)
                }
            }
            .width(min: 180)
            TableColumn("Source") { app in
                Text(app.sourceDescription)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Icon") { app in
                if app.isTracked {
                    HealthChip(state: app.state)
                } else {
                    Text("Stock")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 140)
            TableColumn("Applied") { app in
                Text(app.entry?.updatedAt.shortDay ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let app = library.app(for: id) {
                AppContextMenu(app: app)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.hairline))
        .padding(.bottom, 24)
    }
}
