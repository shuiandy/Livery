import AppKit
import LiveryCore
import SwiftUI

@main
struct LiveryApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup("Livery") {
            ContentView()
                .environment(library)
                .frame(minWidth: 1000, minHeight: 620)
                .task {
                    // A rebuilt bundle carries a new helper binary; re-registering hands it to launchd.
                    await Task.detached { HelperManager.refreshIfEnabled() }.value
                    library.refreshHelperState()
                    Commands.sweepStagingFiles()
                    if CommandLine.arguments.contains("--install-helper") {
                        await library.ensureHelper { library.refreshHelperState() }
                    }
                    if CommandLine.arguments.contains("--remove-helper") {
                        _ = await Task.detached { HelperManager.uninstall() }.value
                        library.refreshHelperState()
                    }
                    if CommandLine.arguments.contains("--reinstall-helper") {
                        // Unregister first so launchd drops the old daemon process, then register the bundle's current binary.
                        _ = await Task.detached { HelperManager.uninstall() }.value
                        await library.ensureHelper { library.refreshHelperState() }
                    }
                }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add App…") { library.addApp() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Icons") {
                Button("Check Now") { library.checkNow() }
                    .keyboardShortcut("r")
                Button("Fix All") { library.fixAll() }
                    .disabled(library.fixableApps.isEmpty)
                Button("Restore All Stock Icons…") { library.confirm = .resetAll(library.trackedCount) }
                    .disabled(library.trackedCount == 0)
                Divider()
                Button("Restart Dock") { Dock.restart() }
                Button("Reveal Library in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.support])
                }
            }
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}
