import SwiftUI
import AppKit
import TimKit
import Sparkle

/// App settings — the small, opinionated set. Defaults lean clean;
/// each toggle brings back the traditional chrome for those who want it.
struct TimSettings: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            ExperimentalSettings()
                .tabItem { Label("Experimental", systemImage: "flask") }
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
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
    }
}

/// The beta's rule: the core is what must be solid; everything else is
/// an experiment you opt into here, off by default.
struct ExperimentalSettings: View {
    @AppStorage("tim.experimental.makeItMine") private var makeItMine = false

    var body: some View {
        Form {
            Section {
                // The stored key still says makeItMine; renaming it would
                // lose the setting for anyone who has already turned it on.
                Toggle("Adopt a Page", isOn: $makeItMine)
                Text("Copy a page you're looking at onto your own site, and keep publishing it. Its words and pictures become yours to change; its layout stays as its author built it. Shows as a yellow button in the address bar on pages that aren't yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Experiments")
            } footer: {
                Text("Experimental features may change or disappear between builds.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
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
        // A first window opens with room to edit — sidebar, page, inspector —
        // not at the 900-point floor.
        .defaultSize(width: 1360, height: 860)
        Settings {
            TimSettings()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { TimApp.checkForUpdates() }
            }
            // While a page is being edited, Undo/Redo are the canvas's — the
            // menu's key equivalent fires before the web page ever sees ⌘Z,
            // so it must be routed to the engine here.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if let tab = store.selectedTab, tab.isEditing { tab.undoEdit() }
                    else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    if let tab = store.selectedTab, tab.isEditing { tab.redoEdit() }
                    else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Reopen Closed Tab") {
                    guard let address = store.recentlyClosed.popLast() else { return }
                    store.newTab()
                    store.selectedTab?.navigate(to: address)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(store.recentlyClosed.isEmpty)
                Button("New Page…") { NotificationCenter.default.post(name: .timNewPage, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { NotificationCenter.default.post(name: .timOpenPage, object: nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Location…") { AddressField.focus() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Duplicate…") { NotificationCenter.default.post(name: .timDuplicatePage, object: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                // No shortcut: ⌥⌘M is Minimize All, system-wide.
                Button(store.selectedTab?.webView.url?.isFileURL == true ? "Put It Online…" : "Change Address…") {
                    NotificationCenter.default.post(name: .timMovePage, object: nil)
                }
                Divider()
                Button("Close Tab") {
                    if let tab = store.selectedTab { store.close(tab) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // Where every browser keeps them, with the shortcuts every
            // browser uses. Anything peculiar to Tim stays out of their way.
            CommandGroup(after: .toolbar) {
                Button("Home") { store.selectedTab?.loadStartPage() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Show Next Tab") { store.selectTab(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Show Previous Tab") { store.selectTab(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { store.selectTab(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Divider()
            }
            CommandMenu("Page") {
                Button("Toggle Edit Mode") { NotificationCenter.default.post(name: .timToggleEdit, object: nil) }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Toggle Mobile Preview") {
                    if let tab = store.selectedTab { tab.setMobilePreview(!tab.isMobilePreview) }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Restack iPhone Layout") {
                    NotificationCenter.default.post(name: .timRestackMobile, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.control, .command])
                .disabled(!(store.selectedTab?.isEditing ?? false))
                Button("Reload") { store.selectedTab?.reloadPage() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Submit to Showcase…") { NotificationCenter.default.post(name: .timSubmitShowcase, object: nil) }
                    .disabled(URL(string: store.selectedTab?.urlString ?? "")?.scheme?.hasPrefix("http") != true)
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
                Button("Back") { store.selectedTab?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { store.selectedTab?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
            }
        }
    }
}
