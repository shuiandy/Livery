import AppKit
import LiveryCore
import SwiftUI

extension Color {
    /// Amber used for every "needs attention" signal; never for actions.
    static let attention = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.90, green: 0.66, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.49, blue: 0.08, alpha: 1)
    })

    static let healthy = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.30, green: 0.75, blue: 0.47, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.62, blue: 0.36, alpha: 1)
    })

    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
}

extension Date {
    var shortDay: String {
        formatted(.dateTime.day().month(.abbreviated).year())
    }
}

func bytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

func tildePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

struct SectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.3)
    }
}

struct HealthChip: View {
    let state: AppState

    var body: some View {
        Text(state.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch state {
        case .healthy: return .healthy
        case .missing, .untracked: return .secondary
        default: return .attention
        }
    }
}
