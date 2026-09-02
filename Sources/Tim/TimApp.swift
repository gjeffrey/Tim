import SwiftUI
import AppKit
import TimKit
import Sparkle

/// App settings — the small, opinionated set. Defaults lean clean;
/// each toggle brings back the traditional chrome for those who want it.
struct TimSettings: View {
    @AppStorage("tim.cleanAddresses") private var cleanAddresses = true
    @AppStorage("tim.tabDomains") private var tabDomains = false

    var body: some View {
        Form {
            Section("Address Bar") {
                Toggle("Simplified addresses", isOn: $cleanAddresses)
                Text("Show the page as a name — no http:// or www — until you click the address to edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Tabs") {
                Toggle("Show domains in tabs", isOn: $tabDomains)
                Text("Add each page's domain under its title in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@main
struct TimApp: App {
    @StateObject private var store = BrowserStore()
    @StateObject private var siteStore = SiteStore()

    /// Sparkle: feed and public key come from Info.plist (set by
    /// Scripts/make-app.sh); started lazily so `swift run` stays quiet.
    private static let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private static var updaterStarted = false

    static func checkForUpdates() {
        if !updaterStarted {
            updaterController.startUpdater()
            updaterStarted = true
        }
        updaterController.updater.checkForUpdates()
    }

    init() {
        // Preload picker previews: warm the curated catalog's fonts
        // (download-once, persistent) so lists render instantly.
        GoogleFonts.prewarm(FontCatalog.options.compactMap { $0.googleQuery != nil ? $0.name : nil })
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
        Settings {
            TimSettings()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { TimApp.checkForUpdates() }
            }
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
                Button("Zoom In") {
                    if let view = store.selectedTab?.webView { view.magnification = min(3, view.magnification * 1.25) }
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") {
                    if let view = store.selectedTab?.webView { view.magnification = max(0.2, view.magnification / 1.25) }
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") {
                    store.selectedTab?.webView.magnification = 1
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Zoom to Fit") {
                    guard let tab = store.selectedTab else { return }
                    // Fit everything, pasteboard included: the overflow
                    // ratio of the canvas decides the magnification.
                    tab.webView.evaluateJavaScript(
                        "(function(){var c=document.querySelector('[data-tim-canvas]');return c?Math.max(1,c.scrollWidth/c.clientWidth):1;})()"
                    ) { result, _ in
                        let ratio = (result as? Double) ?? 1
                        tab.webView.magnification = ratio > 1.01 ? 1 / ratio : 1
                    }
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("Back") { store.selectedTab?.webView.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { store.selectedTab?.webView.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
            }
        }
    }
}
