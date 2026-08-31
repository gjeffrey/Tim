import SwiftUI
import AppKit
import WebKit
import TimKit

// SwiftUI has its own `Tab` (TabView); ours wins in this file.
typealias Tab = TimKit.Tab

extension Notification.Name {
    static let timNewPage = Notification.Name("tim.newPage")
    static let timOpenPage = Notification.Name("tim.openPage")
    static let timDuplicatePage = Notification.Name("tim.duplicatePage")
    static let timToggleEdit = Notification.Name("tim.toggleEdit")
    static let timThumbsUpdated = Notification.Name("tim.thumbsUpdated")
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
        siteStore.isEditable(URL(string: tab.urlString))
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
                            Text(page.label)
                                .font(.system(size: 11.5, weight: page.href == currentRel ? .semibold : .regular))
                                .lineLimit(1)
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
                            rollback(to: version.sha)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(version.date).font(.system(size: 11))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Restore this page to this version and republish it.")
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
        }
    }

    private func refresh() {
        guard let site else { pages = []; versions = []; return }
        let rel = currentRel
        DispatchQueue.global(qos: .utility).async {
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
    @AppStorage("tim.siteSidebar") private var showSiteSidebar = true
    @FocusState private var addressFocused: Bool

    private var pageURL: URL? { URL(string: tab.urlString) }
    private var matchedSite: Site? { siteStore.match(pageURL) }
    private var isPageEditable: Bool { siteStore.isEditable(pageURL) }

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
            if tab.isEditing {
                Divider()
                InspectorView(tab: tab)
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
        .onReceive(NotificationCenter.default.publisher(for: .timToggleEdit)) { _ in
            if tab.isEditing {
                finishEditing()
            } else if isPageEditable {
                tab.setEditing(true)
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if tab.isEditing, isPlainLocalPage { savePlainLocalPage() }
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
            if let html { try? html.write(to: url, atomically: true, encoding: .utf8) }
            completion?()
        }
    }

    /// Done means done: local pages save, site pages publish. One action.
    private func finishEditing() {
        guard let url = tab.webView.url else { tab.setEditing(false); return }

        if isPlainLocalPage {
            savePlainLocalPage {
                PageRegistry.record(url: url.absoluteString, title: tab.title)
                tab.setEditing(false)
                captureThumbnailSoon()
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
        tab.currentHTML { html in
            tab.setEditing(false)
            guard let html else { return }
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
                    switch site.target {
                    case .sftp:
                        let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                        _ = try SFTP.upload(html: html, to: root + rel, host: site.host, username: site.username, port: site.port)
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
                        PageRegistry.record(url: url.absoluteString, title: tab.title)
                        captureThumbnailSoon()
                    }
                } catch {
                    DispatchQueue.main.async { publishAlert(error) }
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
                DispatchQueue.main.async { tab.webView.reload() }
            } catch {
                DispatchQueue.main.async { publishAlert(error) }
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
                }
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
            siteStore.upsert(updated)
        }
        SiteWorkspace.ensure(updated.localProjectPath)
        return updated
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
            } else if isPageEditable {
                Button("Edit") { tab.setEditing(true) }
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
            FontPickerView { family in
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

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            Group {
                if let info = tab.selectionInfo {
                    ScrollView {
                        InspectorControls(tab: tab, info: info)
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
    let info: [String: Any]

    @State private var styleClass: String
    @State private var fontFamilyName: String
    @State private var fontSize: Double
    @State private var weightIndex: Int
    @State private var lineHeight: Double
    @State private var letterSpacing: Double
    @State private var textColor: Color
    @State private var fillColor: Color
    @State private var radius: Double
    @State private var padding: Double
    @State private var opacity: Double
    @State private var hasShadow: Bool
    @State private var showFontPicker = false

    private let weights = [400, 500, 600, 700]

    init(tab: Tab, info: [String: Any]) {
        self.tab = tab
        self.info = info
        let cls = info["timStyle"] as? String ?? ""
        _styleClass = State(initialValue: cls.isEmpty ? "tim-style-body" : cls)
        let family = info["fontFamily"] as? String ?? ""
        _fontFamilyName = State(initialValue: (family.hasPrefix("-apple-") || family.hasPrefix(".")) ? "" : family)
        _fontSize = State(initialValue: info["fontSize"] as? Double ?? 16)
        let weight = info["fontWeight"] as? Int ?? 400
        _weightIndex = State(initialValue: [400, 500, 600, 700].lastIndex(where: { $0 <= weight }) ?? 0)
        _lineHeight = State(initialValue: min(2.2, max(1.0, info["lineHeight"] as? Double ?? 1.4)))
        _letterSpacing = State(initialValue: min(8, max(-2, info["letterSpacing"] as? Double ?? 0)))
        _textColor = State(initialValue: .primary)
        _fillColor = State(initialValue: .clear)
        _radius = State(initialValue: info["radius"] as? Double ?? 0)
        _padding = State(initialValue: info["padding"] as? Double ?? 0)
        _opacity = State(initialValue: info["opacity"] as? Double ?? 1)
        _hasShadow = State(initialValue: (info["hasShadow"] as? Int) == 1)
    }

    private var isText: Bool {
        (info["isText"] as? Int) == 1
            || ["h1", "h2", "h3", "h4", "h5", "h6", "p", "blockquote", "li"].contains(info["tag"] as? String ?? "")
    }
    private var hasOverrides: Bool { (info["overrides"] as? Int) == 1 }
    private var styleName: String { timStyles.first { $0.cls == styleClass }?.name ?? "Body" }

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
        }
        .padding(10)
    }

    // MARK: Style (the Pages/Keynote contract)

    private var styleCard: some View {
        card {
            HStack(spacing: 8) {
                rowLabel("Style")
                Picker("", selection: $styleClass) {
                    ForEach(timStyles, id: \.cls) { style in
                        Text(style.name).tag(style.cls)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: styleClass) { _, cls in tab.applyTextStyle(cls) }
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

    // MARK: Typography

    private var typographyCard: some View {
        card("Typography") {
            Button {
                showFontPicker = true
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
                FontPickerView { family in
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

            sliderRow("Leading", $lineHeight, 1.0...2.2, 0.05, String(format: "%.2f", lineHeight))
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
        }
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
                    .onChange(of: hasShadow) { _, on in
                        tab.setSelectionStyle("boxShadow", on ? "0 8px 24px rgba(0,0,0,0.18)" : "")
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

                metaFileRow(
                    label: "Social Image",
                    value: ogImage,
                    hint: "Shown when this page is shared or texted.",
                    kind: "ogImage"
                )
                metaFileRow(
                    label: "Favicon",
                    value: favicon,
                    hint: "The little icon in tabs and bookmarks.",
                    kind: "favicon"
                )
            }

            Text("Select an object to style it — click empty space to come back to the page.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .padding(10)
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

    /// Stages the picked image like any media (mirror + upload), then
    /// points the metadata at it — absolute URL for the social image, so
    /// link scrapers can fetch it.
    private func chooseMetaImage(kind: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

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
                let value: String
                if kind == "ogImage", let s = resolvedSite, s.origin.hasPrefix("http") {
                    value = s.origin + "/" + staged
                } else {
                    value = staged
                }
                DispatchQueue.main.async {
                    tab.setPageMeta(kind, value)
                    if kind == "ogImage" { ogImage = value } else { favicon = value }
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

// MARK: - Google Fonts picker: the whole catalog, each family in its own face

struct FontPickerView: View {
    let onPick: (GoogleFonts.Family) -> Void

    @State private var catalog: [GoogleFonts.Family] = []
    @State private var search = ""
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
        VStack(spacing: 8) {
            TextField("Search Google Fonts", text: $search)
                .textFieldStyle(.roundedBorder)
            Picker("", selection: $category) {
                ForEach(categories, id: \.0) { pair in
                    Text(pair.1).tag(pair.0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if catalog.isEmpty {
                Spacer()
                ProgressView()
                Text("Loading the catalog…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { family in
                            FontRow(family: family) { onPick(family) }
                        }
                    }
                }
            }

            Text(catalog.isEmpty ? " " : "\(filtered.count) families · previews load as you scroll")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 300, height: 430)
        .onAppear {
            GoogleFonts.catalog { catalog = $0 }
        }
    }
}

struct FontRow: View {
    let family: GoogleFonts.Family
    let pick: () -> Void

    @State private var ready = false
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack {
                Text(family.family)
                    .font(ready ? .custom(family.family, size: 15) : .system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 10)
                Text("Aa")
                    .font(ready ? .custom(family.family, size: 17) : .system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
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
