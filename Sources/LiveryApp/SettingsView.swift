import AppKit
import LiveryCore
import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @AppStorage("restartDockAfterRepair") private var restartDock = false
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var showHelperSetup = false

    var body: some View {
        Form {
            Section("Icon catalog") {
                Picker("Search icons on", selection: sourceBinding) {
                    ForEach(IconSource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                Text("Both serve the same 30,000-icon library. Iconic needs no key. macosicons.com needs a free key and allows 50 calls a month on the free plan, 1,000 with macOSicons+.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Look up icons automatically when an app is selected", isOn: autoSuggestBinding)
                Text("A lookup sends the app's name, and nothing else, to the catalog above. Switched off, nothing is sent until you click Look up icons or Search more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("macosicons.com API key") {
                HStack {
                    SecureField("API key", text: $keyDraft, prompt: Text(hasKey ? "A key is stored" : "Paste your key"))
                    Button("Save") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let keyStatus {
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Stored in \(tildePath(Paths.apiKeyFile.path)). Free keys at macosicons.com/developers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Privileged helper") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(library.helperStatusText)
                        .foregroundStyle(.secondary)
                    Button("Set up…") { showHelperSetup = true }
                    if library.helperState == .enabled {
                        Button("Remove") { library.uninstallHelper() }
                    }
                }
                Text("Writes icons into bundles owned by root, which is how the App Store and installers leave them. Needs two one-time approvals; Set up shows where each stands and walks through them. After that every write is silent, including repairs after an app updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Background agent") {
                Toggle("Watch Applications folders and repair icons automatically", isOn: agentInstalled)
                Text(agentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("After a repair") {
                Toggle("Restart the Dock so it picks up the new icon", isOn: $restartDock)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .sheet(isPresented: $showHelperSetup) {
            HelperSetupView()
                .environment(library)
        }
        .onAppear {
            library.refreshAgent()
            library.refreshHelperState()
        }
    }

    private var hasKey: Bool { (try? MacOSIcons.apiKey()) != nil }

    private var autoSuggestBinding: Binding<Bool> {
        Binding(get: { library.autoSuggest }, set: { library.autoSuggest = $0 })
    }

    private var sourceBinding: Binding<IconSource> {
        Binding(get: { library.iconSource }, set: { library.iconSource = $0 })
    }

    private var agentInstalled: Binding<Bool> {
        Binding(
            get: { library.agent.installed },
            set: { on in
                if on { library.installAgent() } else { library.uninstallAgent() }
            }
        )
    }

    private var agentDescription: String {
        if library.agent.installed {
            let pid = library.agent.pid.map { " (pid \($0))" } ?? ""
            return "Runs \(tildePath(library.agent.program ?? Library.cliBinary)) watch\(pid). Log: \(tildePath(Paths.logFile.path))."
        }
        return "Installs the launch agent com.shuiandy.livery that runs the command line tool from \(tildePath(Library.cliBinary))."
    }

    private func saveKey() {
        do {
            try MacOSIcons.saveKey(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            keyDraft = ""
            keyStatus = "Saved."
        } catch {
            keyStatus = "\(error)"
        }
    }
}
