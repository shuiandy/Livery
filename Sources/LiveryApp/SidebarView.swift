import AppKit
import LiveryCore
import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        List(selection: $library.section) {
            Section("Library") {
                Label("All apps", systemImage: "square.grid.2x2")
                    .badge(library.apps.count)
                    .tag(SidebarSection.all)
                Label("Custom icons", systemImage: "paintpalette")
                    .badge(library.trackedCount)
                    .tag(SidebarSection.custom)
                HStack {
                    Label {
                        Text("Needs attention")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.attention)
                    }
                    Spacer()
                    if library.attentionCount > 0 {
                        Text("\(library.attentionCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 18)
                            .background(Capsule().fill(Color.attention))
                    }
                }
                .tag(SidebarSection.attention)
                Label("Recently changed", systemImage: "clock")
                    .tag(SidebarSection.recent)
            }
            Section("Discover") {
                Label("Find icons", systemImage: "sparkle")
                    .tag(SidebarSection.discover)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            WatcherCard()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }
}

struct WatcherCard: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(agentColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(agentColor.opacity(0.25), lineWidth: 3).padding(-3))
                Text(agentTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !library.agent.installed {
                    Button("Install") { library.installAgent() }
                        .controlSize(.mini)
                } else if !agentRunning {
                    Button("Start") { library.startAgent() }
                        .controlSize(.mini)
                }
            }
            if library.agent.installed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(library.watchRoots, id: \.self) { root in
                        Text(tildePath(root))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(startedText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Without the agent, icons are only repaired while this window is open.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: permissionSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(permissionColor)
                Text(permissionText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if library.permission == .denied {
                Button("Open System Settings…") { NSWorkspace.shared.open(Library.settingsURL) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hairline))
    }

    private var agentRunning: Bool { library.agent.loaded && library.agent.pid != nil }

    private var agentTitle: String {
        if agentRunning { return "Watching" }
        if library.agent.installed { return "Agent stopped" }
        return "Agent not installed"
    }

    private var agentColor: Color {
        if agentRunning { return .healthy }
        if library.agent.installed { return .attention }
        return .secondary
    }

    private var startedText: String {
        guard let started = library.agentStarted else { return "Nothing logged yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Started " + formatter.localizedString(for: started, relativeTo: Date())
    }

    private var permissionSymbol: String {
        switch library.permission {
        case .allowed: return "checkmark"
        case .denied: return "xmark"
        case .unknown: return "questionmark"
        }
    }

    private var permissionColor: Color {
        switch library.permission {
        case .allowed: return .healthy
        case .denied: return .attention
        case .unknown: return .secondary
        }
    }

    /// Deliberately names the principal. The app, the agent and the helper each hold their own App Management grant,
    /// and the log only ever shows what happened to the agent.
    private var permissionText: String {
        switch library.permission {
        case .allowed: return "Agent last wrote an icon successfully"
        case .denied:
            if let when = library.lastRefusal {
                return "Agent was refused at " + when.formatted(date: .omitted, time: .shortened)
            }
            return "Agent was refused an icon write"
        case .unknown: return "Agent has not written an icon yet"
        }
    }
}
