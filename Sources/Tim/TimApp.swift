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
                Button("New Local Page…") { LocalPages.createAndOpen(in: store.selectedTab) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Close Tab") {
                    if let tab = store.selectedTab { store.close(tab) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Page") {
                Button("Toggle Edit Mode") {
                    guard let tab = store.selectedTab else { return }
                    // Editing is for pages you own.
                    if tab.isEditing || siteStore.isEditable(URL(string: tab.urlString)) {
                        tab.setEditing(!tab.isEditing)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("Toggle Mobile Preview") {
                    if let tab = store.selectedTab { tab.setMobilePreview(!tab.isMobilePreview) }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
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
