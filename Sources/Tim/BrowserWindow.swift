import SwiftUI
import AppKit
import WebKit
import TimKit

// SwiftUI has its own `Tab` (TabView); ours wins in this file.
typealias Tab = TimKit.Tab

struct BrowserWindow: View {
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        VStack(spacing: 0) {
            if store.tabs.count > 1 {
                TabBarView()
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

// MARK: - Safari-style tab bar (appears with a second tab)

struct TabBarView: View {
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.tabs) { tab in
                TabChip(
                    tab: tab,
                    isSelected: tab.id == store.selectedTabID,
                    select: { store.selectedTabID = tab.id },
                    close: { store.close(tab) }
                )
            }
            Button {
                store.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(height: 32)
    }
}

struct TabChip: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Spacer(minLength: 0)
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.45)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: 220, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.09) : (hovering ? Color.primary.opacity(0.04) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close Tab") { close() }
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
    @FocusState private var addressFocused: Bool

    private var pageURL: URL? { URL(string: tab.urlString) }
    private var matchedSite: Site? { siteStore.match(pageURL) }

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
            WebViewContainer(webView: tab.webView)
        }
        .background(.background)
        .navigationTitle("")
        .toolbar { toolbarContent }
        .onAppear {
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
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(tab: tab, site: matchedSite)
        }
        .sheet(isPresented: $showConnectSheet) {
            SiteEditorSheet(site: nil, prefillOrigin: originString(from: pageURL))
        }
        .sheet(item: $editingSite) { site in
            SiteEditorSheet(site: site, prefillOrigin: nil)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
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

                TextField("Search or enter website name", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .multilineTextAlignment(addressFocused ? .leading : .center)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 240, idealWidth: 440, maxWidth: 520)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
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
            Button {
                tab.setEditing(!tab.isEditing)
            } label: {
                Image(systemName: tab.isEditing ? "pencil.circle.fill" : "pencil.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(tab.isEditing || matchedSite != nil ? Color.accentColor : Color.secondary)
            }
            .help(tab.isEditing ? "Stop Editing (⌘E)" : "Edit This Page (⌘E)")

            Menu {
                ForEach(siteStore.sites) { site in
                    Menu(site.name.isEmpty ? site.origin : site.name) {
                        Button("Open") { tab.navigate(to: site.origin) }
                        Button("Edit…") { editingSite = site }
                        Button("Delete", role: .destructive) { siteStore.delete(site) }
                    }
                }
                if !siteStore.sites.isEmpty { Divider() }
                Button("Connect Site…") { showConnectSheet = true }
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

// MARK: - Editing toolbar (the Keynote-ish part)

struct EditingToolbar: View {
    @ObservedObject var tab: Tab
    let site: Site?
    let publish: () -> Void
    let connect: () -> Void

    @State private var showLinkPopover = false
    @State private var linkURL = ""
    @State private var savedFlash = false
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
            Picker("", selection: Binding(
                get: { tab.isArranging ? 1 : 0 },
                set: { tab.setArranging($0 == 1) }
            )) {
                Text("Text").tag(0)
                Text("Layout").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Divider().frame(height: 16)

            if tab.isArranging {
                Button {
                    tab.insertObject(html: """
                    <div class="tim-object tim-text tim-style-body" style="left: 8%; width: 38%;">Double-click to edit</div>
                    """)
                } label: {
                    Label("Text Box", systemImage: "character.textbox")
                }
                Button {
                    insertMedia(video: false)
                } label: {
                    Label("Image…", systemImage: "photo")
                }
                Button {
                    insertMedia(video: true)
                } label: {
                    Label("Video…", systemImage: "video")
                }

                Divider().frame(height: 16)

                Menu {
                    Button("Title") { tab.applyTextStyle("tim-style-title") }
                    Button("Heading") { tab.applyTextStyle("tim-style-heading") }
                    Button("Subheading") { tab.applyTextStyle("tim-style-subheading") }
                    Button("Body") { tab.applyTextStyle("tim-style-body") }
                    Button("Caption") { tab.applyTextStyle("tim-style-caption") }
                    Divider()
                    Button("Clear Style") { tab.applyTextStyle("") }
                } label: {
                    Label("Styles", systemImage: "textformat.alt")
                }
                .fixedSize()

                Text("drag to move · double-click text to edit · ⌫ deletes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("Title") { tab.format("formatBlock", value: "h1") }
                    Button("Heading") { tab.format("formatBlock", value: "h2") }
                    Button("Subheading") { tab.format("formatBlock", value: "h3") }
                    Button("Body") { tab.format("formatBlock", value: "p") }
                    Button("Quote") { tab.format("formatBlock", value: "blockquote") }
                    Button("Code") { tab.format("formatBlock", value: "pre") }
                } label: {
                    Label("Style", systemImage: "textformat")
                }
                .fixedSize()

                FormatButton(symbol: "bold") { tab.format("bold") }
                FormatButton(symbol: "italic") { tab.format("italic") }
                FormatButton(symbol: "underline") { tab.format("underline") }
                FormatButton(symbol: "strikethrough") { tab.format("strikethrough") }

                Divider().frame(height: 16)

                FormatButton(symbol: "list.bullet") { tab.format("insertUnorderedList") }
                FormatButton(symbol: "list.number") { tab.format("insertOrderedList") }

                FormatButton(symbol: "link") { showLinkPopover = true }
                    .popover(isPresented: $showLinkPopover, arrowEdge: .bottom) {
                        HStack {
                            TextField("https://…", text: $linkURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit { addLink() }
                            Button("Add Link") { addLink() }
                        }
                        .padding(10)
                    }

                FormatButton(symbol: "arrow.uturn.backward") { tab.format("undo") }
                FormatButton(symbol: "arrow.uturn.forward") { tab.format("redo") }
            }

            if isAstroSite {
                Divider().frame(height: 16)

                Menu {
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
                } label: {
                    Label("Insert", systemImage: "plus.square.on.square")
                }
                .fixedSize()

                Button {
                    showThemePanel = true
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
                .popover(isPresented: $showThemePanel, arrowEdge: .bottom) {
                    ThemePanel(site: site, tab: tab)
                }
            }

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
            if savedFlash {
                Text("Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            if isAstroSite {
                Button("Publish") { publish() }
                    .keyboardShortcut("s", modifiers: .command)
            } else if isLocalFile {
                Button("Save") { saveLocalFile() }
                    .keyboardShortcut("s", modifiers: .command)
            } else if site != nil {
                Button("Publish") { publish() }
                    .keyboardShortcut("s", modifiers: .command)
            } else {
                Text("Edits are local only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect Site…") { connect() }
            }

            Button("Done") { tab.setEditing(false) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .sheet(isPresented: $showNewPageSheet) {
            NewPageSheet(site: site, tab: tab)
        }
    }

    /// Copies a chosen image/video into the site (public/media + dist/media)
    /// or beside a local page, then inserts it as a canvas object.
    private func insertMedia(video: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        let name = fileURL.lastPathComponent
        var src: String?
        do {
            if let site, isAstroSite {
                let project = site.localProjectPath
                for folder in ["public/media", "dist/media"] {
                    let dir = (project as NSString).appendingPathComponent(folder)
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let dest = (dir as NSString).appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: dest) {
                        try FileManager.default.removeItem(atPath: dest)
                    }
                    try FileManager.default.copyItem(atPath: fileURL.path, toPath: dest)
                }
                src = "media/\(name)"
            } else if let pageURL = tab.webView.url, pageURL.isFileURL {
                let dest = pageURL.deletingLastPathComponent().appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: fileURL, to: dest)
                src = name
            } else {
                statusMessage = "Media needs a connected site or a local page to live in."
                return
            }
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        guard let src else { return }
        if video {
            tab.insertObject(html: """
            <video class="tim-object" controls src="\(src)" style="left: 8%; width: 48%;"></video>
            """)
        } else {
            tab.insertObject(html: """
            <img class="tim-object" src="\(src)" style="left: 8%; width: 40%;" alt="" />
            """)
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

    private func addLink() {
        let url = linkURL.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty {
            tab.format("createLink", value: url)
        }
        linkURL = ""
        showLinkPopover = false
    }

    private func saveLocalFile() {
        guard let url = tab.webView.url, url.isFileURL else { return }
        tab.currentHTML { html in
            guard let html else { return }
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
                withAnimation { savedFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { savedFlash = false }
                }
            } catch {
                NSSound.beep()
            }
        }
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

    private var allFonts: [FontOption] { FontCatalog.options + importedFonts }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Headings")
                    fontPicker(selection: $headingFont)
                }
                GridRow {
                    Text("Body")
                    fontPicker(selection: $bodyFont)
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
    }

    private func fontPicker(selection: Binding<FontOption>) -> some View {
        Menu {
            ForEach(allFonts) { font in
                Button(font.name) { selection.wrappedValue = font }
            }
        } label: {
            Text(selection.wrappedValue.name)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var isLayoutPage = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Page")
                .font(.title3.bold())

            TextField("Page title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            Picker("", selection: $isLayoutPage) {
                Text("Layout").tag(true)
                Text("Text").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(isLayoutPage
                 ? "A canvas page: place and move text boxes, images, and video freely — boxes grow downward as needed."
                 : "A text page: a flowing document, like a plain article.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Creates src/pages/\(slug.isEmpty ? "…" : slug).astro from your site's layout, builds, and opens it.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    .disabled(isCreating || slug.isEmpty)
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
        guard let site else { return }
        isCreating = true
        errorMessage = nil
        let pageTitle = title
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rel = try ComponentLibrary.createPage(
                    slug: slug, title: pageTitle, projectPath: site.localProjectPath,
                    layoutPage: isLayoutPage
                )
                _ = try AstroProject.build(projectPath: site.localProjectPath)
                DispatchQueue.main.async {
                    isCreating = false
                    tab.navigate(to: site.origin + rel)
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
                work = { try SFTP.upload(html: html, to: path, host: h, username: u, port: p) }
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
    }

    private var targetCaption: String {
        switch draft.target {
        case .sftp:
            return "Works with any web host that offers SFTP. Uses your SSH keys — password login isn’t supported."
        case .cloudflare:
            return "Deploys with Wrangler to Cloudflare’s free global network. One-time setup in Terminal: npm install -g wrangler && wrangler login."
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
        case .cloudflare: return !draft.cfProjectName.isEmpty && !draft.localProjectPath.isEmpty
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
        siteStore.upsert(draft)
        dismiss()
    }
}

// MARK: - WebKit bridge

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
