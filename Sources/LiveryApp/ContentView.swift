import AppKit
import LiveryCore
import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var showInspector = true

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } detail: {
            HStack(spacing: 0) {
                DetailView()
                if showInspector {
                    Divider()
                    InspectorView()
                        .frame(width: 320)
                        .background(Color.primary.opacity(0.035))
                }
            }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if library.section != .discover {
                            Picker("Layout", selection: $library.layout) {
                                Image(systemName: "square.grid.2x2").tag(LayoutMode.grid)
                                Image(systemName: "list.bullet").tag(LayoutMode.list)
                            }
                            .pickerStyle(.segmented)
                            .help("Grid or list")
                        }
                        Button("Check now") { library.checkNow() }
                            .help("Re-read every app (⌘R)")
                        Button {
                            library.addApp()
                        } label: {
                            Label("Other app…", systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Pick an app that is not in an Applications folder (⌘N)")
                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide the inspector")
                    }
                }
        }
        .navigationTitle((library.section ?? .all).title)
        .navigationSubtitle(subtitle)
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search apps")
        .background(Color.clear.sheet(item: $library.iconPickerTarget) { target in
            ChooseIconSheet(target: target)
                .environment(library)
        })
        .background(Color.clear.sheet(item: $library.pendingHit) { pending in
            AppPickerSheet(hit: pending.hit)
                .environment(library)
        })
        .background(Color.clear.alert(ownershipTitle, isPresented: ownershipPresented, presenting: library.ownershipPrompt) { prompt in
            Button("Set up…") { Task { await prompt.asAdministrator() } }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(ownershipMessage(prompt))
        })
        .background(Color.clear.confirmationDialog(library.confirm?.title ?? "", isPresented: confirmPresented,
                                                   titleVisibility: .visible, presenting: library.confirm) { pending in
            Button(pending.actionTitle, role: pending.isDestructive ? .destructive : nil) { library.perform(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        })
        .background(Color.clear.sheet(isPresented: $library.helperSetupPresented) {
            HelperSetupView()
                .environment(library)
        })
        .background(Color.clear.alert("Livery could not finish", isPresented: errorPresented) {
            if libraryErrorMentionsPermission {
                Button("Open System Settings") { NSWorkspace.shared.open(Library.settingsURL) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        })
    }

    private var subtitle: String {
        func apps(_ n: Int) -> String { n == 1 ? "1 app" : "\(n) apps" }
        switch library.section ?? .all {
        case .all: return "\(apps(library.apps.count)), \(library.trackedCount) with custom icons"
        case .custom, .recent: return apps(library.trackedCount)
        case .attention: return apps(library.attentionCount)
        case .discover: return "\(library.iconSource == .iconic ? "Iconic catalog" : "macosicons.com"), 30,000 icons"
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
    }

    private var libraryErrorMentionsPermission: Bool {
        library.errorMessage?.contains("App Management") ?? false
    }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { library.confirm != nil }, set: { if !$0 { library.confirm = nil } })
    }

    private var ownershipPresented: Binding<Bool> {
        Binding(get: { library.ownershipPrompt != nil }, set: { if !$0 { library.ownershipPrompt = nil } })
    }

    private var ownershipTitle: String {
        guard let prompt = library.ownershipPrompt else { return "" }
        return prompt.names.count == 1 ? "\(prompt.names[0]) is owned by root" : "\(prompt.names.count) apps are owned by root"
    }

    private func ownershipMessage(_ prompt: OwnershipPrompt) -> String {
        let list = prompt.names.joined(separator: ", ")
        return "The App Store or an installer left \(list) owned by root, so nothing running as you can write into the bundle. Livery writes these through a small helper that runs as root. macOS asks for permission once; after that icons are written silently, including repairs after an app updates."
    }
}

struct DetailView: View {
    @Environment(Library.self) private var library

    var body: some View {
        Group {
            if library.section == .discover {
                DiscoverView(mode: .browse)
            } else if library.apps.isEmpty {
                if library.isLoading {
                    ProgressView("Reading Applications…")
                } else {
                    ContentUnavailableView {
                        Label("No apps found", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Nothing in /Applications or ~/Applications. Pick an app from somewhere else.")
                    } actions: {
                        Button("Other app…") { library.addApp() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if library.attentionCount > 0 {
                        AttentionBanner()
                    }
                    if library.layout == .grid {
                        AppGridView(apps: library.visibleApps)
                    } else {
                        AppListView(apps: library.visibleApps)
                    }
                }
                .padding(.top, 20)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            if library.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(16)
            }
        }
    }
}

struct AttentionBanner: View {
    @Environment(Library.self) private var library

    var body: some View {
        let broken = library.apps.filter { $0.state.needsAttention }
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(broken.count == 1 ? "1 app needs attention" : "\(broken.count) apps need attention")
                    .fontWeight(.semibold)
                Text(detail(for: broken))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !library.fixableApps.isEmpty {
                Button(library.fixableApps.count == 1 ? "Repair" : "Fix all") { library.fixAll() }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.isBusy)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.attention.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.attention.opacity(0.25)))
    }

    private func detail(for apps: [AppItem]) -> String {
        let clauses = apps.prefix(3).map { app -> String in
            switch app.state {
            case .folderIcon: return "\(app.name) shows a folder in Finder"
            case .reverted: return "\(app.name) fell back to its stock icon"
            case .missing: return "\(app.name) is no longer where it was"
            case .healthy, .untracked: return app.name
            }
        }
        var sentence: String
        switch clauses.count {
        case 1: sentence = clauses[0]
        case 2: sentence = clauses.joined(separator: " and ")
        default: sentence = clauses.joined(separator: ", ")
        }
        if apps.count > 3 { sentence += ", and \(apps.count - 3) more" }
        sentence += "."
        if !library.fixableApps.isEmpty { sentence += " Repair writes the kept icons back." }
        return sentence
    }
}
