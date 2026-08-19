import SwiftUI
import AppKit
import TimKit

@main
struct TimApp: App {
    @StateObject private var store = BrowserStore()
    @StateObject private var siteStore = SiteStore()

    init() {
        // Running from a Swift Package executable: promote to a regular,
        // focusable app with a menu bar.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            BrowserWindow()
                .environmentObject(store)
                .environmentObject(siteStore)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") {
                    if let tab = store.selectedTab { store.close(tab) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Page") {
                Button("Toggle Edit Mode") {
                    if let tab = store.selectedTab { tab.setEditing(!tab.isEditing) }
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("Reload") { store.selectedTab?.webView.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Back") { store.selectedTab?.webView.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { store.selectedTab?.webView.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
            }
        }
    }
}
