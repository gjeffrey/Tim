import SwiftUI
import AppKit
import WebKit
import TimKit

// SwiftUI has its own `Tab` (TabView); ours wins in this file.
typealias Tab = TimKit.Tab

extension Color {
    /// CSS rgba() at a chosen alpha — shadows want translucency.
    func cssRGBA(_ alpha: Double) -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "rgba(%d, %d, %d, %.2f)",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255)),
            alpha
        )
    }
}

extension Notification.Name {
    static let timNewPage = Notification.Name("tim.newPage")
    static let timOpenPage = Notification.Name("tim.openPage")
    static let timDuplicatePage = Notification.Name("tim.duplicatePage")
    static let timToggleEdit = Notification.Name("tim.toggleEdit")
    static let timThumbsUpdated = Notification.Name("tim.thumbsUpdated")
    static let timPreviewVersion = Notification.Name("tim.previewVersion")
    static let timEditNav = Notification.Name("tim.editNav")
}

struct BrowserWindow: View {
    @EnvironmentObject var store: BrowserStore
    @AppStorage("tim.siteSidebar") private var showSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                UnifiedSidebar()
                Divider()
            }
            if let tab = store.selectedTab {
                TabContentView(tab: tab)
                    .id(tab.id)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Sidebar: vertical tabs above, the current site below (Arc-style)

struct UnifiedSidebar: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var siteStore: SiteStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(store.tabs) { t in
                    VerticalTabRow(
                        tab: t,
                        isSelected: t.id == store.selectedTabID,
                        select: { store.selectedTabID = t.id },
                        close: { store.close(t) }
                    )
                }
                Button {
                    store.newTab()
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)

                if let tab = store.selectedTab {
                    SiteSection(tab: tab)
                        .id(tab.id)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 220)
    }
}

struct VerticalTabRow: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @EnvironmentObject var siteStore: SiteStore
    @State private var hovering = false

    private var isEditable: Bool {
        siteStore.isEditable(URL(string: tab.urlString), timAuthored: tab.isTimPage)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: isEditable ? "pencil.circle.fill" : "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(isEditable ? Color.accentColor : (isSelected ? Color.accentColor : Color.secondary))
                    .help(isEditable ? "This page is yours — you can edit it." : "")
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if tab.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.5)
                } else if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.09) : (hovering ? Color.primary.opacity(0.04) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { Button("Close Tab") { close() } }
    }
}

