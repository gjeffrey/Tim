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
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Page…") { NotificationCenter.default.post(name: .timNewPage, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { NotificationCenter.default.post(name: .timOpenPage, object: nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Duplicate…") { NotificationCenter.default.post(name: .timDuplicatePage, object: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Close Tab") {
                    if let tab = store.selectedTab { store.close(tab) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Page") {
                Button("Toggle Edit Mode") { NotificationCenter.default.post(name: .timToggleEdit, object: nil) }
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
