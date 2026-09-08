import AppKit
import LiveryCore
import SwiftUI

/// The two approvals macOS wants before the helper can write into root-owned bundles, each with a status light that
/// reflects what the system actually says and a button that does the one thing needed. The panel keeps checking while
/// it is open, so a switch flipped in System Settings turns its light green without anything to click here.
///
/// The App Management row is Livery's own: tccd attributes the daemon living inside the bundle to the bundle
/// (`AUTHREQ_SUBJECT: subject=com.shuiandy.Livery` while the accessor is the helper). Nothing has to be added to the
/// list by hand: the first request makes macOS create the row itself, so the button here simply asks.
struct HelperSetupView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up the helper")
                    .font(.title2.weight(.semibold))
                Text("Apps installed by the App Store or an installer belong to root. Livery writes their icons through a small helper that macOS asks you to approve twice, once each. After that every write is silent, including repairs after an app updates.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupStep(number: 1, status: loginStatus, title: String(localized: "Allow Livery in the background"),
                      detail: String(localized: "System Settings › General › Login Items & Extensions › Allow in the Background. Turn on Livery.")) {
                HStack(spacing: 8) {
                    if library.helperState == .notInstalled || library.helperState == .unknown {
                        Button("Register helper") {
                            Task { await library.ensureHelper { await library.refreshHelperStateNow() } }
                        }
                    }
                    Button("Open Login Items") { HelperManager.openApprovalSettings() }
                }
                .controlSize(.small)
            }

            SetupStep(number: 2, status: grantStatus, title: String(localized: "Let the helper manage apps"),
                      detail: grantDetail) {
                if library.helperNeeded {
                    HStack(spacing: 8) {
                        Button("Ask macOS") { Task { await library.probeHelperGrant() } }
                            .disabled(library.helperState != .enabled)
                        Button("Open App Management") { NSWorkspace.shared.open(Library.settingsURL) }
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                if let message = library.helperProbeMessage, library.helperGrant == .denied {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Check again") { Task { await check() } }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 560)
        .task {
            // Poll while open: the switches live in System Settings, and nobody wants to come back and click Refresh.
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func check() async {
        await library.refreshHelperStateNow()
        await library.probeHelperGrant()
    }

    private var loginStatus: SetupStatus {
        switch library.helperState {
        case .enabled: return .done(String(localized: "Approved"))
        case .requiresApproval: return .waiting(String(localized: "Waiting for the switch"))
        case .notInstalled, .unknown: return .waiting(String(localized: "Not registered yet"))
        }
    }

    private var grantStatus: SetupStatus {
        guard library.helperNeeded else { return .done(String(localized: "Not needed: no app here is owned by root")) }
        guard library.helperState == .enabled else { return .blocked(String(localized: "After step 1")) }
        guard library.helperReachable else { return .waiting(String(localized: "Helper starting…")) }
        switch library.helperGrant {
        case .allowed: return .done(String(localized: "Approved"))
        case .denied: return .waiting(String(localized: "Waiting for the switch"))
        case .unknown: return .waiting(String(localized: "Checking…"))
        }
    }

    private var grantDetail: String {
        library.helperNeeded
            ? String(localized: "Ask macOS puts Livery on the list under System Settings › Privacy & Security › App Management, or shows an approval dialog. Make sure the Livery switch there is on. The helper lives inside Livery, so this one switch covers both.")
            : String(localized: "Every app on this Mac is writable by you, so the helper has nothing to do.")
    }
}

enum SetupStatus {
    case done(String), waiting(String), blocked(String)

    var label: String {
        switch self {
        case .done(let text), .waiting(let text), .blocked(let text): return text
        }
    }

    var colour: Color {
        switch self {
        case .done: return .healthy
        case .waiting: return .attention
        case .blocked: return .secondary.opacity(0.5)
        }
    }
}

private struct SetupStep<Actions: View>: View {
    let number: Int
    let status: SetupStatus
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.card).frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.hairline))
                Text("\(number)").font(.system(size: 12, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Circle()
                        .fill(status.colour)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(status.colour.opacity(0.25), lineWidth: 3).padding(-3))
                    Text(status.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(status.label)")
    }
}