/// Site pages + history for the selected tab. All filesystem/git reads
/// happen off the main thread into state — body stays pure (the old
/// in-body git calls were the tab-switch crash).
struct SiteSection: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var siteStore: SiteStore

    @State private var pages: [LinkOption] = []
    @State private var hiddenPages: [LinkOption] = []
    @State private var versions: [SiteWorkspace.PageVersion] = []
    @State private var showNewPage = false
    @State private var thumbTick = 0

    private var site: Site? { siteStore.match(URL(string: tab.urlString)) }
    private var currentRel: String? {
        tab.webView.url.flatMap { url in site.map { $0.relativePagePath(for: url) } }
    }

    var body: some View {
        if let site {
            VStack(alignment: .leading, spacing: 10) {
                Divider().padding(.vertical, 6)
                Text(site.name.isEmpty ? site.origin : site.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .id(thumbTick)

                ForEach(pages) { page in
                    Button {
                        // Navigating away mid-edit is safe: the session is
                        // stashed as a draft and resumes on return.
                        tab.navigate(to: site.origin + page.href)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Group {
                                if let thumb = ThumbnailStore.image(for: site.origin + page.href) {
                                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    ZStack {
                                        Rectangle().fill(Color.primary.opacity(0.05))
                                        Image(systemName: "doc.text").foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(page.href == currentRel ? Color.accentColor : Color.primary.opacity(0.12),
                                            lineWidth: page.href == currentRel ? 2 : 1)
                            )
                            HStack(spacing: 5) {
                                Text(page.label)
                                    .font(.system(size: 11.5, weight: page.href == currentRel ? .semibold : .regular))
                                    .lineLimit(1)
                                if DraftStore.has(site.origin + page.href) {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 6, height: 6)
                                        .help("Unsaved changes — open the page to keep editing; Done publishes them.")
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if site.target == .sftp {
                            Button("Hide Page") { hidePage(page) }
                        }
                        Divider()
                        Button("Delete Page…", role: .destructive) { deletePage(page, hidden: false) }
                    }
                }

                Button {
                    showNewPage = true
                } label: {
                    Label("New Page…", systemImage: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showNewPage) {
                    NewPageSheet(site: site, tab: tab)
                }

                Button {
                    NotificationCenter.default.post(name: .timDuplicatePage, object: nil)
                } label: {
                    Label("Duplicate Page…", systemImage: "plus.square.on.square")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if site.target == .sftp, !hiddenPages.isEmpty {
                    Text("Hidden")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(hiddenPages) { page in
                        HStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(page.label)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Show Page") { showPage(page) }
                            if !page.href.hasPrefix("/_hidden/") {
                                Button("Copy Secret Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(site.origin + page.href, forType: .string)
                                }
                            }
                            Divider()
                            Button("Delete Page…", role: .destructive) { deletePage(page, hidden: true) }
                        }
                        .help("On your server at a secret address — unlisted and unguessable, but anyone with the link can open it. Delete fully removes it.")
                    }
                }

                if versions.count > 1 {
                    Text("History")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(versions) { version in
                        Button {
                            NotificationCenter.default.post(
                                name: .timPreviewVersion,
                                object: nil,
                                userInfo: ["sha": version.sha, "label": historyLabel(version.date)]
                            )
                        } label: {
                            HStack(spacing: 7) {
                                Group {
                                    if let thumb = ThumbnailStore.image(for: "version:\(site.localProjectPath):\(currentRel ?? ""):\(version.sha)") {
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } else {
                                        ZStack {
                                            Rectangle().fill(Color.primary.opacity(0.05))
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .frame(width: 44, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                )
                                Text(historyLabel(version.date))
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Preview this version — restore it from the panel if it's the one.")
                    }
                }
            }
            .onAppear { refresh() }
            .onChange(of: tab.isLoading) { _, loading in
                if !loading { refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .timThumbsUpdated)) { _ in
                thumbTick += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: DraftStore.changed)) { _ in
                thumbTick += 1
            }
        }
    }

    private func refresh() {
        guard let site else { pages = []; versions = []; return }
        let rel = currentRel
        DispatchQueue.global(qos: .utility).async {
            SiteManifest.refreshIfStale(site: site)
            GoogleFonts.prewarm(SiteFonts.used(site: site, pageFonts: []))
            let loadedPages = LinkSources.pages(for: site)
            var loadedVersions: [SiteWorkspace.PageVersion] = []
            if let rel, !AstroProject.isAstroProject(site.localProjectPath) {
                loadedVersions = SiteWorkspace.versions(of: String(rel.dropFirst()), in: site.localProjectPath)
            }
            let loadedHidden = AstroProject.isAstroProject(site.localProjectPath)
                ? [] : LinkSources.hiddenPages(for: site)
            DispatchQueue.main.async {
                pages = loadedPages
                hiddenPages = loadedHidden
                versions = loadedVersions
            }
        }
    }

    /// Delete removes the page from the site and the mirror — with a
    /// confirmation, and the invisible history still holds every version.
    private func deletePage(_ page: LinkOption, hidden: Bool) {
        guard var mutableSite = site else { return }
        if mutableSite.localProjectPath.isEmpty {
            mutableSite.localProjectPath = SiteWorkspace.defaultFolder(
                for: mutableSite.name.isEmpty ? mutableSite.origin : mutableSite.name
            )
            siteStore.upsert(mutableSite)
        }
        SiteWorkspace.ensure(mutableSite.localProjectPath)
        let s = mutableSite
        let rel = page.href

        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(page.label)\u{201D}?"
        alert.informativeText = hidden
            ? "Removes this hidden page from your site's local copy. Its history stays in the timeline."
            : "Removes the page from your site and its local copy. Its history stays in the timeline."
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let wasCurrent = currentRel == rel && !hidden
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let localPath = s.localProjectPath + rel
                if hidden, rel.hasPrefix("/_h/") {
                    let root = s.remoteRoot.hasSuffix("/") ? String(s.remoteRoot.dropLast()) : s.remoteRoot
                    _ = try? SFTP.run(batch: "-rm \"\(root + rel)\"\n", host: s.host, username: s.username, port: s.port)
                }
                if !hidden {
                    switch s.target {
                    case .sftp:
                        let root = s.remoteRoot.hasSuffix("/") ? String(s.remoteRoot.dropLast()) : s.remoteRoot
                        _ = try? SFTP.run(batch: "-rm \"\(root + rel)\"\n", host: s.host, username: s.username, port: s.port)
                        try FileManager.default.removeItem(atPath: localPath)
                    case .cloudflare:
                        try FileManager.default.removeItem(atPath: localPath)
                        _ = try CloudflarePublisher.deploy(folder: s.localProjectPath, projectName: s.cfProjectName)
                    case .githubPages:
                        try FileManager.default.removeItem(atPath: localPath)
                        _ = try GitHubPagesPublisher.publish(repo: s.localProjectPath, message: "Delete \(rel)")
                    }
                } else {
                    try FileManager.default.removeItem(atPath: localPath)
                }
                SiteWorkspace.snapshot(s.localProjectPath, message: "Delete \(rel)")
                DispatchQueue.main.async {
                    refresh()
                    if wasCurrent { tab.navigate(to: s.origin) }
                }
            } catch {
                DispatchQueue.main.async {
                    let failure = NSAlert()
                    failure.messageText = "Delete Page"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                }
            }
        }
    }

    /// Hidden = off your site, parked on the server at a long secret
    /// address (/_h/<random token>/…). Unlisted and effectively impossible
    /// to guess — but anyone with the link can open it, and only Delete
    /// truly removes it. Because it stays on the server, it follows you to
    /// any Mac that refreshes the site's local copy.
    private func hidePage(_ page: LinkOption) {
        guard var mutableSite = site else { return }
        if mutableSite.localProjectPath.isEmpty {
            mutableSite.localProjectPath = SiteWorkspace.defaultFolder(
                for: mutableSite.name.isEmpty ? mutableSite.origin : mutableSite.name
            )
            siteStore.upsert(mutableSite)
        }
        SiteWorkspace.ensure(mutableSite.localProjectPath)
        let s = mutableSite
        let rel = page.href

        let alert = NSAlert()
        alert.messageText = "Hide \u{201C}\(page.label)\u{201D}?"
        alert.informativeText = "It moves to a long secret address on your server — off your site, unlisted, and effectively impossible to guess. But it isn't truly private: anyone who has the link can still open it. Delete is the only way to fully remove it."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let hiddenRel = "/_h/\(token)" + rel
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let root = s.remoteRoot.hasSuffix("/") ? String(s.remoteRoot.dropLast()) : s.remoteRoot
                // mkdir the token path, then move the file server-side.
                var batch = ""
                var cumulative = root
                for component in hiddenRel.split(separator: "/").dropLast() {
                    cumulative += "/" + component
                    batch += "-mkdir \"\(cumulative)\"\n"
                }
                batch += "rename \"\(root + rel)\" \"\(root + hiddenRel)\"\n"
                _ = try SFTP.run(batch: batch, host: s.host, username: s.username, port: s.port)

                let from = s.localProjectPath + rel
                let to = s.localProjectPath + hiddenRel
                try FileManager.default.createDirectory(
                    atPath: (to as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(atPath: to)
                try FileManager.default.moveItem(atPath: from, toPath: to)
                SiteWorkspace.snapshot(s.localProjectPath, message: "Hide \(rel)")
                DispatchQueue.main.async { refresh() }
            } catch {
                DispatchQueue.main.async {
                    let failure = NSAlert()
                    failure.messageText = "Hide Page"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                }
            }
        }
    }

    private func showPage(_ page: LinkOption) {
        guard let s = site else { return }
        let hiddenRel = page.href
        let parts = hiddenRel.split(separator: "/").map(String.init)
        let isLegacy = parts.first == "_hidden"
        let rel = "/" + parts.dropFirst(isLegacy ? 1 : 2).joined(separator: "/")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let root = s.remoteRoot.hasSuffix("/") ? String(s.remoteRoot.dropLast()) : s.remoteRoot
                let from = s.localProjectPath + hiddenRel
                let to = s.localProjectPath + rel
                try FileManager.default.createDirectory(
                    atPath: (to as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(atPath: to)
                try FileManager.default.moveItem(atPath: from, toPath: to)
                if isLegacy {
                    let html = try String(contentsOfFile: to, encoding: .utf8)
                    _ = try SFTP.upload(html: html, to: root + rel, host: s.host, username: s.username, port: s.port)
                } else {
                    do {
                        _ = try SFTP.run(
                            batch: "rename \"\(root + hiddenRel)\" \"\(root + rel)\"\n",
                            host: s.host, username: s.username, port: s.port
                        )
                    } catch {
                        // Server copy missing? Publish from the mirror.
                        let html = try String(contentsOfFile: to, encoding: .utf8)
                        _ = try SFTP.upload(html: html, to: root + rel, host: s.host, username: s.username, port: s.port)
                    }
                }
                SiteWorkspace.snapshot(s.localProjectPath, message: "Show \(rel)")
                DispatchQueue.main.async { refresh() }
            } catch {
                DispatchQueue.main.async {
                    let failure = NSAlert()
                    failure.messageText = "Show Page"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                }
            }
        }
    }

    private func rollback(to sha: String) {
        guard let url = tab.webView.url, var mutableSite = site else { return }
        if mutableSite.localProjectPath.isEmpty {
            mutableSite.localProjectPath = SiteWorkspace.defaultFolder(
                for: mutableSite.name.isEmpty ? mutableSite.origin : mutableSite.name
            )
            siteStore.upsert(mutableSite)
        }
        SiteWorkspace.ensure(mutableSite.localProjectPath)
        guard !AstroProject.isAstroProject(mutableSite.localProjectPath) else { return }
        let s = mutableSite
        let rel = s.relativePagePath(for: url)
        let relPath = String(rel.dropFirst())
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SiteWorkspace.restore(relPath, to: sha, in: s.localProjectPath)
                let html = try String(
                    contentsOfFile: (s.localProjectPath as NSString).appendingPathComponent(relPath),
                    encoding: .utf8
                )
                switch s.target {
                case .sftp:
                    let root = s.remoteRoot.hasSuffix("/") ? String(s.remoteRoot.dropLast()) : s.remoteRoot
                    _ = try SFTP.upload(html: html, to: root + rel, host: s.host, username: s.username, port: s.port)
                case .cloudflare:
                    _ = try CloudflarePublisher.deploy(folder: s.localProjectPath, projectName: s.cfProjectName)
                case .githubPages:
                    _ = try GitHubPagesPublisher.publish(repo: s.localProjectPath, message: "Roll back \(rel)")
                }
                SiteWorkspace.snapshot(s.localProjectPath, message: "Roll back \(rel) to \(sha)")
                DispatchQueue.main.async { tab.webView.reload() }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Roll Back"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - Tab content: native toolbar + (editing bar) + web view

struct TabContentView: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var siteStore: SiteStore

    @State private var addressText: String = ""
    @State private var showPublishSheet = false
    @State private var showConnectSheet = false
    @State private var editingSite: Site?
    @State private var newPageSite: Site?
    @State private var previewSha: String?
    @State private var previewLabel = ""
    @State private var previewHTML = ""
    @AppStorage("tim.siteSidebar") private var showSiteSidebar = true
    @FocusState private var addressFocused: Bool

    private var pageURL: URL? { URL(string: tab.urlString) }
    private var matchedSite: Site? {
        if let site = siteStore.match(pageURL) { return site }
        // Credentials belong to the server: a Tim-authored page on a host
        // we already publish to is editable, and a missing page there can
        // be created — no separate connection required.
        guard tab.isTimPage || tab.lastHTTPStatus == 404, let url = pageURL else { return nil }
        return siteStore.derivedSite(for: url)
    }
    private var isPageEditable: Bool { siteStore.isEditable(pageURL, timAuthored: tab.isTimPage) }

    var body: some View {
        VStack(spacing: 0) {
            if tab.isEditing {
                EditingToolbar(
                    tab: tab,
                    site: matchedSite,
                    publish: { showPublishSheet = true },
                    connect: { showConnectSheet = true }
                )
                Divider()
            }
            HStack(spacing: 0) {
            Group {
                if tab.isMobilePreview {
                    ZStack {
                        Color.primary.opacity(0.045)
                        WebViewContainer(webView: tab.webView)
                            .frame(width: 390)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
                            .padding(.vertical, 20)
                    }
                } else {
                    WebViewContainer(webView: tab.webView)
                }
            }
            if previewSha != nil {
                Divider()
                VersionPreviewPane(
                    dateLabel: previewLabel,
                    onRestore: { restorePreviewedVersion() },
                    onRestoreAsNew: { restorePreviewAsNewPage() },
                    onCancel: { exitVersionPreview() }
                )
            } else if tab.isEditing {
                Divider()
                InspectorView(
                    tab: tab,
                    site: matchedSite,
                    allowsTemplates: matchedSite != nil
                        && !(matchedSite.map { AstroProject.isAstroProject($0.localProjectPath) } ?? false)
                )
            }
            }
        }
        .background(.background)
        .navigationTitle("")
        .toolbar { toolbarContent }
        .onAppear {
            // Your own pages always load fresh — never a stale cached copy
            // of something you just published.
            tab.cacheBypass = { url in siteStore.match(url) != nil }
            addressText = tab.urlString
            if tab.urlString.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    addressFocused = true
                }
            }
        }
        .onChange(of: tab.urlString) { _, newValue in
            if !addressFocused { addressText = newValue }
            previewSha = nil
        }
        .onChange(of: tab.isLoading) { _, loading in
            // Thumbnails fall out of browsing: snapshot owned pages on load.
            guard !loading, let url = tab.webView.url, matchedSite != nil else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 280
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                tab.webView.takeSnapshot(with: config) { image, _ in
                    if let image {
                        ThumbnailStore.save(image, for: url.absoluteString)
                        NotificationCenter.default.post(name: .timThumbsUpdated, object: nil)
                    }
                }
            }
        }
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(tab: tab, site: matchedSite)
        }
        .sheet(isPresented: $showConnectSheet) {
            SiteEditorSheet(site: nil, prefillOrigin: originString(from: pageURL))
        }
        .sheet(item: $editingSite) { site in
            SiteEditorSheet(site: site, prefillOrigin: nil)
        }
        .sheet(item: $newPageSite) { site in
            NewPageSheet(site: site, tab: tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .timNewPage)) { _ in
            if let site = matchedSite, AstroProject.isAstroProject(site.localProjectPath) {
                newPageSite = site
            } else {
                LocalPages.createAndOpen(in: tab)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timOpenPage)) { _ in
            openLocalPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .timDuplicatePage)) { _ in
            duplicatePage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .timPreviewVersion)) { note in
            guard let sha = note.userInfo?["sha"] as? String,
                  let label = note.userInfo?["label"] as? String else { return }
            previewVersion(sha: sha, label: label)
        }
        .onReceive(NotificationCenter.default.publisher(for: .timToggleEdit)) { _ in
            if tab.isEditing {
                finishEditing()
            } else if isPageEditable {
                beginEditing()
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if tab.isEditing, isPlainLocalPage {
                savePlainLocalPage()
            } else if tab.isEditing {
                // Site pages autosave as drafts: the session survives
                // navigation, tab closes, even quitting the app.
                tab.stashDraft()
            }
        }
    }

    /// A local page that isn't a build product of a connected project —
    /// the kind that autosaves like any modern Mac document.
    private var isPlainLocalPage: Bool {
        guard let url = tab.webView.url, url.isFileURL else { return false }
        if let site = matchedSite, AstroProject.isAstroProject(site.localProjectPath) { return false }
        return true
    }

    private func savePlainLocalPage(then completion: (() -> Void)? = nil) {
        guard let url = tab.webView.url, url.isFileURL else { completion?(); return }
        tab.currentHTML { html in
            // Only if the tab is still showing this file — a navigation
            // mid-save must never write another page's DOM here.
            if let html, tab.webView.url == url { try? html.write(to: url, atomically: true, encoding: .utf8) }
            completion?()
        }
    }

    /// Entering edit mode materializes a derived site (a Tim page on a
    /// server we can write to, but outside every explicit connection):
    /// it's saved as a real connection and its mirror starts downloading
    /// while you edit, so Done has the full site to restamp against.
    private func beginEditing() {
        if let matched = matchedSite { _ = ensureWorkspace(matched) }
        tab.setEditing(true)
    }

    /// The DOM about to be saved must still belong to the page this edit
    /// session was on. If the tab navigated mid-save (a stray link, a
    /// redirect), writing would overwrite the page with a different page's
    /// content — so write nothing and say so.
    private func stillOn(_ url: URL) -> Bool {
        if tab.webView.url == url { return true }
        let alert = NSAlert()
        alert.messageText = "Nothing was saved"
        alert.informativeText = "The tab moved to a different page while finishing this edit, so Tim didn't save — that would have overwritten \(url.lastPathComponent) with the wrong page. Go back and edit again."
        alert.runModal()
        return false
    }

    /// Done means done: local pages save, site pages publish. One action.
    private func finishEditing() {
        guard let url = tab.webView.url else { tab.setEditing(false); return }

        if isPlainLocalPage {
            tab.setEditing(false)
            ensureAutoSocialCard {
                savePlainLocalPage {
                    PageRegistry.record(url: url.absoluteString, title: tab.title)
                    captureThumbnailSoon()
                }
            }
            return
        }

        guard let matched = matchedSite else { tab.setEditing(false); return }
        let site = ensureWorkspace(matched)

        if AstroProject.isAstroProject(site.localProjectPath) {
            // Done = sync canvas + text edits to source, build, deploy.
            tab.canvasHTML { canvas in
                tab.collectEdits { edits in
                    tab.setEditing(false)
                    guard stillOn(url) else { return }
                    let pagePath = ComponentLibrary.pageSource(
                        forRelativePagePath: site.relativePagePath(for: url),
                        projectPath: site.localProjectPath
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            if !canvas.isEmpty, let pagePath {
                                _ = try? AstroProject.replaceCanvas(inPageSource: pagePath, with: canvas)
                            }
                            _ = AstroProject.applyEdits(edits, projectPath: site.localProjectPath)
                            _ = try AstroProject.build(projectPath: site.localProjectPath)
                            let dist = AstroProject.distPath(site.localProjectPath)
                            switch site.target {
                            case .cloudflare:
                                _ = try CloudflarePublisher.deploy(folder: dist, projectName: site.cfProjectName)
                            case .githubPages:
                                _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Edit with Tim")
                            case .sftp:
                                _ = try SFTP.uploadDirectory(
                                    local: dist, host: site.host, username: site.username,
                                    port: site.port, remoteRoot: site.remoteRoot
                                )
                            }
                            SiteWorkspace.snapshot(site.localProjectPath, message: "Edit \(site.relativePagePath(for: url))")
                            DispatchQueue.main.async {
                                DraftStore.clear(for: url.absoluteString)
                                PageRegistry.record(url: url.absoluteString, title: tab.title)
                                tab.webView.reload()
                            }
                        } catch {
                            DispatchQueue.main.async { publishAlert(error) }
                        }
                    }
                }
            }
            return
        }

        // Plain site page: Done publishes this page.
        tab.setEditing(false)
        ensureAutoSocialCard {
        tab.currentHTML { html in
            guard let html, stillOn(url) else { return }
            let rel = site.relativePagePath(for: url)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try PageWriter.write(html: html, folder: site.localProjectPath, relativePath: rel)
                    // Components edited inline propagate: harvest this
                    // page's regions into components/, re-stamp every other
                    // page, and republish the ones that changed.
                    let harvested = PageComponents.harvest(fromPageHTML: html)
                    var restamped: [String] = []
                    for (name, inner) in harvested where PageComponents.html(named: name, in: site.localProjectPath) != inner {
                        try? PageComponents.save(name: name, html: inner, in: site.localProjectPath)
                    }
                    if !harvested.isEmpty {
                        restamped = PageComponents.restampAll(in: site.localProjectPath, excludingRel: String(rel.dropFirst()))
                    }
                    let injected = PageComponents.injectTemplateComponents(
                        in: site.localProjectPath, excludingRel: String(rel.dropFirst())
                    )
                    restamped = Array(Set(restamped + injected))
                    // Fonts the page uses join the site's cached list in
                    // tim.json — that's what pins them in every font picker,
                    // on every Mac, without rescanning pages.
                    var manifest = SiteManifest.load(fromMirror: site.localProjectPath)
                    var manifestJSON: String?
                    if manifest.noteFonts(SiteFonts.families(inPageHTML: html)) {
                        manifestJSON = manifest.save(toMirror: site.localProjectPath)
                    }
                    switch site.target {
                    case .sftp:
                        let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                        _ = try SFTP.upload(html: html, to: root + rel, host: site.host, username: site.username, port: site.port)
                        if let manifestJSON {
                            _ = try? SFTP.upload(html: manifestJSON, to: root + "/tim.json", host: site.host, username: site.username, port: site.port)
                        }
                        for pageRel in restamped {
                            let path = (site.localProjectPath as NSString).appendingPathComponent(pageRel)
                            if let pageHTML = try? String(contentsOfFile: path, encoding: .utf8) {
                                _ = try? SFTP.upload(html: pageHTML, to: root + "/" + pageRel, host: site.host, username: site.username, port: site.port)
                            }
                        }
                    case .cloudflare:
                        _ = try CloudflarePublisher.deploy(folder: site.localProjectPath, projectName: site.cfProjectName)
                    case .githubPages:
                        _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Edit \(rel) with Tim")
                    }
                    SiteWorkspace.snapshot(site.localProjectPath, message: "Edit \(rel)")
                    DispatchQueue.main.async {
                        DraftStore.clear(for: url.absoluteString)
                        PageRegistry.record(url: url.absoluteString, title: tab.title)
                        captureThumbnailSoon()
                    }
                } catch {
                    DispatchQueue.main.async { publishAlert(error) }
                }
            }
        }
        }
    }

    /// History is just history: pick a version, the page returns to it —
    /// restored in the mirror, republished, reloaded, and recorded as a
    /// new snapshot (so a rollback can itself be rolled back).
    private func rollbackCurrentPage(to sha: String) {
        guard let url = tab.webView.url, let matched = matchedSite else { return }
        let site = ensureWorkspace(matched)
        guard !AstroProject.isAstroProject(site.localProjectPath) else { return }
        let rel = site.relativePagePath(for: url)
        let relPath = String(rel.dropFirst())
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SiteWorkspace.restore(relPath, to: sha, in: site.localProjectPath)
                let html = try String(
                    contentsOfFile: (site.localProjectPath as NSString).appendingPathComponent(relPath),
                    encoding: .utf8
                )
                switch site.target {
                case .sftp:
                    let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                    _ = try SFTP.upload(html: html, to: root + rel, host: site.host, username: site.username, port: site.port)
                case .cloudflare:
                    _ = try CloudflarePublisher.deploy(folder: site.localProjectPath, projectName: site.cfProjectName)
                case .githubPages:
                    _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Roll back \(rel)")
                }
                SiteWorkspace.snapshot(site.localProjectPath, message: "Roll back \(rel) to \(sha)")
                DispatchQueue.main.async {
                    // The restored version is the page now — an old draft
                    // must not resurrect over it.
                    DraftStore.clear(for: url.absoluteString)
                    tab.webView.reload()
                }
            } catch {
                DispatchQueue.main.async { publishAlert(error) }
            }
        }
    }

    /// The default share card is the page itself: regenerated on every
    /// Done unless the user chose a custom image (auto cards are named
    /// social-<page>.png — the filename is the state, so it holds across
    /// Macs; Clear a custom image and auto resumes next save).
    private func ensureAutoSocialCard(then completion: @escaping () -> Void) {
        guard let url = tab.webView.url else { completion(); return }
        if let matched = matchedSite, AstroProject.isAstroProject(matched.localProjectPath) {
            completion()  // Astro heads aren't round-tripped; theme-level territory.
            return
        }
        tab.pageInfo { info in
            let current = info["ogImage"] as? String ?? ""
            let currentName = (current as NSString).lastPathComponent
            guard current.isEmpty || currentName.hasPrefix("social-") else {
                completion()  // custom image — theirs, never touched
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let config = WKSnapshotConfiguration()
                config.snapshotWidth = 1200
                tab.webView.takeSnapshot(with: config) { image, _ in
                    guard let image, image.size.width > 0 else { completion(); return }
                    let card = NSImage(size: NSSize(width: 1200, height: 630))
                    card.lockFocus()
                    let scaledHeight = image.size.height * (1200 / image.size.width)
                    image.draw(in: NSRect(x: 0, y: 630 - scaledHeight, width: 1200, height: scaledHeight))
                    card.unlockFocus()
                    guard let tiff = card.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:])
                    else { completion(); return }

                    let slug: String
                    if let matched = matchedSite {
                        let rel = matched.relativePagePath(for: url)
                        slug = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                    } else {
                        slug = url.deletingPathExtension().lastPathComponent
                    }
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("social-\(slug).png")
                    try? png.write(to: temp)

                    var resolved = matchedSite
                    if var s = resolved {
                        if s.localProjectPath.isEmpty {
                            s.localProjectPath = SiteWorkspace.defaultFolder(for: s.name.isEmpty ? s.origin : s.name)
                            siteStore.upsert(s)
                        }
                        SiteWorkspace.ensure(s.localProjectPath)
                        resolved = s
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let staged = try? EditingToolbar.stage(fileURL: temp, site: resolved, pageURL: url)
                        DispatchQueue.main.async {
                            if let staged {
                                let value: String
                                if let s = resolved, s.origin.hasPrefix("http") {
                                    value = s.origin + "/" + staged
                                } else {
                                    value = staged
                                }
                                tab.setPageMeta("ogImage", value)
                            }
                            // A beat so the meta lands before serialization.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion() }
                        }
                    }
                }
            }
        }
    }

    /// The sidebar thumbnail should show what you just saved.
    private func captureThumbnailSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let url = tab.webView.url else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 280
            tab.webView.takeSnapshot(with: config) { image, _ in
                if let image {
                    ThumbnailStore.save(image, for: url.absoluteString)
                    NotificationCenter.default.post(name: .timThumbsUpdated, object: nil)
                    // Pair this thumbnail with the commit it documents (the
                    // snapshot lands in the background; give it a beat).
                    if let site = matchedSite, !AstroProject.isAstroProject(site.localProjectPath) {
                        let rel = String(site.relativePagePath(for: url).dropFirst())
                        let mirror = site.localProjectPath
                        let source = ThumbnailStore.path(for: url.absoluteString)
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
                            guard let sha = SiteWorkspace.latestSha(of: rel, in: mirror) else { return }
                            // Keyed per page as well as per commit: a page's
                            // history must only ever show that page.
                            let destination = ThumbnailStore.path(for: "version:\(mirror):/\(rel):\(sha)")
                            try? FileManager.default.removeItem(at: destination)
                            try? FileManager.default.copyItem(at: source, to: destination)
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .timThumbsUpdated, object: nil)
                            }
                        }
                    }
                }
            }
        }
    }

    /// History previews before it restores: load the version into the
    /// web view (nothing changes anywhere), decide in the panel.
    private func previewVersion(sha: String, label: String) {
        guard let url = tab.webView.url, let matched = matchedSite else { return }
        let site = ensureWorkspace(matched)
        let rel = String(site.relativePagePath(for: url).dropFirst())
        DispatchQueue.global(qos: .userInitiated).async {
            guard let html = try? Shell.run("git show \(sha):\(Shell.quoted(rel))", in: site.localProjectPath) else { return }
            DispatchQueue.main.async {
                let proceed = {
                    if tab.isEditing { tab.setEditing(false) }
                    previewHTML = html
                    previewLabel = label
                    previewSha = sha
                    tab.suppressDraftResume = true
                    tab.webView.loadHTMLString(html, baseURL: url)
                }
                // Mid-edit previewing keeps the session: stash first.
                if tab.isEditing { tab.stashDraft { proceed() } } else { proceed() }
            }
        }
    }

    private func exitVersionPreview() {
        previewSha = nil
        previewHTML = ""
        tab.webView.reload()
    }

    private func restorePreviewedVersion() {
        guard let sha = previewSha else { return }
        previewSha = nil
        rollbackCurrentPage(to: sha)
    }

    private func restorePreviewAsNewPage() {
        guard let matched = matchedSite, !previewHTML.isEmpty else { return }
        let site = ensureWorkspace(matched)
        let alert = NSAlert()
        alert.messageText = "Restore as New Page"
        alert.informativeText = "Name for the page:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.stringValue = "restored"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let slug = field.stringValue.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !slug.isEmpty else { return }
        let newRel = "/\(slug).html"
        let html = previewHTML
        previewSha = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PageWriter.write(html: html, folder: site.localProjectPath, relativePath: newRel)
                switch site.target {
                case .sftp:
                    let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                    _ = try SFTP.upload(html: html, to: root + newRel, host: site.host, username: site.username, port: site.port)
                case .cloudflare:
                    _ = try CloudflarePublisher.deploy(folder: site.localProjectPath, projectName: site.cfProjectName)
                case .githubPages:
                    _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Restore version as \(newRel)")
                }
                SiteWorkspace.snapshot(site.localProjectPath, message: "Restore version as \(newRel)")
                DispatchQueue.main.async {
                    PageRegistry.record(url: site.origin + newRel, title: slug)
                    tab.navigate(to: site.origin + newRel)
                }
            } catch {
                DispatchQueue.main.async { publishAlert(error) }
            }
        }
    }

    private func publishAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Publish"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// Makes sure a site has its local mirror, persisting the default.
    private func ensureWorkspace(_ site: Site) -> Site {
        var updated = site
        if updated.localProjectPath.isEmpty {
            updated.localProjectPath = SiteWorkspace.defaultFolder(for: updated.name.isEmpty ? updated.origin : updated.name)
        }
        let isNew = !siteStore.sites.contains { $0.id == updated.id }
        if isNew || site.localProjectPath.isEmpty {
            siteStore.upsert(updated)
        }
        SiteWorkspace.ensure(updated.localProjectPath)
        // A derived site's first real use: quietly pull the server's copy
        // into the fresh mirror so history, components, and restamping
        // have the actual site to work with.
        if isNew { mirrorQuietly(updated) }
        return updated
    }

    private func mirrorQuietly(_ site: Site) {
        guard site.target == .sftp, !site.remoteRoot.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = try? SFTP.downloadDirectory(
                remoteRoot: site.remoteRoot, to: site.localProjectPath,
                host: site.host, username: site.username, port: site.port
            )
            SiteWorkspace.snapshot(site.localProjectPath, message: "Connected \(site.name)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .timThumbsUpdated, object: nil)
            }
        }
    }

    /// You browsed to a page on your site that doesn't exist yet — make it
    /// real at exactly this address, publish it, and reload.
    private func createMissingPage() {
        guard let url = tab.webView.url, let matched = matchedSite else { return }
        let site = ensureWorkspace(matched)
        if AstroProject.isAstroProject(site.localProjectPath) {
            newPageSite = site
            return
        }
        let rel = site.relativePagePath(for: url)
        let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        let html = LocalPage.html(title: name == "index" ? (site.name.isEmpty ? "Home" : site.name) : name.capitalized)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PageWriter.write(html: html, folder: site.localProjectPath, relativePath: rel)
                switch site.target {
                case .sftp:
                    let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                    _ = try SFTP.upload(html: html, to: root + rel, host: site.host, username: site.username, port: site.port)
                case .cloudflare:
                    _ = try CloudflarePublisher.deploy(folder: site.localProjectPath, projectName: site.cfProjectName)
                case .githubPages:
                    _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "New page \(rel) with Tim")
                }
                DispatchQueue.main.async {
                    PageRegistry.record(url: url.absoluteString, title: name)
                    tab.webView.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Create This Page"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func downloadSite(_ site: Site) {
        let s = ensureWorkspace(site)
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                _ = try SFTP.downloadDirectory(
                    remoteRoot: s.remoteRoot, to: s.localProjectPath,
                    host: s.host, username: s.username, port: s.port
                )
                message = "Site downloaded to \(s.localProjectPath)."
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Download Site"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }

    private func revealLocalFolder(_ site: Site) {
        let s = ensureWorkspace(site)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.localProjectPath)])
    }

    private func openLocalPage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            tab.navigate(to: url.absoluteString)
        }
    }

    private func duplicatePage() {
        guard let url = tab.webView.url else { return }
        if let site = matchedSite, AstroProject.isAstroProject(site.localProjectPath) {
            let rel = site.relativePagePath(for: url)
            guard let source = ComponentLibrary.pageSource(
                forRelativePagePath: rel, projectPath: site.localProjectPath
            ) else { return }
            let stem = ((source as NSString).lastPathComponent as NSString).deletingPathExtension + "-copy"
            let destination = ((source as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(stem + ".astro")
            guard !FileManager.default.fileExists(atPath: destination) else { return }
            try? FileManager.default.copyItem(atPath: source, toPath: destination)
            let project = site.localProjectPath
            let origin = site.origin
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? AstroProject.build(projectPath: project)
                DispatchQueue.main.async { tab.navigate(to: origin + "/" + stem + ".html") }
            }
        } else if let matched = matchedSite {
            // Plain site page: name the copy, publish it alongside.
            let site = ensureWorkspace(matched)
            let rel = site.relativePagePath(for: url)
            let stem = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
            let alert = NSAlert()
            alert.messageText = "Duplicate Page"
            alert.informativeText = "Name for the copy:"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
            field.stringValue = stem + "-copy"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Duplicate")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let slug = field.stringValue.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            guard !slug.isEmpty else { return }
            let newRel = "/\(slug).html"
            let sourcePath = (site.localProjectPath as NSString).appendingPathComponent(String(rel.dropFirst()))
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let html = try String(contentsOfFile: sourcePath, encoding: .utf8)
                    try PageWriter.write(html: html, folder: site.localProjectPath, relativePath: newRel)
                    switch site.target {
                    case .sftp:
                        let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                        _ = try SFTP.upload(html: html, to: root + newRel, host: site.host, username: site.username, port: site.port)
                    case .cloudflare:
                        _ = try CloudflarePublisher.deploy(folder: site.localProjectPath, projectName: site.cfProjectName)
                    case .githubPages:
                        _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Duplicate \(rel) as \(newRel)")
                    }
                    SiteWorkspace.snapshot(site.localProjectPath, message: "Duplicate \(rel) as \(newRel)")
                    DispatchQueue.main.async {
                        PageRegistry.record(url: site.origin + newRel, title: slug)
                        tab.navigate(to: site.origin + newRel)
                    }
                } catch {
                    DispatchQueue.main.async { publishAlert(error) }
                }
            }
        } else if url.isFileURL {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " copy.html"
            panel.directoryURL = url.deletingLastPathComponent()
            guard panel.runModal() == .OK, var destination = panel.url else { return }
            if destination.pathExtension.lowercased() != "html" {
                destination.appendPathExtension("html")
            }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: url, to: destination)
            tab.navigate(to: destination.absoluteString)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                showSiteSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show tabs, your site's pages, and history")
            Button {
                tab.webView.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!tab.canGoBack)
            .help("Back (⌘[)")

            Button {
                tab.webView.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!tab.canGoForward)
            .help("Forward (⌘])")
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                if let site = matchedSite {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                        Text(site.name.isEmpty ? "Editable" : site.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                    .help("You own this page — press ⌘E to edit and publish it.")
                }

                if matchedSite != nil, tab.lastHTTPStatus == 404, !tab.isEditing {
                    Button {
                        createMissingPage()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Create This Page")
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .help("This page doesn't exist on your site yet — create and publish it at this address.")
                }

                TextField("Search or enter website name", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .multilineTextAlignment(addressFocused ? .leading : .center)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 240, idealWidth: 440, maxWidth: 520)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isPageEditable ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isPageEditable ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
                    )
                    .focused($addressFocused)
                    .onSubmit {
                        tab.navigate(to: addressText)
                        addressFocused = false
                    }

                Button {
                    if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .help(tab.isLoading ? "Stop" : "Reload (⌘R)")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("", selection: Binding(
                get: { tab.isMobilePreview },
                set: { tab.setMobilePreview($0) }
            )) {
                Image(systemName: "desktopcomputer").tag(false)
                Image(systemName: "iphone").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Preview as Mac or iPhone — same content, both must be excellent")

            if tab.isEditing {
                Button {
                    tab.format("undo")
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Undo")
                Button {
                    tab.format("redo")
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .help("Redo")
                Button("Done") { finishEditing() }
                    .buttonStyle(.borderedProminent)
                    .help("Done (⌘E) — your changes are saved")
            } else if isPageEditable, previewSha == nil {
                Button("Edit") { beginEditing() }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .help("Edit This Page (⌘E)")
            }

            Menu {
                ForEach(siteStore.sites) { site in
                    Menu(site.name.isEmpty ? site.origin : site.name) {
                        Button("Open") { tab.navigate(to: site.origin) }
                        Button("New Page…") { newPageSite = site }
                        let pages = LinkSources.pages(for: site)
                        if !pages.isEmpty {
                            Section("Pages") {
                                ForEach(pages) { page in
                                    Button(page.label) { tab.navigate(to: site.origin + page.href) }
                                }
                            }
                        }
                        Divider()
                        if site.target == .sftp {
                            Button("Refresh Local Copy") { downloadSite(site) }
                        }
                        Button("Show Local Folder") { revealLocalFolder(site) }
                        Button("Edit…") { editingSite = site }
                        Button("Delete", role: .destructive) { siteStore.delete(site) }
                    }
                }
                if !siteStore.sites.isEmpty { Divider() }
                Button("Connect Site…") { showConnectSheet = true }
                if matchedSite == nil {
                    Button("New Local Page…") { LocalPages.createAndOpen(in: tab) }
                }
            } label: {
                Image(systemName: "server.rack")
            }
            .help("My Sites")
        }
    }

    private func originString(from url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL {
            return "file://" + url.deletingLastPathComponent().path
        }
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return origin
    }
}

// MARK: - Editing toolbar (one mode: the canvas)

struct EditingToolbar: View {
    @ObservedObject var tab: Tab
    let site: Site?
    let publish: () -> Void
    let connect: () -> Void
    @EnvironmentObject var siteStore: SiteStore

    @State private var showLinkPopover = false
    @State private var showThemePanel = false
    @State private var showNewPageSheet = false
    @State private var navBuilderSite: Site?
    @State private var statusMessage: String?
    @State private var isWorking = false

    private var isLocalFile: Bool { tab.webView.url?.isFileURL == true }
    private var isAstroSite: Bool {
        guard let site else { return false }
        return AstroProject.isAstroProject(site.localProjectPath)
    }

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Section("Objects") {
                    Button {
                        tab.insertObject(
                            html: #"<div class="tim-object tim-text tim-style-body">Double-click to edit</div>"#,
                            colSpan: 10, rowSpan: 2
                        )
                    } label: {
                        Label("Text Box", systemImage: "character.textbox")
                    }
                    Button {
                        insertMedia()
                    } label: {
                        Label("Media…", systemImage: "photo.on.rectangle.angled")
                    }
                    if let site, !isAstroSite {
                        Button {
                            navBuilderSite = site
                        } label: {
                            Label("Navigation…", systemImage: "list.bullet.rectangle")
                        }
                    }
                }
                if let site, !isAstroSite {
                    Section("Components") {
                        ForEach(PageComponents.list(in: site.localProjectPath), id: \.self) { name in
                            Button(name.capitalized) { insertComponentFragment(name) }
                        }
                        Button("New Component from Selection…") { makeComponentFromSelection() }
                    }
                }
                if isAstroSite {
                    Section("Components") {
                        let components = ComponentLibrary.components(in: site?.localProjectPath ?? "")
                        if components.isEmpty {
                            Text("None in src/components")
                        }
                        ForEach(components) { component in
                            Button(component.props.isEmpty
                                   ? component.name
                                   : "\(component.name) — \(component.props.joined(separator: ", "))") {
                                insertComponent(component)
                            }
                        }
                    }
                    Section("Pages") {
                        Button("New Page…") { showNewPageSheet = true }
                    }
                }
            } label: {
                Label("Insert", systemImage: "plus.square.on.square")
            }
            .fixedSize()

            Menu {
                Button("Title") { tab.applyTextStyle("tim-style-title") }
                Button("Heading") { tab.applyTextStyle("tim-style-heading") }
                Button("Subheading") { tab.applyTextStyle("tim-style-subheading") }
                Button("Body") { tab.applyTextStyle("tim-style-body") }
                Button("Caption") { tab.applyTextStyle("tim-style-caption") }
                Divider()
                Button("Clear Style") { tab.applyTextStyle("") }
            } label: {
                Label("Styles", systemImage: "textformat")
            }
            .fixedSize()

            Divider().frame(height: 16)

            FormatButton(symbol: "bold") { tab.format("bold") }
            FormatButton(symbol: "italic") { tab.format("italic") }
            FormatButton(symbol: "underline") { tab.format("underline") }
            FormatButton(symbol: "strikethrough") { tab.format("strikethrough") }

            Divider().frame(height: 16)

            FormatButton(symbol: "list.bullet") { tab.format("insertUnorderedList") }
            FormatButton(symbol: "list.number") { tab.format("insertOrderedList") }

            FormatButton(symbol: "link") { showLinkPopover = true }
                .popover(isPresented: $showLinkPopover, arrowEdge: .bottom) {
                    LinkPicker(tab: tab, site: site) { showLinkPopover = false }
                }

            if isAstroSite {
                Divider().frame(height: 16)
                Button {
                    showThemePanel = true
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
                .popover(isPresented: $showThemePanel, arrowEdge: .bottom) {
                    ThemePanel(site: site, tab: tab)
                }
            }

            Text("double-click text to edit · drag objects to move · ⌫ deletes")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if site != nil {
                Text("Done publishes")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Done syncs your edits to the site and publishes them.")
            } else if isLocalFile {
                Text("Autosaves")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Local pages save continuously — Done finishes up.")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .sheet(isPresented: $showNewPageSheet) {
            NewPageSheet(site: site, tab: tab)
        }
        .sheet(item: $navBuilderSite) { navSite in
            NavBuilderSheet(site: navSite, tab: tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .timEditNav)) { _ in
            if let site, tab.isEditing { navBuilderSite = site }
        }
    }

    /// One Media command: pick any file — images, video, and audio embed
    /// as their native elements; anything else becomes a linked file. The
    /// file lands in the site's mirror (media/) and is pushed to the
    /// site's target, or saved beside a local page.
    private func insertMedia() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        let name = fileURL.lastPathComponent
        let kind = MediaKind.of(fileExtension: fileURL.pathExtension)

        // Resolve the mirror on the main thread (may persist a default).
        var resolvedSite = site
        if var s = resolvedSite {
            if s.localProjectPath.isEmpty {
                s.localProjectPath = SiteWorkspace.defaultFolder(for: s.name.isEmpty ? s.origin : s.name)
                siteStore.upsert(s)
            }
            SiteWorkspace.ensure(s.localProjectPath)
            resolvedSite = s
        }
        let pageURL = tab.webView.url
        isWorking = true
        statusMessage = "Adding \(name)…"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var src = try Self.stage(fileURL: fileURL, site: resolvedSite, pageURL: pageURL)
                // Relative to the current page, so it works under any base
                // path, on file:// previews, and on the live site alike.
                if let resolvedSite, let pageURL {
                    let rel = resolvedSite.relativePagePath(for: pageURL)
                    let depth = max(0, rel.split(separator: "/").count - 1)
                    src = String(repeating: "../", count: depth) + src
                }
                DispatchQueue.main.async {
                    isWorking = false
                    statusMessage = nil
                    insertStaged(kind: kind, src: src, name: name)
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    statusMessage = "Couldn’t add \(name): \(error.localizedDescription)"
                }
            }
        }
    }

    static func stage(fileURL: URL, site: Site?, pageURL: URL?) throws -> String {
        let fm = FileManager.default
        let name = fileURL.lastPathComponent
        if let site, !site.localProjectPath.isEmpty {
            if AstroProject.isAstroProject(site.localProjectPath) {
                for folder in ["public/media", "dist/media"] {
                    let dir = (site.localProjectPath as NSString).appendingPathComponent(folder)
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let dest = (dir as NSString).appendingPathComponent(name)
                    if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
                    try fm.copyItem(atPath: fileURL.path, toPath: dest)
                }
                return "media/\(name)"
            }
            let mediaDir = (site.localProjectPath as NSString).appendingPathComponent("media")
            try fm.createDirectory(atPath: mediaDir, withIntermediateDirectories: true)
            let dest = (mediaDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: fileURL.path, toPath: dest)
            switch site.target {
            case .sftp:
                let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                _ = try SFTP.uploadFile(
                    localPath: dest, toDirectory: root.isEmpty ? "media" : root + "/media", named: name,
                    host: site.host, username: site.username, port: site.port
                )
            case .cloudflare:
                _ = try CloudflarePublisher.deploy(folder: site.localProjectPath, projectName: site.cfProjectName)
            case .githubPages:
                _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Add media \(name)")
            }
            return "media/\(name)"
        }
        if let pageURL, pageURL.isFileURL {
            let dest = pageURL.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: fileURL, to: dest)
            return name
        }
        throw PublishError.failed("Media needs a connected site or a local page to live in.")
    }

    private func insertStaged(kind: MediaKind, src: String, name: String) {
        switch kind {
        case .image:
            tab.insertObject(html: #"<img class="tim-object" src="\#(src)" alt="" />"#, colSpan: 8, rowSpan: 8)
        case .video:
            tab.insertObject(html: #"<video class="tim-object" controls src="\#(src)"></video>"#, colSpan: 12, rowSpan: 8)
        case .audio:
            tab.insertObject(html: #"<audio class="tim-object" controls src="\#(src)"></audio>"#, colSpan: 8, rowSpan: 2)
        case .file:
            tab.insertObject(html: "<div class=\"tim-object tim-text tim-style-body\"><a href=\"\(src)\">\(name)</a></div>", colSpan: 6, rowSpan: 2)
        }
    }

    private func insertComponentFragment(_ name: String) {
        guard let site, let content = PageComponents.html(named: name, in: site.localProjectPath) else { return }
        tab.insertObject(html: PageComponents.stamped(name: name, content: content), colSpan: 24, rowSpan: 3)
    }

    /// Inline components: the selection becomes the master copy; edits to
    /// it on any page update every page on Done.
    private func makeComponentFromSelection() {
        guard let site else { return }
        tab.selectedHTML { html in
            guard !html.isEmpty else {
                statusMessage = "Select an object first, then make it a component."
                return
            }
            let alert = NSAlert()
            alert.messageText = "New Component"
            alert.informativeText = "Name it (nav, footer…). Editing it on any page updates every page that includes it."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
            field.placeholderString = "nav"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            guard !name.isEmpty else { return }
            do {
                try PageComponents.save(name: name, html: html, in: site.localProjectPath)
                tab.replaceSelection(with: PageComponents.stamped(name: name, content: html))
                statusMessage = "\(name) is now a component — insert it on other pages from Insert."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func insertComponent(_ component: AstroComponent) {
        guard let site, let url = tab.webView.url else { return }
        let rel = site.relativePagePath(for: url)
        guard let pagePath = ComponentLibrary.pageSource(
            forRelativePagePath: rel, projectPath: site.localProjectPath
        ) else {
            statusMessage = "Couldn’t find this page’s source file."
            return
        }
        isWorking = true
        statusMessage = "Inserting \(component.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ComponentLibrary.insert(component, intoPageSource: pagePath)
                _ = try AstroProject.build(projectPath: site.localProjectPath)
                DispatchQueue.main.async {
                    isWorking = false
                    statusMessage = "\(component.name) inserted — edit its placeholder text inline."
                    tab.webView.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

}

// MARK: - Link picker: link targets in proximity order

struct LinkPicker: View {
    @ObservedObject var tab: Tab
    let site: Site?
    let dismiss: () -> Void

    @State private var query = ""
    @State private var anchors: [String] = []

    private var pageURL: URL? { tab.webView.url }
    private var siblings: [LinkOption] { LinkSources.siblings(pageURL: pageURL, site: site) }
    private var yours: [LinkOption] { LinkSources.yourPages(excluding: pageURL) }

    private func matches(_ label: String) -> Bool {
        query.isEmpty || label.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Type to filter, or paste any URL", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply(LinkSources.normalize(query)) }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let anchorItems = Array(anchors.enumerated()).filter { matches($0.element) }
                    if !anchorItems.isEmpty {
                        sectionHeader("On This Page")
                        ForEach(anchorItems, id: \.offset) { item in
                            row(label: item.element, detail: "section", symbol: "number") {
                                tab.anchorHref(at: item.offset) { href in apply(href) }
                            }
                        }
                    }
                    let sib = siblings.filter { matches($0.label) }
                    if !sib.isEmpty {
                        sectionHeader(site != nil ? "On This Site" : "In This Folder")
                        ForEach(sib) { option in
                            row(label: option.label, detail: option.href, symbol: "doc.text") {
                                apply(option.href)
                            }
                        }
                    }
                    let mine = yours.filter { matches($0.label) }
                    if !mine.isEmpty {
                        sectionHeader("Your Pages")
                        ForEach(mine) { option in
                            row(label: option.label, detail: option.href, symbol: "globe") {
                                apply(option.href)
                            }
                        }
                    }
                    if anchorItems.isEmpty, sib.isEmpty, mine.isEmpty {
                        Text(query.isEmpty
                             ? "No link targets yet — paste a URL above."
                             : "No matches — press return to link to “\(query)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button("Link") { apply(LinkSources.normalize(query)) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { tab.pageAnchors { anchors = $0 } }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 6)
    }

    private func row(label: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func apply(_ href: String) {
        let value = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        tab.format("createLink", value: value)
        dismiss()
    }
}

struct FormatButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Theme panel (typography + accent, written into the project)

struct ThemePanel: View {
    let site: Site?
    @ObservedObject var tab: Tab

    @State private var headingFont: FontOption = FontCatalog.system
    @State private var bodyFont: FontOption = FontCatalog.system
    @State private var accentColor: Color = .blue
    @State private var importedFonts: [FontOption] = []
    @State private var isApplying = false
    @State private var status: String?
    @State private var browsingFor: FontTarget?

    enum FontTarget: String, Identifiable {
        case heading, body
        var id: String { rawValue }
    }

    private var allFonts: [FontOption] { FontCatalog.options + importedFonts }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Headings")
                    fontPicker(selection: $headingFont, target: .heading)
                }
                GridRow {
                    Text("Body")
                    fontPicker(selection: $bodyFont, target: .body)
                }
                GridRow {
                    Text("Accent")
                    ColorPicker("", selection: $accentColor, supportsOpacity: false)
                        .labelsHidden()
                }
            }

            HStack {
                Button("Import Font…") { importFont() }
                    .controlSize(.small)
                Text("ttf, otf, woff2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Google Fonts are loaded via their CSS API; imported fonts are copied into public/fonts/ with a generated @font-face. Applying writes public/tim-theme.css and links it from your layout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(isApplying ? "Applying…" : "Apply Theme") { applyTheme() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isApplying || site == nil)
            }
        }
        .padding(14)
        .frame(width: 340)
        .popover(item: $browsingFor, arrowEdge: .trailing) { target in
            FontPickerView(
                pinned: SiteFonts.used(site: site, pageFonts: []),
                current: (target == .heading ? headingFont : bodyFont).name
            ) { family in
                let option = fontOption(from: family)
                if !importedFonts.contains(option) { importedFonts.append(option) }
                if target == .heading { headingFont = option } else { bodyFont = option }
                browsingFor = nil
            }
        }
    }

    private func fontPicker(selection: Binding<FontOption>, target: FontTarget) -> some View {
        Menu {
            ForEach(allFonts) { font in
                Button(font.name) { selection.wrappedValue = font }
            }
            Divider()
            Button("Browse Google Fonts…") { browsingFor = target }
        } label: {
            Text(selection.wrappedValue.name)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fontOption(from family: GoogleFonts.Family) -> FontOption {
        FontOption(
            name: family.family,
            family: "'\(family.family)'",
            fallback: GoogleFonts.genericFallback(family.category),
            googleQuery: GoogleFonts.query(for: family)
        )
    }

    private func importFont() {
        guard let site else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let option = try ThemeManager.importCustomFont(from: url, projectPath: site.localProjectPath)
                importedFonts.append(option)
                headingFont = option
                status = "Imported \(option.name) — assign it and apply."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func applyTheme() {
        guard let site else { return }
        isApplying = true
        status = nil
        let theme = TimTheme(headingFont: headingFont, bodyFont: bodyFont, accentHex: accentColor.hexString)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try ThemeManager.apply(theme, projectPath: site.localProjectPath)
                _ = try AstroProject.build(projectPath: site.localProjectPath)
                DispatchQueue.main.async {
                    isApplying = false
                    status = summary
                    tab.webView.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    isApplying = false
                    status = error.localizedDescription
                }
            }
        }
    }
}

extension Color {
    /// sRGB hex string for CSS.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(
            format: "#%02X%02X%02X",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255))
        )
    }
}

// MARK: - New page from the site's own layout (its master slide)

struct NewPageSheet: View {
    let site: Site?
    @ObservedObject var tab: Tab
    @EnvironmentObject var siteStore: SiteStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var isAstro: Bool {
        site.map { AstroProject.isAstroProject($0.localProjectPath) } ?? false
    }
    /// An empty site's first page is obviously the home page.
    private var isHomePage: Bool {
        guard let site, !isAstro else { return false }
        return SiteWorkspace.needsHomePage(site.localProjectPath)
    }
    private var effectiveSlug: String { isHomePage ? "index" : slug }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Page")
                .font(.title3.bold())

            TextField("Page title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            Text(isAstro
                 ? "Creates src/pages/\(slug.isEmpty ? "…" : slug).astro from your site's layout, builds, and opens it."
                 : (isHomePage
                    ? "This site has no home page yet — this page becomes index.html, publishes, and opens."
                    : "Creates \(effectiveSlug.isEmpty ? "…" : effectiveSlug).html in the site's local folder, publishes it, and opens it."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Every page is a canvas — a plain article is just a full-width text box.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isCreating ? "Creating…" : "Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || effectiveSlug.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var slug: String {
        title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func create() {
        guard var site else { return }
        isCreating = true
        errorMessage = nil
        let pageTitle = title

        // The local mirror is where pages are born.
        if site.localProjectPath.isEmpty {
            site.localProjectPath = SiteWorkspace.defaultFolder(for: site.name.isEmpty ? site.origin : site.name)
            siteStore.upsert(site)
        }
        SiteWorkspace.ensure(site.localProjectPath)
        let workingSite = site
        let pageSlug = effectiveSlug

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rel: String
                if isAstro {
                    rel = try ComponentLibrary.createPage(
                        slug: pageSlug, title: pageTitle, projectPath: workingSite.localProjectPath
                    )
                    _ = try AstroProject.build(projectPath: workingSite.localProjectPath)
                } else {
                    // Plain site: write the page into the mirror, publish it.
                    rel = pageSlug == "index" ? "/index.html" : "/\(pageSlug).html"
                    let html = LocalPage.html(title: pageTitle.isEmpty ? pageSlug : pageTitle)
                    try PageWriter.write(html: html, folder: workingSite.localProjectPath, relativePath: rel)
                    switch workingSite.target {
                    case .sftp:
                        let root = workingSite.remoteRoot.hasSuffix("/")
                            ? String(workingSite.remoteRoot.dropLast()) : workingSite.remoteRoot
                        _ = try SFTP.upload(
                            html: html, to: root + rel,
                            host: workingSite.host, username: workingSite.username, port: workingSite.port
                        )
                    case .cloudflare:
                        _ = try CloudflarePublisher.deploy(
                            folder: workingSite.localProjectPath, projectName: workingSite.cfProjectName
                        )
                    case .githubPages:
                        _ = try GitHubPagesPublisher.publish(
                            repo: workingSite.localProjectPath, message: "New page \(rel) with Tim"
                        )
                    }
                }
                DispatchQueue.main.async {
                    isCreating = false
                    let destination = workingSite.origin + (rel == "/index.html" && !isAstro ? "/" : rel)
                    PageRegistry.record(url: destination, title: pageTitle)
                    tab.navigate(to: destination)
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Publish sheet (target-aware; Astro round trip when the site has a project)

struct PublishSheet: View {
    @ObservedObject var tab: Tab
    let site: Site?
    @Environment(\.dismiss) private var dismiss

    // Manual SFTP fields (used when no site matched, or target == .sftp).
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var remotePath = ""

    @State private var deployAfterBuild = true
    @State private var isPublishing = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private var target: PublishTarget { site?.target ?? .sftp }

    private var isAstro: Bool {
        guard let site else { return false }
        return AstroProject.isAstroProject(site.localProjectPath)
    }

    private var relativePagePath: String {
        guard let site, let url = tab.webView.url else { return "/index.html" }
        return site.relativePagePath(for: url)
    }

    private var title: String {
        if isAstro { return "Publish Site" }
        switch target {
        case .sftp:
            return site.map { "Publish to \($0.name.isEmpty ? $0.origin : $0.name)" } ?? "Publish via SFTP"
        case .cloudflare:
            return "Publish to Cloudflare"
        case .githubPages:
            return "Publish to GitHub Pages"
        }
    }

    private var targetConfigured: Bool {
        guard let site else { return false }
        switch target {
        case .sftp: return !site.host.isEmpty && !site.username.isEmpty && !site.remoteRoot.isEmpty
        case .cloudflare: return !site.cfProjectName.isEmpty
        case .githubPages: return !site.localProjectPath.isEmpty
        }
    }

    private var canPublish: Bool {
        if isAstro { return deployAfterBuild ? targetConfigured : true }
        switch target {
        case .sftp:
            return !host.isEmpty && !username.isEmpty && !remotePath.isEmpty
        case .cloudflare:
            return site?.localProjectPath.isEmpty == false && site?.cfProjectName.isEmpty == false
        case .githubPages:
            return site?.localProjectPath.isEmpty == false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())

            if isAstro {
                astroContent
            } else {
                plainContent
            }

            if let errorMessage {
                ScrollView {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            if let successMessage {
                Text(successMessage)
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isPublishing ? "Publishing…" : "Publish") { publishNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPublishing || !canPublish)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { prefill() }
    }

    @ViewBuilder
    private var astroContent: some View {
        summaryGrid(rows: [
            ("Project", site?.localProjectPath ?? ""),
            ("Pipeline", "apply edits to source → npm run build → deploy dist/"),
            ("Deploy via", target.label + (target == .cloudflare ? " (\(site?.cfProjectName ?? ""))" : ""))
        ])

        Toggle("Deploy after build", isOn: $deployAfterBuild)
            .toggleStyle(.checkbox)

        Text("Astro round trip: text edits are written into the project source (only unambiguous matches — anything unclear is reported, never guessed), the site is rebuilt, and dist/ is deployed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if deployAfterBuild, !targetConfigured {
            Text("The \(target.label) settings for this site are incomplete — edit the site first, or uncheck deploy to just rebuild locally.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var plainContent: some View {
        switch target {
        case .sftp:
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Host")
                    TextField("example.com", text: $host)
                }
                GridRow {
                    Text("User")
                    TextField("deploy", text: $username)
                }
                GridRow {
                    Text("Port")
                    TextField("22", text: $port)
                }
                GridRow {
                    Text("Remote path")
                    TextField("/var/www/site/index.html", text: $remotePath)
                }
            }
            .textFieldStyle(.roundedBorder)

            Text("Authenticates with your SSH keys (~/.ssh). Password login isn’t supported — add your key to the server first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .cloudflare:
            summaryGrid(rows: [
                ("Project", site?.cfProjectName ?? ""),
                ("Site folder", site?.localProjectPath ?? ""),
                ("Page file", relativePagePath)
            ])
            Text("Tim saves this page into the site folder, then deploys it with Wrangler. First time? Run `wrangler login` once in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .githubPages:
            summaryGrid(rows: [
                ("Repository", site?.localProjectPath ?? ""),
                ("Page file", relativePagePath)
            ])
            Text("Tim saves this page into the repository, commits, and pushes to origin. GitHub Pages serves the result.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryGrid(rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Text(row.1.isEmpty ? "—" : row.1)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func prefill() {
        if let site, let url = tab.webView.url {
            host = site.host
            username = site.username
            port = site.port
            remotePath = site.remotePath(for: url)
        } else if let url = tab.webView.url {
            host = url.host() ?? ""
            remotePath = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        }
    }

    private func publishNow() {
        isPublishing = true
        errorMessage = nil
        successMessage = nil

        if isAstro {
            publishAstro()
            return
        }

        guard let url = tab.webView.url else {
            errorMessage = "No page URL."
            isPublishing = false
            return
        }
        tab.currentHTML { html in
            guard let html else {
                errorMessage = "Couldn’t read the page HTML."
                isPublishing = false
                return
            }

            let work: () throws -> String
            switch target {
            case .sftp:
                let (h, u, p, path) = (host, username, port, remotePath)
                let cacheSite = site
                work = {
                    let output = try SFTP.upload(html: html, to: path, host: h, username: u, port: p)
                    // Keep the local mirror in sync with what was published.
                    if let cacheSite, !cacheSite.localProjectPath.isEmpty {
                        try? PageWriter.write(
                            html: html, folder: cacheSite.localProjectPath,
                            relativePath: cacheSite.relativePagePath(for: url)
                        )
                    }
                    return output
                }
            case .cloudflare:
                guard let site else { isPublishing = false; return }
                let rel = site.relativePagePath(for: url)
                work = {
                    try PageWriter.write(html: html, folder: site.localProjectPath, relativePath: rel)
                    return try CloudflarePublisher.deploy(
                        folder: site.localProjectPath,
                        projectName: site.cfProjectName
                    )
                }
            case .githubPages:
                guard let site else { isPublishing = false; return }
                let rel = site.relativePagePath(for: url)
                work = {
                    try PageWriter.write(html: html, folder: site.localProjectPath, relativePath: rel)
                    return try GitHubPagesPublisher.publish(
                        repo: site.localProjectPath,
                        message: "Edit \(rel) with Tim"
                    )
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try work()
                    DispatchQueue.main.async {
                        isPublishing = false
                        successMessage = "Published."
                        if let pageURL = tab.webView.url {
                            PageRegistry.record(url: pageURL.absoluteString, title: tab.title)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                    }
                } catch {
                    DispatchQueue.main.async {
                        isPublishing = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func publishAstro() {
        guard let site else {
            isPublishing = false
            return
        }
        let deploy = deployAfterBuild
        let pageSourcePath: String? = tab.webView.url.flatMap { url in
            ComponentLibrary.pageSource(
                forRelativePagePath: site.relativePagePath(for: url),
                projectPath: site.localProjectPath
            )
        }
        tab.canvasHTML { canvas in
        tab.collectEdits { edits in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var parts: [String] = []
                    if !canvas.isEmpty, let pageSourcePath,
                       (try? AstroProject.replaceCanvas(inPageSource: pageSourcePath, with: canvas)) == true {
                        parts.append("canvas synced to source")
                    }
                    let result = AstroProject.applyEdits(edits, projectPath: site.localProjectPath)
                    _ = try AstroProject.build(projectPath: site.localProjectPath)

                    parts.append("\(result.applied.count) text edit\(result.applied.count == 1 ? "" : "s") written to source")
                    parts.append("site rebuilt")
                    if deploy {
                        let dist = AstroProject.distPath(site.localProjectPath)
                        switch site.target {
                        case .cloudflare:
                            _ = try CloudflarePublisher.deploy(folder: dist, projectName: site.cfProjectName)
                        case .githubPages:
                            _ = try GitHubPagesPublisher.publish(
                                repo: site.localProjectPath,
                                message: "Edit \(site.name) with Tim"
                            )
                        case .sftp:
                            _ = try SFTP.uploadDirectory(
                                local: dist,
                                host: site.host, username: site.username, port: site.port,
                                remoteRoot: site.remoteRoot
                            )
                        }
                        parts.append("deployed via \(site.target.label)")
                    }
                    if !result.skipped.isEmpty {
                        parts.append("needs attention: " + result.skipped.joined(separator: "; "))
                    }
                    let summary = parts.joined(separator: " · ")
                    DispatchQueue.main.async {
                        isPublishing = false
                        successMessage = summary
                        if let pageURL = tab.webView.url {
                            PageRegistry.record(url: pageURL.absoluteString, title: tab.title)
                        }
                        tab.setEditing(false)
                        tab.webView.reload()
                        if result.skipped.isEmpty {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dismiss() }
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        isPublishing = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        }
    }
}

// MARK: - Site editor (connect / edit a site, with per-target verification)

struct SiteEditorSheet: View {
    let site: Site?
    let prefillOrigin: String?

    @EnvironmentObject var siteStore: SiteStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = Site()
    @State private var isVerifying = false
    @State private var verifyResult: String?
    @State private var verifyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(site == nil ? "Connect a Site" : "Edit Site")
                .font(.title3.bold())

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField("My Site", text: $draft.name)
                }
                GridRow {
                    Text("Site URL")
                    TextField("https://example.com", text: $draft.origin)
                }
            }
            .textFieldStyle(.roundedBorder)

            Picker("Publish via", selection: $draft.target) {
                ForEach(PublishTarget.allCases) { target in
                    Text(target.label).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                switch draft.target {
                case .sftp:
                    GridRow {
                        Text("SFTP host")
                        TextField("example.com", text: $draft.host)
                    }
                    GridRow {
                        Text("User")
                        TextField("deploy", text: $draft.username)
                    }
                    GridRow {
                        Text("Port")
                        TextField("22", text: $draft.port)
                    }
                    GridRow {
                        Text("Remote root")
                        TextField("/var/www/html", text: $draft.remoteRoot)
                    }
                    GridRow {
                        Text("Local folder")
                        HStack {
                            TextField("Optional — this site's source folder", text: $draft.localProjectPath)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                case .cloudflare:
                    GridRow {
                        Text("Project name")
                        TextField("my-site", text: $draft.cfProjectName)
                    }
                    GridRow {
                        Text("Site folder")
                        HStack {
                            TextField("The folder Wrangler deploys", text: $draft.localProjectPath)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                case .githubPages:
                    GridRow {
                        Text("Repository")
                        HStack {
                            TextField("Local clone of the Pages repo", text: $draft.localProjectPath)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(targetCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if Robots.state(inMirror: draft.localProjectPath) == .foreign {
                Text("This site has its own robots.txt — Tim won't change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Allow search engines", isOn: $draft.allowSearchEngines)
                    .font(.system(size: 12))
                Toggle("Allow AI crawlers", isOn: $draft.allowAICrawlers)
                    .font(.system(size: 12))
                Text("Written as robots.txt on your site. Honor-system: well-behaved crawlers respect it; it's a request, not a lock.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if AstroProject.isAstroProject(draft.localProjectPath) {
                Label("Astro project detected — Tim will edit source, rebuild, and deploy dist/.", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            if let verifyError {
                Text(verifyError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let verifyResult {
                Text(verifyResult)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Button(isVerifying ? "Verifying…" : "Verify Connection") { verify() }
                    .disabled(isVerifying || !canVerify)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let site {
                draft = site
            } else if let prefillOrigin {
                draft.origin = prefillOrigin
                draft.host = URL(string: prefillOrigin)?.host() ?? ""
                draft.name = draft.host
            }
        }
        .onChange(of: draft.origin) { _, value in
            // Smart defaults: the origin usually knows the name and host.
            guard let host = URL(string: Site.normalizeOrigin(value))?.host() else { return }
            if draft.host.isEmpty { draft.host = host }
            if draft.name.isEmpty { draft.name = host }
        }
    }

    private var targetCaption: String {
        let mirror = "Tim keeps a local copy in ~/Tim/\(draft.name.isEmpty ? "<site>" : draft.name) — created automatically; set a folder only to override."
        switch draft.target {
        case .sftp:
            return "Works with any web host that offers SFTP. Uses your SSH keys — password login isn’t supported. Leave remote root empty for the login folder. " + mirror
        case .cloudflare:
            return "Deploys with Wrangler to Cloudflare’s free global network. One-time setup in Terminal: npm install -g wrangler && wrangler login. " + mirror
        case .githubPages:
            return "Publishing commits your edit and pushes to origin with your existing git credentials. Free hosting via the repo’s Pages settings."
        }
    }

    private var canVerify: Bool {
        switch draft.target {
        case .sftp: return !draft.host.isEmpty && !draft.username.isEmpty
        case .cloudflare: return true
        case .githubPages: return !draft.localProjectPath.isEmpty
        }
    }

    private var canSave: Bool {
        guard !draft.origin.isEmpty else { return false }
        switch draft.target {
        case .sftp: return !draft.host.isEmpty && !draft.username.isEmpty
        case .cloudflare: return !draft.cfProjectName.isEmpty
        case .githubPages: return !draft.localProjectPath.isEmpty
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.localProjectPath = url.path
        }
    }

    private func verify() {
        isVerifying = true
        verifyResult = nil
        verifyError = nil
        let d = draft
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let message: String
                switch d.target {
                case .sftp:
                    _ = try SFTP.verify(host: d.host, username: d.username, port: d.port, remoteRoot: d.remoteRoot)
                    message = "Connected — remote root is reachable."
                case .cloudflare:
                    _ = try CloudflarePublisher.verify()
                    message = "Wrangler is installed and logged in."
                case .githubPages:
                    _ = try GitHubPagesPublisher.verify(repo: d.localProjectPath)
                    message = "Repository and origin are reachable."
                }
                DispatchQueue.main.async {
                    isVerifying = false
                    verifyResult = message
                }
            } catch {
                DispatchQueue.main.async {
                    isVerifying = false
                    verifyError = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        draft.origin = Site.normalizeOrigin(draft.origin)
        if draft.name.isEmpty {
            draft.name = URL(string: draft.origin)?.host() ?? draft.origin
        }
        // The local mirror is a smart default, never a chore: create it
        // automatically unless the user pointed at their own folder.
        if draft.localProjectPath.isEmpty, draft.target != .githubPages {
            draft.localProjectPath = SiteWorkspace.defaultFolder(for: draft.name)
        }
        if !draft.localProjectPath.isEmpty {
            SiteWorkspace.ensure(draft.localProjectPath)
        }
        let isNewSFTPSite = site == nil && draft.target == .sftp && !draft.host.isEmpty
        siteStore.upsert(draft)
        // Crawler permissions become robots.txt in the mirror (and on the
        // server for SFTP sites; other targets carry it on next deploy).
        if !draft.localProjectPath.isEmpty,
           let robots = Robots.write(
               allowSearch: draft.allowSearchEngines,
               allowAI: draft.allowAICrawlers,
               toMirror: draft.localProjectPath
           ),
           draft.target == .sftp, !draft.host.isEmpty {
            let s = draft
            DispatchQueue.global(qos: .utility).async {
                let root = s.remoteRoot.hasSuffix("/") ? String(s.remoteRoot.dropLast()) : s.remoteRoot
                _ = try? SFTP.upload(html: robots, to: root + "/robots.txt", host: s.host, username: s.username, port: s.port)
            }
        }
        // Connecting an existing site pulls it down automatically — the
        // mirror fills itself; no manual download step.
        if isNewSFTPSite {
            let s = draft
            DispatchQueue.global(qos: .utility).async {
                _ = try? SFTP.downloadDirectory(
                    remoteRoot: s.remoteRoot, to: s.localProjectPath,
                    host: s.host, username: s.username, port: s.port
                )
                SiteWorkspace.snapshot(s.localProjectPath, message: "Initial download from \(s.host)")
            }
        }
        dismiss()
    }
}

/// Human time for history: relative today, "Yesterday" after, dates beyond.
func historyLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
    return date.formatted(.dateTime.month(.abbreviated).day()) + ", " + time
}

// MARK: - Version preview: look first, then decide

struct VersionPreviewPane: View {
    let dateLabel: String
    let onRestore: () -> Void
    let onRestoreAsNew: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 12)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 3) {
                Text("Version from")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(dateLabel)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("You're previewing — nothing has changed yet.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button {
                    onRestore()
                } label: {
                    Text("Restore This Version")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onRestoreAsNew()
                } label: {
                    Text("Restore as New Page…")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.regular)

            Divider()
                .padding(.vertical, 2)

            Button("Back to Current") { onCancel() }
                .controlSize(.small)

            Spacer()
        }
        .padding(14)
        .frame(width: 248)
        .background(Color.accentColor.opacity(0.04))
    }
}

// MARK: - Thumbnails (machine-local cache, filled lazily by browsing)

enum ThumbnailStore {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TimThumbnails")

    static func path(for url: String) -> URL {
        let key = Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .prefix(180)
        return directory.appendingPathComponent(String(key) + ".png")
    }

    static func save(_ image: NSImage, for url: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: path(for: url))
    }

    static func image(for url: String) -> NSImage? {
        NSImage(contentsOf: path(for: url))
    }
}

// MARK: - New local page (a single .html canvas file, no site needed)

enum LocalPages {
    static func createAndOpen(in tab: Tab?) {
        guard let tab else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.html"
        panel.title = "New Local Page"
        panel.prompt = "Create"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "html" {
            url.appendPathExtension("html")
        }
        let title = url.deletingPathExtension().lastPathComponent
        do {
            try LocalPage.html(title: title).write(to: url, atomically: true, encoding: .utf8)
            tab.navigate(to: url.absoluteString)
            // Enter edit mode once the new page has loaded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !tab.isEditing { tab.setEditing(true) }
            }
        } catch {
            NSSound.beep()
        }
    }
}


// MARK: - Inspector: style the selection like a design tool, not a CSS editor

let timStyles: [(cls: String, name: String)] = [
    ("tim-style-title", "Title"),
    ("tim-style-heading", "Heading"),
    ("tim-style-subheading", "Subheading"),
    ("tim-style-body", "Body"),
    ("tim-style-caption", "Caption")
]

struct InspectorView: View {
    @ObservedObject var tab: Tab
    var site: Site?
    var allowsTemplates: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            Group {
                if let info = tab.selectionInfo {
                    ScrollView {
                        InspectorControls(tab: tab, site: site, info: info, allowsTemplates: allowsTemplates)
                            .id(info["seq"] as? Int ?? 0)
                    }
                } else {
                    PageOptionsPane(tab: tab)
                }
            }
        }
        .frame(width: 248)
        .background(Color.primary.opacity(0.025))
    }

    /// The trail starts at Page — always one click back to page settings —
    /// and continues through the selection's enclosing elements, each
    /// clickable. The DOM as a path, not a panel.
    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumb("Page", isCurrent: tab.selectionInfo == nil) {
                    tab.clearSelection()
                }
                if let path = tab.selectionInfo?["path"] as? [String] {
                    ForEach(Array(path.enumerated()), id: \.offset) { item in
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        crumb(item.element.capitalized, isCurrent: item.offset == path.count - 1) {
                            tab.selectAncestor(item.offset)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .background(Color.primary.opacity(0.02))
    }

    private func crumb(_ label: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .padding(.vertical, 2)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "Current selection" : (label == "Page" ? "Page settings" : "Select the enclosing \(label)"))
    }
}

struct InspectorControls: View {
    @ObservedObject var tab: Tab
    var site: Site?
    let info: [String: Any]
    var allowsTemplates: Bool = false

    @State private var styleClass: String
    @State private var fontFamilyName: String
    @State private var fontSize: Double
    @State private var weightIndex: Int
    @State private var lineHeight: Double
    @State private var letterSpacing: Double
    @State private var pinnedFonts: [String] = []
    @State private var isItalic: Bool = false
    @State private var isUnderlined: Bool = false
    @State private var isStruck: Bool = false
    @State private var capsMode: String = "none"
    @State private var textColor: Color
    @State private var fillColor: Color
    @State private var radius: Double
    @State private var padding: Double
    @State private var opacity: Double
    @State private var hasShadow: Bool
    @State private var shadowColor: Color = .black
    @State private var textShadowOn: Bool
    @State private var textShadowColor: Color = .black
    @State private var showFontPicker = false

    private let weights = [400, 500, 600, 700]

    init(tab: Tab, site: Site? = nil, info: [String: Any], allowsTemplates: Bool = false) {
        self.tab = tab
        self.site = site
        self.info = info
        self.allowsTemplates = allowsTemplates
        let cls = info["timStyle"] as? String ?? ""
        _styleClass = State(initialValue: cls.isEmpty ? "tim-style-body" : cls)
        let family = info["fontFamily"] as? String ?? ""
        _fontFamilyName = State(initialValue: (family.hasPrefix("-apple-") || family.hasPrefix(".")) ? "" : family)
        _fontSize = State(initialValue: info["fontSize"] as? Double ?? 16)
        let weight = info["fontWeight"] as? Int ?? 400
        _weightIndex = State(initialValue: [400, 500, 600, 700].lastIndex(where: { $0 <= weight }) ?? 0)
        _lineHeight = State(initialValue: min(2.2, max(0.8, info["lineHeight"] as? Double ?? 1.4)))
        _letterSpacing = State(initialValue: min(8, max(-2, info["letterSpacing"] as? Double ?? 0)))
        _textColor = State(initialValue: Color(cssColor: info["color"] as? String ?? "", fallback: .primary))
        _fillColor = State(initialValue: Color(cssColor: info["fill"] as? String ?? "", fallback: .clear))
        _radius = State(initialValue: info["radius"] as? Double ?? 0)
        _padding = State(initialValue: info["padding"] as? Double ?? 0)
        _opacity = State(initialValue: info["opacity"] as? Double ?? 1)
        _hasShadow = State(initialValue: (info["hasShadow"] as? Int) == 1)
        _textShadowOn = State(initialValue: (info["hasTextShadow"] as? Int) == 1)
        _isItalic = State(initialValue: (info["italic"] as? Int) == 1)
        _isUnderlined = State(initialValue: (info["underline"] as? Int) == 1)
        _isStruck = State(initialValue: (info["strike"] as? Int) == 1)
        _capsMode = State(initialValue: info["caps"] as? String ?? "none")
    }

    private var isText: Bool {
        (info["isText"] as? Int) == 1
            || ["h1", "h2", "h3", "h4", "h5", "h6", "p", "blockquote", "li"].contains(info["tag"] as? String ?? "")
    }
    private var hasOverrides: Bool { (info["overrides"] as? Int) == 1 }
    private var selectionCount: Int { info["selCount"] as? Int ?? 1 }
    private var customStyles: [String] {
        let fixed = Set(timStyles.map(\.cls))
        return ((info["customStyles"] as? [String]) ?? []).filter { !fixed.contains($0) }.sorted()
    }
    private var styleName: String {
        timStyles.first { $0.cls == styleClass }?.name ?? styleDisplayName(styleClass)
    }
    private func styleDisplayName(_ cls: String) -> String {
        cls.replacingOccurrences(of: "tim-style-", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isText {
                styleCard
                typographyCard
            } else {
                Text((info["tag"] as? String ?? "object").capitalized)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 2)
            }
            appearanceCard
            if allowsTemplates, isCanvasObject {
                templateCard
            }
        }
        .padding(10)
        .onAppear {
            // Warm the pinned list so the font picker opens populated.
            tab.pageFonts { fonts in
                pinnedFonts = SiteFonts.used(site: site, pageFonts: fonts)
            }
        }
    }

    private var isCanvasObject: Bool {
        (info["path"] as? [String])?.contains("Canvas") == true
    }

    private var onEveryPage: Bool {
        (info["templateComponent"] as? String ?? "").hasPrefix("tpl-")
    }

    private var templateCard: some View {
        card {
            if (info["templateComponent"] as? String) == "tpl-nav" {
                Button("Edit Navigation…") {
                    NotificationCenter.default.post(name: .timEditNav, object: nil)
                }
                .font(.system(size: 11))
                .help("Choose which pages appear, add links, and reorder.")
            }
            Toggle("On every page", isOn: Binding(
                get: { onEveryPage },
                set: { on in
                    tab.setSelectionOnEveryPage(on, name: "tpl-" + String(UUID().uuidString.prefix(6)).lowercased())
                }
            ))
            .font(.system(size: 12))
            Text(onEveryPage
                 ? "Part of this page's template — it appears on every page, and edits here update it everywhere on Done."
                 : "Adds this object to the template: every page gets it, in this spot, on your next Done.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Style (the Pages/Keynote contract)

    private var styleCard: some View {
        card {
            if selectionCount > 1 {
                Text("\(selectionCount) objects — edits apply to all")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 6) {
                rowLabel("Style")
                Picker("", selection: $styleClass) {
                    ForEach(timStyles, id: \.cls) { style in
                        Text(style.name).tag(style.cls)
                    }
                    if !customStyles.isEmpty {
                        Divider()
                        ForEach(customStyles, id: \.self) { cls in
                            Text(styleDisplayName(cls)).tag(cls)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: styleClass) { _, cls in tab.applyTextStyle(cls) }
                Menu {
                    Button("New Style from Selection…") { promptNewStyle() }
                    if customStyles.contains(styleClass) {
                        Button("Rename \(styleName)…") { promptRenameStyle() }
                        Button("Delete \(styleName)", role: .destructive) {
                            tab.deleteStyle(className: styleClass)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 11))
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if hasOverrides {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        tab.updateStyleFromSelection()
                    } label: {
                        Text("Update \(styleName) Style")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Every \(styleName) block on this page takes this look.")

                    Button {
                        tab.revertSelectionToStyle()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .controlSize(.small)
                    .help("Back to the \(styleName) style")
                }
            }
        }
    }

    private func styleSlug(_ name: String) -> String {
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "style" : slug
    }

    private func askForName(title: String, message: String, prefill: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        field.stringValue = prefill
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func promptNewStyle() {
        guard let name = askForName(
            title: "New Style",
            message: "The selection's look becomes a named style you can apply anywhere on this page.",
            prefill: ""
        ) else { return }
        let cls = "tim-style-" + styleSlug(name)
        tab.createStyleFromSelection(className: cls)
        styleClass = cls
    }

    private func promptRenameStyle() {
        guard let name = askForName(
            title: "Rename Style",
            message: "Every block using it follows the new name.",
            prefill: styleDisplayName(styleClass)
        ) else { return }
        let newClass = "tim-style-" + styleSlug(name)
        tab.renameStyle(from: styleClass, to: newClass)
        styleClass = newClass
    }

    // MARK: Typography

    private var typographyCard: some View {
        card("Typography") {
            Button {
                tab.pageFonts { fonts in
                    pinnedFonts = SiteFonts.used(site: site, pageFonts: fonts)
                    showFontPicker = true
                }
            } label: {
                HStack {
                    Text(fontFamilyName.isEmpty ? "System" : fontFamilyName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFontPicker, arrowEdge: .leading) {
                FontPickerView(pinned: pinnedFonts, current: fontFamilyName) { family in
                    fontFamilyName = family.family
                    tab.ensurePageFont(family: family.family, cssURL: GoogleFonts.cssURL(for: family))
                    tab.setSelectionStyle("fontFamily", "'\(family.family)', \(GoogleFonts.genericFallback(family.category))")
                    showFontPicker = false
                }
            }

            sliderRow("Size", $fontSize, 10...96, 1, "\(Int(fontSize))")
                .onChange(of: fontSize) { _, v in tab.setSelectionStyle("fontSize", "\(Int(v))px") }

            HStack(spacing: 8) {
                rowLabel("Weight")
                Picker("", selection: $weightIndex) {
                    Text("Reg").tag(0)
                    Text("Med").tag(1)
                    Text("Semi").tag(2)
                    Text("Bold").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .onChange(of: weightIndex) { _, i in tab.setSelectionStyle("fontWeight", "\(weights[i])") }
            }

            HStack(spacing: 8) {
                rowLabel("Align")
                HStack(spacing: 3) {
                    ForEach(["left", "center", "right"], id: \.self) { alignment in
                        Button {
                            tab.setSelectionStyle("textAlign", alignment)
                        } label: {
                            Image(systemName: "text.align\(alignment)")
                                .font(.system(size: 10))
                                .frame(width: 26, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                rowLabel("Emphasis")
                HStack(spacing: 3) {
                    emphasisButton("italic", on: $isItalic) {
                        tab.setSelectionStyle("fontStyle", isItalic ? "italic" : "normal")
                    }
                    emphasisButton("underline", on: $isUnderlined) { applyDecoration() }
                    emphasisButton("strikethrough", on: $isStruck) { applyDecoration() }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                rowLabel("Caps")
                Picker("", selection: $capsMode) {
                    Text("None").tag("none")
                    Text("ALL").tag("upper")
                    Text("Small").tag("small")
                    Text("Title").tag("title")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .onChange(of: capsMode) { _, mode in
                    tab.setSelectionStyle("textTransform", mode == "upper" ? "uppercase" : (mode == "title" ? "capitalize" : "none"))
                    tab.setSelectionStyle("fontVariant", mode == "small" ? "small-caps" : "normal")
                }
            }

            sliderRow("Leading", $lineHeight, 0.8...2.2, 0.05, String(format: "%.2f", lineHeight))
                .onChange(of: lineHeight) { _, v in tab.setSelectionStyle("lineHeight", String(format: "%.2f", v)) }

            sliderRow("Tracking", $letterSpacing, -2...8, 0.5, String(format: "%.1f", letterSpacing))
                .onChange(of: letterSpacing) { _, v in
                    tab.setSelectionStyle("letterSpacing", v == 0 ? "normal" : String(format: "%.1fpx", v))
                }

            HStack(spacing: 8) {
                rowLabel("Color")
                ColorPicker("", selection: $textColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: textColor) { _, c in tab.setSelectionStyle("color", c.hexString) }
                Spacer()
            }
            HStack(spacing: 8) {
                rowLabel("Shadow")
                Toggle("", isOn: $textShadowOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: textShadowOn) { _, _ in applyTextShadow() }
                if textShadowOn {
                    ColorPicker("", selection: $textShadowColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: textShadowColor) { _, _ in applyTextShadow() }
                }
                Spacer()
            }
        }
    }

    private func emphasisButton(_ symbol: String, on: Binding<Bool>, apply: @escaping () -> Void) -> some View {
        Button {
            on.wrappedValue.toggle()
            apply()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 26, height: 16)
        }
        .buttonStyle(.bordered)
        .tint(on.wrappedValue ? Color.accentColor : nil)
        .controlSize(.mini)
    }

    private func applyDecoration() {
        var parts: [String] = []
        if isUnderlined { parts.append("underline") }
        if isStruck { parts.append("line-through") }
        tab.setSelectionStyle("textDecoration", parts.isEmpty ? "none" : parts.joined(separator: " "))
    }

    private func applyTextShadow() {
        tab.setSelectionStyle(
            "textShadow",
            textShadowOn ? "0 1px 6px \(textShadowColor.cssRGBA(0.45))" : ""
        )
    }

    private func applyBoxShadow() {
        tab.setSelectionStyle(
            "boxShadow",
            hasShadow ? "0 8px 24px \(shadowColor.cssRGBA(0.30))" : ""
        )
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        card("Appearance") {
            HStack(spacing: 8) {
                rowLabel("Fill")
                ColorPicker("", selection: $fillColor)
                    .labelsHidden()
                    .onChange(of: fillColor) { _, c in tab.setSelectionStyle("background", c.hexString) }
                Button("None") { tab.setSelectionStyle("background", "") }
                    .controlSize(.mini)
                Spacer()
            }
            sliderRow("Corner", $radius, 0...40, 1, "\(Int(radius))")
                .onChange(of: radius) { _, v in tab.setSelectionStyle("borderRadius", "\(Int(v))px") }
            sliderRow("Padding", $padding, 0...48, 2, "\(Int(padding))")
                .onChange(of: padding) { _, v in tab.setSelectionStyle("padding", "\(Int(v))px") }
            sliderRow("Opacity", $opacity, 0.2...1, 0.05, "\(Int(opacity * 100))")
                .onChange(of: opacity) { _, v in tab.setSelectionStyle("opacity", String(format: "%.2f", v)) }
            HStack(spacing: 8) {
                rowLabel("Shadow")
                Toggle("", isOn: $hasShadow)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: hasShadow) { _, _ in applyBoxShadow() }
                if hasShadow {
                    ColorPicker("", selection: $shadowColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: shadowColor) { _, _ in applyBoxShadow() }
                }
                Spacer()
            }
        }
    }

    // MARK: pieces

    private func card(_ title: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.7)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 58, alignment: .leading)
    }

    private func sliderRow(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ display: String) -> some View {
        HStack(spacing: 8) {
            rowLabel(name)
            Slider(value: value, in: range, step: step)
                .controlSize(.mini)
            Text(display)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Page pane: no selection = page options (edits the page's template)

struct PageOptionsPane: View {
    @ObservedObject var tab: Tab

    @State private var info: [String: Any]?
    @State private var loadCount = 0

    var body: some View {
        ScrollView {
            if let info {
                PageOptionsControls(tab: tab, info: info, reload: reload)
                    .id(loadCount)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 48)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        tab.pageInfo { loaded in
            info = loaded
            loadCount += 1
        }
    }
}

struct PageOptionsControls: View {
    @ObservedObject var tab: Tab
    let info: [String: Any]
    let reload: () -> Void
    @EnvironmentObject var siteStore: SiteStore

    @State private var template: String
    @State private var title: String
    @State private var bg: Color
    @State private var fg: Color
    @State private var link: Color
    @State private var contentW: Double
    @State private var marginX: Double
    @State private var padY: Double
    @State private var baseSize: Double
    @State private var descriptionText: String
    @State private var ogImage: String
    @State private var favicon: String
    @State private var touchIcon: String
    @State private var showIconMaker = false
    @State private var hideFromSearch: Bool
    @State private var makerRecipe: IconRecipe?
    @State private var makerImage: NSImage?
    @State private var editingSiteSettings: Site?
    @State private var pinnedFonts: [String] = []

    init(tab: Tab, info: [String: Any], reload: @escaping () -> Void) {
        self.tab = tab
        self.info = info
        self.reload = reload
        _template = State(initialValue: info["template"] as? String ?? "default")
        _title = State(initialValue: info["title"] as? String ?? "")
        _bg = State(initialValue: Color(cssColor: info["bg"] as? String ?? "", fallback: .white))
        _fg = State(initialValue: Color(cssColor: info["fg"] as? String ?? "", fallback: .black))
        _link = State(initialValue: Color(cssColor: info["link"] as? String ?? "", fallback: .blue))
        _contentW = State(initialValue: min(1680, max(560, info["contentW"] as? Double ?? 1320)))
        _marginX = State(initialValue: min(120, max(0, info["marginX"] as? Double ?? 32)))
        _padY = State(initialValue: min(200, max(0, info["padY"] as? Double ?? 48)))
        _baseSize = State(initialValue: min(22, max(12, info["baseSize"] as? Double ?? 16)))
        _descriptionText = State(initialValue: info["description"] as? String ?? "")
        _ogImage = State(initialValue: info["ogImage"] as? String ?? "")
        _favicon = State(initialValue: info["favicon"] as? String ?? "")
        _touchIcon = State(initialValue: info["touchIcon"] as? String ?? "")
        _hideFromSearch = State(initialValue: (info["robotsMeta"] as? String ?? "").contains("noindex"))
    }

    private var currentSite: Site? { siteStore.match(tab.webView.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card {
                HStack(spacing: 8) {
                    rowLabel("Template")
                    Picker("", selection: $template) {
                        Text("Default").tag("default")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                }
                Text("Page options edit this template — every page using it follows. Templates live in your theme, next to styles.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            card("Page") {
                HStack(spacing: 8) {
                    rowLabel("Title")
                    TextField("Untitled", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                        .onChange(of: title) { _, value in tab.setPageOption("title", value) }
                }
            }

            card("Colors") {
                HStack(spacing: 8) {
                    rowLabel("Background")
                    ColorPicker("", selection: $bg, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: bg) { _, c in tab.setPageOption("bg", c.hexString) }
                    Spacer()
                }
                HStack(spacing: 8) {
                    rowLabel("Text")
                    ColorPicker("", selection: $fg, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: fg) { _, c in tab.setPageOption("fg", c.hexString) }
                    Spacer()
                }
                HStack(spacing: 8) {
                    rowLabel("Links")
                    ColorPicker("", selection: $link, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: link) { _, c in tab.setPageOption("link", c.hexString) }
                    Spacer()
                }
                Button("Reset Colors") {
                    tab.setPageOption("bg", "")
                    tab.setPageOption("fg", "")
                    tab.setPageOption("link", "")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { reload() }
                }
                .controlSize(.mini)
            }

            card("Layout") {
                sliderRow("Width", $contentW, 560...1680, 20, "\(Int(contentW))")
                    .onChange(of: contentW) { _, v in tab.setPageOption("contentW", "\(Int(v))") }
                sliderRow("Margins", $marginX, 0...120, 4, "\(Int(marginX))")
                    .onChange(of: marginX) { _, v in tab.setPageOption("marginX", "\(Int(v))") }
                sliderRow("Vertical", $padY, 0...200, 8, "\(Int(padY))")
                    .onChange(of: padY) { _, v in tab.setPageOption("padY", "\(Int(v))") }
                sliderRow("Base Size", $baseSize, 12...22, 1, "\(Int(baseSize))")
                    .onChange(of: baseSize) { _, v in tab.setPageOption("baseSize", "\(Int(v))") }
            }

            card("Sharing & Search") {
                Text("Description")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("What this page is about — search results and link previews show this.", text: $descriptionText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...4)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .onChange(of: descriptionText) { _, value in tab.setPageMeta("description", value) }

                // Social image — previewed as the share card it becomes.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        rowLabel("Social Image")
                        Button("Thumbnail") { useThumbnailAsSocial() }
                            .controlSize(.mini)
                            .help("Snapshot this page as its share card (1200×630).")
                        Button("Choose…") { chooseMetaImage(kind: "ogImage") }
                            .controlSize(.mini)
                        if !ogImage.isEmpty {
                            Button("Clear") { tab.setPageMeta("ogImage", ""); ogImage = "" }
                                .controlSize(.mini)
                        }
                        Spacer()
                    }
                    if ogImage.isEmpty {
                        Text("Auto-generates from the page on each save — Choose… to use your own.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            imagePreview(ogImage)
                                .frame(maxWidth: .infinity)
                                .frame(height: 104)
                                .clipped()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title.isEmpty ? "Untitled" : title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                                if !descriptionText.isEmpty {
                                    Text(descriptionText)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(shareDomain)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        Text("How links to this page unfurl in Messages and social apps.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                // App icon and favicon — shown as they'll appear.
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        rowLabel("App Icon")
                        Group {
                            if touchIcon.isEmpty {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                                    .overlay(
                                        Image(systemName: "app.dashed")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.tertiary)
                                    )
                            } else {
                                imagePreview(touchIcon)
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        HStack(spacing: 4) {
                            Button("Make…") { prepareIconMaker() }.controlSize(.mini)
                            Button("Choose…") { chooseMetaImage(kind: "touchIcon") }.controlSize(.mini)
                        }
                        if !touchIcon.isEmpty {
                            Button("Clear") { tab.setPageMeta("touchIcon", ""); touchIcon = "" }
                                .controlSize(.mini)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        rowLabel("Favicon")
                        HStack(spacing: 5) {
                            Group {
                                if favicon.isEmpty {
                                    Image(systemName: "globe")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    imagePreview(favicon)
                                        .frame(width: 14, height: 14)
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                }
                            }
                            Text(title.isEmpty ? "Untitled" : title)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        HStack(spacing: 4) {
                            Button("Choose…") { chooseMetaImage(kind: "favicon") }.controlSize(.mini)
                            if !favicon.isEmpty {
                                Button("Clear") { tab.setPageMeta("favicon", ""); favicon = "" }
                                    .controlSize(.mini)
                            }
                        }
                    }
                    Spacer()
                }
                Text("Dock and Home Screen use the app icon; tabs and bookmarks use the favicon.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Hide this page from search engines", isOn: $hideFromSearch)
                    .font(.system(size: 11))
                    .onChange(of: hideFromSearch) { _, on in
                        tab.setPageMeta("robots", on ? "noindex, nofollow" : "")
                    }
                    .help("Adds a noindex meta tag — search engines skip this page. Site-wide crawler permissions live in the site's settings.")
            }
            .sheet(isPresented: $showIconMaker) {
                IconMakerSheet(existing: makerRecipe, existingImage: makerImage, pinned: pinnedFonts) { recipe, url in
                    stageAndSet(fileURL: url, kinds: ["touchIcon", "favicon"])
                    persistIconRecipe(recipe)
                }
            }

            if let s = currentSite {
                VStack(alignment: .leading, spacing: 9) {
                    Text("SITE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.7)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: s.target.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(s.name.isEmpty ? s.origin : s.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Button("Site Settings…") { editingSiteSettings = s }
                            .controlSize(.small)
                    }
                    Text("Connection, crawler permissions, and everything else that applies to every page on this site.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .sheet(item: $editingSiteSettings) { site in
                    SiteEditorSheet(site: site, prefillOrigin: nil)
                }
            }

            Text("Select an object to style it — click empty space to come back to the page.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .padding(10)
    }

    /// Editing an icon means reopening its recipe, not starting over —
    /// recipes live in the site manifest (tim.json) so they follow the
    /// site to any Mac; local pages keep theirs in defaults.
    private func prepareIconMaker() {
        if let s = currentSite, let url = tab.webView.url {
            SiteManifest.refreshIfStale(site: s)
            let rel = s.relativePagePath(for: url)
            makerRecipe = SiteManifest.load(fromMirror: s.localProjectPath).iconRecipes[rel]
        } else if let url = tab.webView.url,
                  let data = UserDefaults.standard.data(forKey: "tim.iconRecipe." + url.absoluteString),
                  let recipe = try? JSONDecoder().decode(IconRecipe.self, from: data) {
            makerRecipe = recipe
        } else {
            makerRecipe = nil
        }
        if makerRecipe == nil, !touchIcon.isEmpty, let image = localPreviewImage(for: touchIcon) {
            // Icon predates recipes: start from what's there, not a blank.
            var legacy = IconRecipe()
            legacy.imageBased = true
            makerRecipe = legacy
            makerImage = image
        } else {
            makerImage = (makerRecipe?.imageBased == true) ? localPreviewImage(for: touchIcon) : nil
        }
        let site = currentSite
        tab.pageFonts { fonts in
            pinnedFonts = SiteFonts.used(site: site, pageFonts: fonts)
            showIconMaker = true
        }
    }

    private func persistIconRecipe(_ recipe: IconRecipe) {
        if let s = currentSite, let url = tab.webView.url, !s.localProjectPath.isEmpty {
            let rel = s.relativePagePath(for: url)
            var manifest = SiteManifest.load(fromMirror: s.localProjectPath)
            manifest.iconRecipes[rel] = recipe
            manifest.iconRecipesUpdated = Date()
            let json = manifest.save(toMirror: s.localProjectPath)
            if s.target == .sftp, let json {
                let site = s
                DispatchQueue.global(qos: .utility).async {
                    let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                    _ = try? SFTP.upload(html: json, to: root + "/tim.json", host: site.host, username: site.username, port: site.port)
                }
            }
        } else if let url = tab.webView.url, let data = try? JSONEncoder().encode(recipe) {
            UserDefaults.standard.set(data, forKey: "tim.iconRecipe." + url.absoluteString)
        }
    }

    private var shareDomain: String {
        if let host = tab.webView.url?.host() { return host }
        return currentSite.flatMap { URL(string: $0.origin)?.host() } ?? "your site"
    }

    /// Resolves a metadata image to something viewable: the mirror copy
    /// first (fast, offline), then the live URL.
    private func localPreviewImage(for value: String) -> NSImage? {
        guard !value.isEmpty else { return nil }
        var rel = value
        if let s = currentSite, rel.hasPrefix(s.origin) { rel = String(rel.dropFirst(s.origin.count)) }
        while rel.hasPrefix("/") { rel.removeFirst() }
        if let s = currentSite, !s.localProjectPath.isEmpty {
            for base in [s.localProjectPath, s.localProjectPath + "/public", s.localProjectPath + "/dist"] {
                if let image = NSImage(contentsOfFile: base + "/" + rel) { return image }
            }
        }
        if let pageURL = tab.webView.url, pageURL.isFileURL {
            let path = pageURL.deletingLastPathComponent().appendingPathComponent(rel).path
            if let image = NSImage(contentsOfFile: path) { return image }
        }
        return nil
    }

    @ViewBuilder
    private func imagePreview(_ value: String) -> some View {
        if let image = localPreviewImage(for: value) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let url = URL(string: value), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.primary.opacity(0.06))
                }
            }
        } else {
            Rectangle().fill(Color.primary.opacity(0.06))
        }
    }

    private func metaFileRow(label: String, value: String, hint: String, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                rowLabel(label)
                Button("Choose…") { chooseMetaImage(kind: kind) }
                    .controlSize(.mini)
                if !value.isEmpty {
                    Button("Clear") {
                        tab.setPageMeta(kind, "")
                        if kind == "ogImage" { ogImage = "" } else { favicon = "" }
                    }
                    .controlSize(.mini)
                }
                Spacer()
            }
            Text(value.isEmpty ? hint : value)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func chooseMetaImage(kind: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        stageAndSet(fileURL: fileURL, kinds: [kind])
    }

    /// Stages an image like any media (mirror + upload), then points the
    /// metadata at it — absolute URL for the social image so link
    /// scrapers can fetch it.
    private func stageAndSet(fileURL: URL, kinds: [String]) {
        var resolvedSite = currentSite
        if var s = resolvedSite {
            if s.localProjectPath.isEmpty {
                s.localProjectPath = SiteWorkspace.defaultFolder(for: s.name.isEmpty ? s.origin : s.name)
                siteStore.upsert(s)
            }
            SiteWorkspace.ensure(s.localProjectPath)
            resolvedSite = s
        }
        let pageURL = tab.webView.url
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let staged = try EditingToolbar.stage(fileURL: fileURL, site: resolvedSite, pageURL: pageURL)
                DispatchQueue.main.async {
                    for kind in kinds {
                        let value: String
                        if kind == "ogImage", let s = resolvedSite, s.origin.hasPrefix("http") {
                            value = s.origin + "/" + staged
                        } else {
                            value = staged
                        }
                        tab.setPageMeta(kind, value)
                        switch kind {
                        case "ogImage": ogImage = value
                        case "favicon": favicon = value
                        case "touchIcon": touchIcon = value
                        default: break
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Add Image"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// The automated share card: this page, snapshotted at 1200×630.
    private func useThumbnailAsSocial() {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1200
        tab.webView.takeSnapshot(with: config) { image, _ in
            guard let image, image.size.width > 0 else { return }
            let card = NSImage(size: NSSize(width: 1200, height: 630))
            card.lockFocus()
            let scaledHeight = image.size.height * (1200 / image.size.width)
            image.draw(in: NSRect(x: 0, y: 630 - scaledHeight, width: 1200, height: scaledHeight))
            card.unlockFocus()
            guard let tiff = card.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("social-card.png")
            try? png.write(to: url)
            stageAndSet(fileURL: url, kinds: ["ogImage"])
        }
    }

    private func card(_ title: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.7)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 66, alignment: .leading)
    }

    private func sliderRow(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ display: String) -> some View {
        HStack(spacing: 8) {
            rowLabel(name)
            Slider(value: value, in: range, step: step)
                .controlSize(.mini)
            Text(display)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

extension Color {
    /// Parses CSS "rgb(…)" / "rgba(…)" / "#hex" strings from computed styles.
    init(cssColor: String, fallback: Color) {
        let value = cssColor.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("rgb") {
            let numbers = value
                .split(whereSeparator: { !"0123456789.".contains($0) })
                .compactMap { Double($0) }
            if numbers.count >= 3 {
                self = Color(.sRGB, red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, opacity: 1)
                return
            }
        }
        if value.hasPrefix("#"), value.count >= 7,
           let r = Int(value.dropFirst().prefix(2), radix: 16),
           let g = Int(value.dropFirst(3).prefix(2), radix: 16),
           let b = Int(value.dropFirst(5).prefix(2), radix: 16) {
            self = Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
            return
        }
        self = fallback
    }
}


// MARK: - Navigation object: the site's live pages, deselectable

struct NavBuilderSheet: View {
    let site: Site
    @ObservedObject var tab: Tab
    @Environment(\.dismiss) private var dismiss

    private struct NavItem: Identifiable, Equatable {
        let id = UUID()
        var label: String
        var href: String
        var enabled: Bool
        var isPage: Bool
        var openTag: String?  // the original <a …> tag — styling survives
    }

    @State private var items: [NavItem] = []
    @State private var navOpenTag: String?
    @State private var hasMaster = false
    @State private var newLabel = ""
    @State private var newURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Navigation")
                .font(.title3.bold())
            Text("A menu that lives on every page. Toggle pages on and off, add links to anything — even an email address — and drag to reorder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach($items) { $item in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $item.enabled)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                                .font(.system(size: 12))
                            if !item.isPage {
                                Text(item.href)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        if !item.isPage {
                            Button {
                                items.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this link")
                        }
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }
                }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)
            .frame(height: 220)

            HStack(spacing: 6) {
                TextField("Label", text: $newLabel)
                    .frame(width: 90)
                TextField("URL or email address", text: $newURL)
                Button("Add") { addCustomLink() }
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty
                              || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(hasMaster ? "Update" : "Insert") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!items.contains(where: \.enabled))
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear(perform: load)
    }

    /// Seeds the sheet from the nav on the page itself (unsaved styling
    /// and edits included), falling back to the master on disk — links
    /// come back in order, styling intact — and every site page not yet
    /// in the nav joins the list, toggled off.
    private func load() {
        tab.componentHTML(name: "tpl-nav") { live in
            let source = live ?? PageComponents.html(named: "tpl-nav", in: site.localProjectPath)
            DispatchQueue.main.async { seed(from: source) }
        }
    }

    private func seed(from master: String?) {
        let hadMaster = master != nil
        hasMaster = hadMaster
        var list: [NavItem] = []
        if let master {
            navOpenTag = firstMatch(in: master, pattern: "<nav[^>]*>")
            for anchor in allMatches(in: master, pattern: "<a\\b[^>]*>[\\s\\S]*?</a>") {
                let openTag = firstMatch(in: anchor, pattern: "<a\\b[^>]*>") ?? "<a>"
                let href = firstMatch(in: openTag, pattern: "href=\"([^\"]*)\"", group: 1) ?? ""
                let label = anchor
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                list.append(NavItem(label: label.isEmpty ? href : label, href: href,
                                    enabled: true, isPage: false, openTag: openTag))
            }
        }
        let pages = LinkSources.pages(for: site)
        for index in list.indices {
            list[index].isPage = pages.contains { site.origin + $0.href == list[index].href }
        }
        for page in pages {
            let full = site.origin + page.href
            guard !list.contains(where: { $0.href == full }) else { continue }
            list.append(NavItem(label: page.label, href: full,
                                enabled: !hadMaster, isPage: true, openTag: nil))
        }
        items = list
    }

    private func addCustomLink() {
        var href = newURL.trimmingCharacters(in: .whitespaces)
        if !href.contains("://"), !href.hasPrefix("mailto:"), !href.hasPrefix("tel:"),
           !href.hasPrefix("#"), !href.hasPrefix("/") {
            href = href.contains("@") && !href.contains("/") ? "mailto:" + href : "https://" + href
        }
        items.append(NavItem(label: newLabel.trimmingCharacters(in: .whitespaces),
                             href: href, enabled: true, isPage: false, openTag: nil))
        newLabel = ""
        newURL = ""
    }

    /// Rebuilds the nav from the list, saves the master, and updates the
    /// live region in place (or inserts one when the page has none). Done
    /// stamps it across every page as usual.
    private func apply() {
        let links = items.filter(\.enabled).map { item -> String in
            var tag = item.openTag ?? "<a style=\"text-decoration:none;color:inherit;\">"
            tag = tag.replacingOccurrences(of: "\\s*href=\"[^\"]*\"", with: "", options: .regularExpression)
            tag = tag.replacingOccurrences(of: "<a", with: "<a href=\"\(item.href)\"")
            return tag + escapeHTML(item.label) + "</a>"
        }.joined(separator: "\n  ")
        let openTag = navOpenTag
            ?? "<nav class=\"tim-object tim-nav tim-text\" style=\"display:flex; gap:20px; flex-wrap:wrap; align-items:center; font-weight:500;\">"
        let nav = openTag + "\n  " + links + "\n</nav>"
        try? PageComponents.save(name: "tpl-nav", html: nav, in: site.localProjectPath)
        tab.updateComponent(name: "tpl-nav", html: nav) { found in
            if !found {
                tab.insertObject(html: PageComponents.stamped(name: "tpl-nav", content: nav),
                                 colSpan: 24, rowSpan: 2)
            }
        }
        dismiss()
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func firstMatch(in text: String, pattern: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    private func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Icon maker: an editable recipe — colors, gradients, type

struct IconMakerSheet: View {
    let existing: IconRecipe?
    let existingImage: NSImage?
    var pinned: [String] = []
    let onSave: (IconRecipe, URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var fontFamily: String
    @State private var textColor: Color
    @State private var backgroundColor: Color
    @State private var useGradient: Bool
    @State private var backgroundEnd: Color
    @State private var picked: NSImage?
    @State private var fontReady = true
    @State private var showFontPicker = false

    private let quickColors: [NSColor] = [
        NSColor(red: 0.996, green: 0.929, blue: 0.0, alpha: 1),
        .systemBlue, .systemPurple, .systemGreen,
        .systemOrange, .systemPink, .black, .white
    ]

    init(existing: IconRecipe?, existingImage: NSImage?, pinned: [String] = [], onSave: @escaping (IconRecipe, URL) -> Void) {
        self.existing = existing
        self.existingImage = existingImage
        self.pinned = pinned
        self.onSave = onSave
        let recipe = existing ?? IconRecipe()
        _text = State(initialValue: recipe.text)
        _fontFamily = State(initialValue: recipe.fontFamily)
        _textColor = State(initialValue: recipe.textColorHex.isEmpty
            ? .white
            : Color(cssColor: recipe.textColorHex, fallback: .white))
        _backgroundColor = State(initialValue: Color(cssColor: recipe.backgroundHex, fallback: Color(nsColor: NSColor(red: 0.996, green: 0.929, blue: 0, alpha: 1))))
        _useGradient = State(initialValue: !recipe.backgroundEndHex.isEmpty)
        _backgroundEnd = State(initialValue: recipe.backgroundEndHex.isEmpty
            ? .purple
            : Color(cssColor: recipe.backgroundEndHex, fallback: .purple))
        _picked = State(initialValue: (recipe.imageBased ? existingImage : nil))
        if recipe.textColorHex.isEmpty {
            _textColor = State(initialValue: .black)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(existing == nil ? "Make an Icon" : "Edit Icon")
                .font(.title3.bold())

            ZStack {
                if let picked {
                    Image(nsImage: picked)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    if useGradient {
                        LinearGradient(
                            colors: [backgroundColor, backgroundEnd],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    } else {
                        Rectangle().fill(backgroundColor)
                    }
                    Text(text.isEmpty ? "T" : text)
                        .font(previewFont)
                        .foregroundStyle(textColor)
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )

            TextField("1–3 letters, or an emoji", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 190)
                .onChange(of: text) { _, value in
                    if value.count > 3 { text = String(value.prefix(3)) }
                    if !value.isEmpty { picked = nil }
                }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Font").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button {
                        showFontPicker = true
                    } label: {
                        HStack {
                            Text(fontFamily.isEmpty ? "System" : fontFamily)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 160, alignment: .leading)
                    .popover(isPresented: $showFontPicker, arrowEdge: .trailing) {
                        VStack(spacing: 6) {
                            Button("Use System Font") {
                                fontFamily = ""
                                fontReady = true
                                showFontPicker = false
                            }
                            .controlSize(.small)
                            FontPickerView(pinned: pinned, current: fontFamily) { family in
                                fontFamily = family.family
                                fontReady = false
                                GoogleFonts.registerForPreview(family) { ok in fontReady = ok }
                                showFontPicker = false
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                GridRow {
                    Text("Text").font(.system(size: 11)).foregroundStyle(.secondary)
                    ColorPicker("", selection: $textColor, supportsOpacity: false)
                        .labelsHidden()
                }
                GridRow {
                    Text("Fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ColorPicker("", selection: $backgroundColor, supportsOpacity: false)
                            .labelsHidden()
                        Toggle("Gradient", isOn: $useGradient)
                            .font(.system(size: 11))
                        if useGradient {
                            ColorPicker("", selection: $backgroundEnd, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(Array(quickColors.enumerated()), id: \.offset) { item in
                    Button {
                        backgroundColor = Color(nsColor: item.element)
                        picked = nil
                    } label: {
                        Circle()
                            .fill(Color(nsColor: item.element))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Use an Image…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
                    picked = image
                }
            }
            .controlSize(.small)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var previewFont: Font {
        let size: CGFloat = text.count > 2 ? 28 : (text.count == 2 ? 38 : 50)
        if fontFamily.isEmpty || !fontReady { return .system(size: size, weight: .bold) }
        return .custom(fontFamily, size: size)
    }

    private func save() {
        var recipe = IconRecipe()
        recipe.text = text.isEmpty ? "T" : text
        recipe.fontFamily = fontFamily
        recipe.textColorHex = textColor.hexString
        recipe.backgroundHex = backgroundColor.hexString
        recipe.backgroundEndHex = useGradient ? backgroundEnd.hexString : ""
        recipe.imageBased = picked != nil
        if let url = renderTimIcon(recipe: recipe, image: picked) {
            onSave(recipe, url)
        }
        dismiss()
    }
}

func nsColor(fromHex hex: String, fallback: NSColor) -> NSColor {
    guard hex.hasPrefix("#"), hex.count >= 7,
          let r = Int(hex.dropFirst().prefix(2), radix: 16),
          let g = Int(hex.dropFirst(3).prefix(2), radix: 16),
          let b = Int(hex.dropFirst(5).prefix(2), radix: 16)
    else { return fallback }
    return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

/// Renders the 180×180 PNG used for both apple-touch-icon and favicon.
func renderTimIcon(recipe: IconRecipe, image: NSImage?) -> URL? {
    let side: CGFloat = 180
    let canvas = NSImage(size: NSSize(width: side, height: side))
    canvas.lockFocus()
    let full = NSRect(x: 0, y: 0, width: side, height: side)
    if let image, image.size.width > 0, image.size.height > 0 {
        let scale = max(side / image.size.width, side / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        image.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
    } else {
        let start = nsColor(fromHex: recipe.backgroundHex, fallback: NSColor(red: 0.996, green: 0.929, blue: 0, alpha: 1))
        if !recipe.backgroundEndHex.isEmpty,
           let gradient = NSGradient(starting: start, ending: nsColor(fromHex: recipe.backgroundEndHex, fallback: .systemPurple)) {
            gradient.draw(in: full, angle: -45)
        } else {
            start.setFill()
            full.fill()
        }
        let display = recipe.text.isEmpty ? "T" : recipe.text
        let fontSize: CGFloat = display.count == 1 ? 96 : (display.count == 2 ? 68 : 48)
        var font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        if !recipe.fontFamily.isEmpty {
            font = NSFont(name: recipe.fontFamily, size: fontSize)
                ?? NSFontManager.shared.font(withFamily: recipe.fontFamily, traits: [], weight: 9, size: fontSize)
                ?? font
        }
        let srgb = (nsColor(fromHex: recipe.backgroundHex, fallback: .white).usingColorSpace(.sRGB)) ?? .white
        let luminance = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        let foreground = recipe.textColorHex.isEmpty
            ? (luminance > 0.6 ? NSColor.black : NSColor.white)
            : nsColor(fromHex: recipe.textColorHex, fallback: .white)
        let string = NSAttributedString(string: display, attributes: [.font: font, .foregroundColor: foreground])
        let size = string.size()
        string.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
    }
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("icon.png")
    try? png.write(to: url)
    return url
}

// MARK: - Google Fonts picker: the whole catalog, each family in its own face

struct FontPickerView: View {
    var pinned: [String] = []
    var current: String = ""
    let onPick: (GoogleFonts.Family) -> Void

    @State private var catalog: [GoogleFonts.Family] = []
    @State private var search = ""
    @State private var sample = ""
    @State private var category = "all"

    private let categories: [(String, String)] = [
        ("all", "All"), ("sans-serif", "Sans"), ("serif", "Serif"),
        ("display", "Display"), ("handwriting", "Script"), ("monospace", "Mono")
    ]

    private var filtered: [GoogleFonts.Family] {
        catalog.filter { family in
            (category == "all" || family.category == category)
                && (search.isEmpty || family.family.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search Google Fonts", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(categories, id: \.0) { pair in
                        Button {
                            category = pair.0
                        } label: {
                            Text(pair.1)
                                .font(.system(size: 11, weight: category == pair.0 ? .semibold : .regular))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .background(Capsule().fill(category == pair.0 ? Color.accentColor : Color.primary.opacity(0.06)))
                                .foregroundStyle(category == pair.0 ? Color.white : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 1)
            }

            if catalog.isEmpty {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Loading the catalog…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let pinnedFamilies = filtered.filter { pinned.contains($0.family) }
                        if !pinnedFamilies.isEmpty {
                            sectionHeader("On this site")
                            ForEach(pinnedFamilies) { family in
                                FontRow(family: family, sample: sample, isCurrent: family.family == current) {
                                    onPick(family)
                                }
                            }
                            sectionHeader("All fonts")
                        }
                        ForEach(filtered.filter { !pinned.contains($0.family) }) { family in
                            FontRow(family: family, sample: sample, isCurrent: family.family == current) {
                                onPick(family)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Preview text…", text: $sample)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                Text(catalog.isEmpty ? "" : "\(filtered.count) families")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(12)
        .frame(width: 340, height: 480)
        .onAppear {
            GoogleFonts.catalog { catalog = $0 }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.bottom, 3)
    }
}

struct FontRow: View {
    let family: GoogleFonts.Family
    var sample: String = ""
    var isCurrent: Bool = false
    let pick: () -> Void

    @State private var ready = false
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sample.isEmpty ? family.family : sample)
                        .font(ready ? .custom(family.family, size: 16) : .system(size: 13))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if !sample.isEmpty {
                            Text(family.family)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Text(family.category)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.08) : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear {
            GoogleFonts.registerForPreview(family) { ok in ready = ok }
        }
    }
}

// MARK: - WebKit bridge

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
