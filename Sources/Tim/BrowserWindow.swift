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
    static let timSubmitShowcase = Notification.Name("tim.submitShowcase")
    static let timThumbsUpdated = Notification.Name("tim.thumbsUpdated")
    static let timPreviewVersion = Notification.Name("tim.previewVersion")
    static let timEditNav = Notification.Name("tim.editNav")
    static let timReplaceMedia = Notification.Name("tim.replaceMedia")
    static let timUpscaleMedia = Notification.Name("tim.upscaleMedia")
    static let timMovePage = Notification.Name("tim.movePage")
    static let timBounceVideo = Notification.Name("tim.bounceVideo")
}

/// Liquid Glass where Tahoe offers it, honest material everywhere else.
/// The creative-app posture: chrome recedes into glass, the page is the
/// hero, and Tim's identity colors ride on top as accents.
extension View {
    func timGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }

    /// Panel chrome: the soft translucent ground sidebars and inspectors
    /// sit on.
    func timPanel() -> some View {
        self.background(.ultraThinMaterial)
    }

    /// The app's one side-panel treatment, shared with the page card:
    /// a rounded material card with a hairline edge, soft shadow, and
    /// thin even margins — Lightbox's PanelCard, adopted so every pane
    /// in every app of the house looks like the same idea.
    func timPanelCard(width: CGFloat = 280) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return self
            .frame(width: width)
            .clipShape(shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(8)
    }
}

/// Tim's yellow — the color of ownership. It marks what's yours (the
/// frame around your page, the pill's pencil, your site's name) and
/// nothing else; tools and selection stay blue so they read anywhere.
let timYellow = Color(red: 0.996, green: 0.929, blue: 0)

/// Parses "linear-gradient(140deg, <c1>, <c2>)" back into its parts —
/// colors may be hex or rgb(), whatever Color(cssColor:) reads.
func parseLinearGradient(_ value: String) -> (angle: Double, start: String, end: String)? {
    guard value.contains("linear-gradient"),
          let regex = try? NSRegularExpression(
            pattern: "linear-gradient\\(\\s*([0-9.]+)deg\\s*,\\s*(#[0-9a-fA-F]+|rgba?\\([^)]*\\))\\s*,\\s*(#[0-9a-fA-F]+|rgba?\\([^)]*\\))"
          ),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          let a = Range(match.range(at: 1), in: value),
          let s = Range(match.range(at: 2), in: value),
          let e = Range(match.range(at: 3), in: value),
          let angle = Double(value[a])
    else { return nil }
    return (angle, String(value[s]), String(value[e]))
}

/// The social card, by default and hands-off: after every publish, the
/// page is re-rendered offscreen at the card's own aspect (600×315 —
/// under the phone breakpoint, so the bold mobile styles compose it)
/// and shipped as social-<page>.png. A page with a custom image is
/// never touched. Never depends on where the user's tab wandered.
final class SocialCards: NSObject, WKNavigationDelegate {
    static let shared = SocialCards()

    private struct Job { let url: URL; let site: Site; let slug: String }
    private var queue: [Job] = []
    private var busy = false
    private var current: Job?
    private var activity: UUID?
    private lazy var webView: WKWebView = {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 315))
        view.navigationDelegate = self
        return view
    }()

    func capture(pageURL: URL, site: Site, pageHTML: String) {
        if let existing = TabContentView.metaContent(in: pageHTML, property: "og:image"),
           !(existing as NSString).lastPathComponent.hasPrefix("social-") {
            return  // custom image — theirs, never touched
        }
        let rel = site.relativePagePath(for: pageURL)
        let slug = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        DispatchQueue.main.async {
            guard !self.queue.contains(where: { $0.slug == slug }) else { return }
            self.queue.append(Job(url: pageURL, site: site, slug: slug))
            self.pump()
        }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        current = queue.removeFirst()
        activity = ActivityCenter.shared.begin("Updating share card…")
        // A cache-buster keeps CDN copies from serving the previous save.
        var parts = URLComponents(url: current!.url, resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "timcard", value: String(Int(Date().timeIntervalSince1970)))]
        webView.load(URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        let started = current?.slug
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.busy, self.current?.slug == started else { return }
            self.finish()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let job = self.current else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 1200
            self.webView.takeSnapshot(with: config) { image, _ in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { self.finish(); return }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("social-\(job.slug).png")
                try? png.write(to: temp)
                DispatchQueue.global(qos: .utility).async {
                    _ = try? EditingToolbar.stage(fileURL: temp, site: job.site, pageURL: job.url)
                    DispatchQueue.main.async { self.finish() }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    private func finish() {
        guard busy else { return }
        if let activity { ActivityCenter.shared.end(activity) }
        activity = nil
        busy = false
        current = nil
        pump()
    }
}

/// Mobile thumbnails, made offscreen: a hidden iPhone-sized web view
/// loads pages one at a time and snapshots them, so the sidebar can
/// show every page's phone rendition without ever touching your tab.
final class MobileThumbs: NSObject, WKNavigationDelegate {
    static let shared = MobileThumbs()

    private var queue: [String] = []
    private var busy = false
    private var current: String?
    private lazy var webView: WKWebView = {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = self
        return view
    }()

    static func key(_ url: String) -> String { "mobile:" + url }

    /// Queues a capture; refreshOnly skips URLs that already have one.
    func capture(_ url: String, onlyIfMissing: Bool = false) {
        DispatchQueue.main.async {
            if onlyIfMissing, ThumbnailStore.image(for: Self.key(url)) != nil { return }
            guard !self.queue.contains(url), self.current != url, URL(string: url) != nil else { return }
            self.queue.append(url)
            self.pump()
        }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        current = queue.removeFirst()
        webView.load(URLRequest(url: URL(string: current!)!))
        // Failsafe: a page that never finishes shouldn't stall the queue —
        // but only time out THIS load, never a successor.
        let started = current
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.busy, self.current == started else { return }
            self.finish()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let url = self.current else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 160
            self.webView.takeSnapshot(with: config) { image, _ in
                if let image {
                    ThumbnailStore.save(image, for: Self.key(url))
                    NotificationCenter.default.post(name: .timThumbsUpdated, object: nil)
                }
                self.finish()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    private func finish() {
        guard busy else { return }
        busy = false
        current = nil
        pump()
    }
}

/// Everything Tim does behind your back — publishing, uploads, mirror
/// downloads, share cards — registers here, and the toolbar shows a
/// spinner you can click to see exactly what's in flight.
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()
    struct Activity: Identifiable, Equatable {
        let id = UUID()
        let label: String
    }
    @Published var activities: [Activity] = []

    @discardableResult
    func begin(_ label: String) -> UUID {
        let activity = Activity(label: label)
        DispatchQueue.main.async { self.activities.append(activity) }
        return activity.id
    }

    func end(_ id: UUID) {
        DispatchQueue.main.async { self.activities.removeAll { $0.id == id } }
    }
}

/// The activity item, the Transmit way: always in the toolbar, quiet
/// when idle, spinning while anything's in flight, badged when several
/// are. Clicking it shows the work. It never appears or disappears —
/// the toolbar is the toolbar.
struct ActivityIndicator: View {
    @ObservedObject var center = ActivityCenter.shared
    @State private var showList = false

    var body: some View {
        Button {
            showList.toggle()
        } label: {
            // Both states always exist; only opacity changes. A structural
            // swap here rebuilds the toolbar and steals focus from the
            // address field mid-keystroke.
            ZStack {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.secondary)
                    .opacity(center.activities.isEmpty ? 1 : 0)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .opacity(center.activities.isEmpty ? 0 : 1)
            }
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .topTrailing) {
            if center.activities.count > 1 {
                Text("\(center.activities.count)")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(Color.white)
                    .offset(x: 5, y: -3)
                    .allowsHitTesting(false)
            }
        }
        .help(center.activities.first?.label ?? "Activity — publishes and uploads show here while they work")
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if center.activities.isEmpty {
                    Text("No Activity")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Publishing, media uploads, and share cards appear here while they work.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("In Progress")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(center.activities) { activity in
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).scaleEffect(0.75)
                            Text(activity.label)
                                .font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
    }
}

struct BrowserWindow: View {
    @EnvironmentObject var store: BrowserStore
    @State private var columns = NavigationSplitViewVisibility.all

    // The system sidebar structure is what buys the Tahoe look: the
    // wallpaper glows through the sidebar glass, the toolbar unifies
    // with the window, and the whole app reads native instead of built.
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            UnifiedSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 256, max: 320)
        } detail: {
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

    // Press-and-drag reorder: the pressed card lifts and tracks the
    // cursor raw; neighbors slide aside with a spring as the target slot
    // changes; the array itself only reorders on release. Pinned tabs
    // reorder among pinned, the rest among the rest.
    @State private var draggedID: UUID?
    @State private var dragStartIndex = 0
    @State private var dragTargetIndex = 0
    @State private var dragTranslation: CGFloat = 0

    @AppStorage("tim.tabDomains") private var tabDomains = false

    private var rowStep: CGFloat { TabCard.height(showingDomains: tabDomains) + TabCard.spacing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                VStack(spacing: TabCard.spacing) {
                    ForEach(store.tabs) { t in
                        TabCard(
                            tab: t,
                            isSelected: t.id == store.selectedTabID,
                            isDragging: draggedID == t.id,
                            close: { store.close(t) },
                            closeOthers: {
                                for other in store.tabs where other.id != t.id && !other.isPinned {
                                    store.close(other)
                                }
                                store.selectedTabID = t.id
                            },
                            togglePin: {
                                withAnimation(.spring(duration: 0.3)) { store.setPinned(t, !t.isPinned) }
                            }
                        )
                        .offset(y: rowOffset(for: t))
                        .zIndex(draggedID == t.id ? 1 : 0)
                        .onTapGesture { store.selectedTabID = t.id }
                        .gesture(reorderGesture(for: t))
                    }
                }
                NewTabButton { store.newTab() }
                    .padding(.top, 2)

                if let tab = store.selectedTab {
                    SiteSection(tab: tab)
                        .id(tab.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where the dragged tab may land: pinned tabs stay in the pinned
    /// block, everything else below it.
    private func groupBounds(for tab: Tab) -> ClosedRange<Int> {
        let boundary = store.tabs.firstIndex(where: { !$0.isPinned }) ?? store.tabs.count
        if tab.isPinned { return 0...max(0, boundary - 1) }
        return min(boundary, store.tabs.count - 1)...(store.tabs.count - 1)
    }

    private func rowOffset(for tab: Tab) -> CGFloat {
        guard let draggedID else { return 0 }
        if tab.id == draggedID { return dragTranslation }
        guard let index = store.tabs.firstIndex(where: { $0.id == tab.id }) else { return 0 }
        // Neighbors step aside as the lifted card's target slot passes them.
        if dragStartIndex < dragTargetIndex, index > dragStartIndex, index <= dragTargetIndex {
            return -rowStep
        }
        if dragStartIndex > dragTargetIndex, index < dragStartIndex, index >= dragTargetIndex {
            return rowStep
        }
        return 0
    }

    private func reorderGesture(for tab: Tab) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if draggedID != tab.id {
                    draggedID = tab.id
                    dragStartIndex = store.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
                    dragTargetIndex = dragStartIndex
                }
                dragTranslation = value.translation.height
                let bounds = groupBounds(for: tab)
                let proposed = dragStartIndex + Int((dragTranslation / rowStep).rounded())
                let target = max(bounds.lowerBound, min(bounds.upperBound, proposed))
                if target != dragTargetIndex {
                    withAnimation(.spring(duration: 0.28)) { dragTargetIndex = target }
                }
            }
            .onEnded { _ in
                let target = dragTargetIndex
                withAnimation(.spring(duration: 0.32)) {
                    store.move(tab, to: target)
                    draggedID = nil
                    dragTranslation = 0
                }
            }
    }
}

/// A tab as a card: a rectangular object you press to switch, drag to
/// reorder, pin to keep, and close from its own corner. The identity
/// badge speaks the ownership grammar — a black pencil on Tim yellow
/// when the page is yours, a quiet globe when it isn't.
struct TabCard: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let isDragging: Bool
    let close: () -> Void
    let closeOthers: () -> Void
    let togglePin: () -> Void
    @EnvironmentObject var siteStore: SiteStore
    @State private var hovering = false
    @AppStorage("tim.tabDomains") private var tabDomains = false

    // Title-only cards sit tighter; the domain line earns the extra room.
    static func height(showingDomains: Bool) -> CGFloat { showingDomains ? 46 : 36 }
    static let spacing: CGFloat = 5

    private var isEditable: Bool {
        siteStore.isEditable(URL(string: tab.urlString), timAuthored: tab.isTimPage)
    }


    private var subtitle: String {
        guard let host = URL(string: tab.urlString)?.host, !host.isEmpty else { return "Start Page" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(isEditable ? timYellow : Color.primary.opacity(0.07))
                Image(systemName: isEditable ? "pencil" : "globe")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isEditable ? Color.black : Color.secondary)
            }
            .frame(width: 23, height: 23)
            .help(isEditable ? "This page is yours — you can edit it." : "")

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(tab.title.isEmpty ? "New Tab" : tab.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if tab.isEditing {
                        CautionTape(stripe: 3)
                            .frame(width: 18, height: 6)
                            .clipShape(Capsule())
                            .help("Under construction — being edited, not published yet.")
                    }
                }
                if tabDomains {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: Self.height(showingDomains: tabDomains))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                shape.fill(Color.primary.opacity(0.02))
                    .timGlass(in: shape, interactive: true)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            } else {
                shape.fill(Color.primary.opacity(hovering ? 0.075 : 0.04))
            }
        }
        .contentShape(shape)
        .scaleEffect(isDragging ? 1.03 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: 9, y: 4)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: togglePin)
            Divider()
            Button("Close Tab", action: close)
            Button("Close Other Tabs", action: closeOthers)
        }
    }

    // Pinned tabs trade the hover ✕ for the pin itself (click to unpin) —
    // pinning means "don't let me close this casually."
    @ViewBuilder private var trailing: some View {
        if tab.isLoading {
            ProgressView().controlSize(.small).scaleEffect(0.55)
        } else if tab.isPinned {
            Button(action: togglePin) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Unpin")
        } else if hovering {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close Tab")
        }
    }
}

struct NewTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("New Tab", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
            VStack(alignment: .leading, spacing: 12) {
                Divider().padding(.vertical, 10)
                HStack(spacing: 6) {
                    // The yellow again: this site is yours.
                    Circle()
                        .fill(timYellow)
                        .frame(width: 8, height: 8)
                        .shadow(color: timYellow.opacity(0.5), radius: 2)
                    Text(site.name.isEmpty ? site.origin : site.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .id(thumbTick)

                ForEach(pages) { page in
                    VStack(alignment: .leading, spacing: 4) {
                        // Two renditions, side by side — each is a door
                        // into that page in that mode.
                        HStack(spacing: 6) {
                            pageThumb(page, mobile: false)
                            pageThumb(page, mobile: true)
                        }
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

    /// One page, one device: the desktop or phone rendition, and a click
    /// takes you into that page IN that mode.
    private func pageThumb(_ page: LinkOption, mobile: Bool) -> some View {
        let fullURL = site.map { $0.origin + page.href } ?? page.href
        let key = mobile ? MobileThumbs.key(fullURL) : fullURL
        let isCurrent = page.href == currentRel && tab.isMobilePreview == mobile
        return Button {
            if tab.isMobilePreview != mobile { tab.setMobilePreview(mobile) }
            if page.href != currentRel { tab.navigate(to: fullURL) }
        } label: {
            Group {
                if let thumb = ThumbnailStore.image(for: key) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.05))
                        Image(systemName: mobile ? "iphone" : "desktopcomputer")
                            .font(.system(size: mobile ? 12 : 16))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .frame(maxWidth: mobile ? 46 : .infinity)
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isCurrent ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isCurrent ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mobile ? "\(page.label) on iPhone" : "\(page.label) on desktop")
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
                // Backfill phone renditions for pages that lack one.
                for page in loadedPages {
                    MobileThumbs.shared.capture(site.origin + page.href, onlyIfMissing: true)
                }
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
                        _ = try CloudflarePublisher.publish(site: s, folder: s.localProjectPath)
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
                    _ = try CloudflarePublisher.publish(site: s, folder: s.localProjectPath)
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

/// The Both view's phone: a live second rendering beside the desktop
/// one. While editing it mirrors the canvas (the serialized DOM, drafts
/// and all, refreshed as it changes); while browsing it simply loads the
/// page as an iPhone would.
final class MobilePreviewModel: ObservableObject {
    let webView: WKWebView
    var lastHash: Int = 0
    var lastURL: String = ""

    init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    }
}

struct MobilePreviewPane: View {
    @ObservedObject var tab: Tab
    let pageURL: URL?
    @StateObject private var model = MobilePreviewModel()

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "iphone")
                        .font(.system(size: 10))
                    Text("iPhone")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                WebViewContainer(webView: model.webView)
                    .frame(minWidth: 0, idealWidth: 375, maxWidth: 375)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                    .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 0, idealWidth: 420, maxWidth: 420)
        .onAppear { sync() }
        .onChange(of: tab.urlString) { _, _ in
            model.lastURL = ""
            model.lastHash = 0
            sync()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            sync()
        }
    }

    private func sync() {
        guard let url = pageURL else { return }
        if tab.isEditing {
            tab.currentHTML { html in
                guard let html else { return }
                let hash = html.hashValue
                if hash != model.lastHash {
                    model.lastHash = hash
                    model.lastURL = ""
                    model.webView.loadHTMLString(html, baseURL: url)
                }
            }
        } else if model.lastURL != url.absoluteString {
            model.lastURL = url.absoluteString
            model.lastHash = 0
            model.webView.load(URLRequest(url: url))
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
    @State private var viewMode: Int = 0  // 0 desktop · 1 both · 2 iPhone
    @State private var showImportSheet = false
    @State private var showShowcaseSheet = false
    @State private var moveSite: Site?
    @FocusState private var addressFocused: Bool
    @AppStorage("tim.cleanAddresses") private var cleanAddresses = true
    @AppStorage("tim.experimental.makeItMine") private var makeItMineEnabled = false

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

    /// Tim's signature: a thin yellow frame on the page's own edge when
    /// the page is yours, a touch stronger while you're editing it.
    private var ownershipLine: some View {
        ZStack {
            // Editable: the thin yellow line. Editing: the site is under
            // construction — caution tape on the page's edge.
            Rectangle()
                .strokeBorder(timYellow.opacity(0.85), lineWidth: isPageEditable && !tab.isEditing ? 1.5 : 0)
            CautionTape()
                .mask(Rectangle().strokeBorder(lineWidth: 5))
                .opacity(tab.isEditing ? 1 : 0)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: isPageEditable)
        .animation(.easeInOut(duration: 0.3), value: tab.isEditing)
    }

    /// The page fills its pane, Safari-style — no gutter, no drawn card.
    /// Phone view is the exception: a device preview deserves to look
    /// like a device sitting on the window's surface.
    @ViewBuilder private var pageArea: some View {
        if tab.isMobilePreview {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                // Editing widens the frame onto the pasteboard — the page
                // itself stays a true 390; the rest is where off-page
                // objects live in plain sight.
                // Ideal, not fixed: a hard width here is a hard MINIMUM to
                // the split view, and sidebar + inspector + 680 can't fit a
                // 900-point window — AppKit looped on constraints and the
                // app aborted at launch. The page inside stays a true 390
                // by CSS; only pasteboard room gives way when space is tight.
                WebViewContainer(webView: tab.webView)
                    .frame(minWidth: 0, idealWidth: tab.isEditing ? 680 : 390, maxWidth: tab.isEditing ? 680 : 390)
                    .clipShape(shape)
                    .overlay(
                        ZStack {
                            shape.strokeBorder(
                                isPageEditable ? AnyShapeStyle(timYellow.opacity(0.85))
                                               : AnyShapeStyle(Color.primary.opacity(0.15)),
                                lineWidth: isPageEditable ? 1.5 : 1
                            )
                            .opacity(tab.isEditing ? 0 : 1)
                            CautionTape()
                                .mask(shape.strokeBorder(lineWidth: 5))
                                .opacity(tab.isEditing ? 1 : 0)
                        }
                        .allowsHitTesting(false)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
                    .padding(.vertical, 16)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
        } else if viewMode == 1 {
            HStack(spacing: 0) {
                WebViewContainer(webView: tab.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(ownershipLine)
                Divider()
                MobilePreviewPane(tab: tab, pageURL: pageURL)
            }
        } else {
            WebViewContainer(webView: tab.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(ownershipLine)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tab.isEditing {
                // Preview's markup bar: the format row belongs to the
                // editing mode, and arrives as one coordinated motion
                // with the inspector — a single spring, no two-stage
                // jump, nothing sliding across the page.
                EditingToolbar(
                    tab: tab,
                    site: matchedSite,
                    publish: { showPublishSheet = true },
                    connect: { showConnectSheet = true }
                )
                Divider()
            }
            pageArea
        }
        // The system inspector: AppKit owns the column, so the page can
        // never starve it (the hand-rolled row did exactly that), and the
        // pane wears the window's own material instead of a drawn card.
        .inspector(isPresented: Binding(
            get: { tab.isEditing || previewSha != nil },
            set: { _ in }
        )) {
            Group {
                if previewSha != nil {
                    VersionPreviewPane(
                        dateLabel: previewLabel,
                        onRestore: { restorePreviewedVersion() },
                        onRestoreAsNew: { restorePreviewAsNewPage() },
                        onCancel: { exitVersionPreview() }
                    )
                } else {
                    InspectorView(
                        tab: tab,
                        site: matchedSite,
                        allowsTemplates: matchedSite != nil
                            && !(matchedSite.map { AstroProject.isAstroProject($0.localProjectPath) } ?? false)
                    )
                }
            }
            .transaction { $0.animation = nil }
            // One width, full stop. A min/ideal/max range let the column
            // renegotiate every time the selection changed and the Form's
            // intrinsic width moved — the "randomly resizing" sidebar.
            // (Only the column width is pinned: a fixed .frame on the
            // content as well made the split view's min/max size flip
            // during a constraint pass — an AppKit exception and a crash.)
            .inspectorColumnWidth(min: 280, ideal: 300, max: 320)
        }
        .navigationTitle("")
        // The toolbar wears the sidebar's material — one piece of chrome.
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        // The toolbar hangs off an EQUATABLE anchor: its content is only
        // re-supplied when something the toolbar actually renders from
        // changes. A window re-evaluation caused by loading progress (a
        // page whose trackers never settle) used to re-supply the toolbar
        // and rebuild the address field mid-keystroke.
        .background(ToolbarAnchor(key: toolbarKey) { toolbarContent }.equatable())
        .onAppear {
            // Your own pages always load fresh — never a stale cached copy
            // of something you just published.
            tab.cacheBypass = { url in siteStore.match(url) != nil }
            addressText = tab.urlString
            if tab.urlString.isEmpty {
                // A new tab puts the cursor in the address field, the way
                // every browser does.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    addressFocused = true
                }
            }
        }
        .onChange(of: tab.urlString) { _, newValue in
            if !addressFocused { addressText = newValue }
            previewSha = nil
        }
        // The inspector is a system inspector column: glass, resizable,
        // width managed by the OS — no homemade pane, no reflow jumps.
        .onDisappear {
            // Switching tabs closes the edit session: the draft is
            // stashed silently, the page keeps showing your changes, and
            // Edit picks up exactly where you left off. One page in edit
            // mode at a time — the multi-tab edit tangle wasn't worth it.
            if tab.isEditing {
                let url = tab.webView.url
                tab.currentHTML { html in
                    if let html, let url { DraftStore.save(html, for: url.absoluteString) }
                    tab.setEditing(false)
                }
            }
        }
        .sheet(isPresented: $showShowcaseSheet) {
            ShowcaseSheet(tab: tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .timSubmitShowcase)) { _ in
            if store.selectedTab === tab { showShowcaseSheet = true }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(tab: tab)
        }
        .onChange(of: tab.isLoading) { _, loading in
            // Thumbnails fall out of browsing: snapshot owned pages on
            // load — filed under the rendition the tab is showing, so a
            // phone visit refreshes the phone thumb, never the desktop one.
            guard !loading, let url = tab.webView.url, matchedSite != nil else { return }
            let mobile = tab.isMobilePreview
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = mobile ? 160 : 280
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard tab.isMobilePreview == mobile, tab.webView.url == url else { return }
                tab.webView.takeSnapshot(with: config) { image, _ in
                    if let image {
                        ThumbnailStore.save(image, for: mobile ? MobileThumbs.key(url.absoluteString) : url.absoluteString)
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
        .onReceive(NotificationCenter.default.publisher(for: .timMovePage)) { _ in
            if store.selectedTab === tab, let s = siteStore.match(pageURL), s.target == .sftp || s.target == .cloudflare || s.target == .githubPages {
                moveSite = ensureWorkspace(s)
            }
        }
        .sheet(item: $moveSite) { s in
            MovePageSheet(tab: tab, site: s)
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
            if tab.isEditing { tab.refreshReviewCounts() }
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

    // MARK: The address capsule — the toolbar's centerpiece. Familiar
    // (a centered Safari-style field) but Tim's own: the host reads
    // strong with the path quiet, a page you own wears a soft accent
    // glow and a pencil, loading draws a hairline of progress along the
    // capsule's floor, and reload lives inside where your eye already is.

    private var prettyAddress: (host: String, path: String)? {
        // Safari's manner: the address reads as a name at rest — scheme
        // and www only appear when the field is focused for editing.
        guard cleanAddresses, !addressFocused,
              let url = URL(string: tab.urlString),
              let host = url.host()
        else { return nil }
        let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = url.path
        if path == "/" || path.isEmpty { path = "" }
        return (cleanHost, path)
    }

    private var addressCapsule: some View {
        AddressBar(tab: tab, onCreate: { createMissingPage() }, onClaim: { showImportSheet = true })
    }

    /// Entering edit mode materializes a derived site (a Tim page on a
    /// server we can write to, but outside every explicit connection):
    /// it's saved as a real connection and its mirror starts downloading
    /// while you edit, so Done has the full site to restamp against.
    /// Entering and leaving edit mode changes the window's whole shape —
    /// format bar in, inspector out, page resized. Animating that means
    /// the web view relayouts on every frame of the animation, which is
    /// exactly the jumpiness and tearing you see. One crisp frame beats
    /// a janky quarter-second.
    private func withoutMotion(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private func beginEditing() {
        if let matched = matchedSite { _ = ensureWorkspace(matched) }
        withoutMotion { tab.setEditing(true) }
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
        guard let url = tab.webView.url else { withoutMotion { tab.setEditing(false) }; return }

        if isPlainLocalPage {
            withoutMotion { tab.setEditing(false) }
            ensureAutoSocialCard {
                savePlainLocalPage {
                    PageRegistry.record(url: url.absoluteString, title: tab.title)
                    captureThumbnailSoon()
                }
            }
            return
        }

        guard let matched = matchedSite else { withoutMotion { tab.setEditing(false) }; return }
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
                                _ = try CloudflarePublisher.publish(site: site, folder: dist)
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

        // Plain site page: Done captures the page this instant, then
        // publishes in the background — navigate anywhere, the save is
        // already in hand. The toolbar spinner shows it landing.
        tab.currentHTML { captured in
            tab.setEditing(false)
            // The 3-second draft is the fallback if capture raced a navigation.
            guard let raw = captured ?? DraftStore.html(for: url.absoluteString) else { return }
            let rel = site.relativePagePath(for: url)
            let html = MobileCSS.regenerate(in: Self.ensuringAutoSocialMeta(in: raw, rel: rel, site: site))
            let publishing = ActivityCenter.shared.begin("Publishing \((rel as NSString).lastPathComponent)…")
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
                    // Site icons reach every page (except those keeping
                    // their own) the same way components do — on Done.
                    let iconStamped = PageComponents.PageIcons.stampAll(
                        in: site.localProjectPath,
                        favicon: manifest.siteFavicon, touchIcon: manifest.siteTouchIcon,
                        excludingRel: String(rel.dropFirst())
                    )
                    restamped = Array(Set(restamped + iconStamped))
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
                        _ = try CloudflarePublisher.publish(site: site, folder: site.localProjectPath)
                    case .githubPages:
                        _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Edit \(rel) with Tim")
                    }
                    SiteWorkspace.snapshot(site.localProjectPath, message: "Edit \(rel)")
                    DispatchQueue.main.async {
                        ActivityCenter.shared.end(publishing)
                        DraftStore.clear(for: url.absoluteString)
                        PageRegistry.record(url: url.absoluteString, title: tab.title)
                        captureThumbnailSoon(expecting: url)
                        // The share card, from the page just published —
                        // offscreen, mobile-bold, and never skipped.
                        SocialCards.shared.capture(pageURL: url, site: site, pageHTML: html)
                    }
                } catch {
                    DispatchQueue.main.async {
                        ActivityCenter.shared.end(publishing)
                        publishAlert(error)
                    }
                }
            }
        }
    }

    /// The auto share card's meta tags, ensured in the captured HTML — the
    /// card's filename is deterministic (social-<page>.png), so the tags
    /// can be written before the image itself lands. A custom image (any
    /// other filename) is theirs and stays untouched.
    // Shared with the iPad now — see TimKit/PageMeta.swift.
    static func ensuringAutoSocialMeta(in html: String, rel: String, site: Site) -> String {
        PageMeta.ensureAutoSocial(in: html, rel: rel, site: site)
    }

    static func metaContent(in html: String, property: String) -> String? {
        PageMeta.content(in: html, property: property)
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
        let activity = ActivityCenter.shared.begin("Restoring \((rel as NSString).lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { ActivityCenter.shared.end(activity) }
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
                    _ = try CloudflarePublisher.publish(site: site, folder: site.localProjectPath)
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

    /// The sidebar thumbnail should show what you just saved. When a save
    /// finishes after the tab moved on, `expecting` keeps a snapshot of
    /// the wrong page from being filed under the right one.
    private func captureThumbnailSoon(expecting: URL? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let url = tab.webView.url, expecting == nil || url == expecting else { return }
            // In phone view, the live snapshot belongs to the phone thumb;
            // the offscreen factory keeps the desktop one honest instead.
            if tab.isMobilePreview {
                let config = WKSnapshotConfiguration()
                config.snapshotWidth = 160
                tab.webView.takeSnapshot(with: config) { image, _ in
                    if let image {
                        ThumbnailStore.save(image, for: MobileThumbs.key(url.absoluteString))
                        NotificationCenter.default.post(name: .timThumbsUpdated, object: nil)
                    }
                }
                return
            }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 280
            tab.webView.takeSnapshot(with: config) { image, _ in
                if let image {
                    ThumbnailStore.save(image, for: url.absoluteString)
                    MobileThumbs.shared.capture(url.absoluteString)
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
                    _ = try CloudflarePublisher.publish(site: site, folder: site.localProjectPath)
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
        alert.messageText = "Couldn’t Publish"
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
        let activity = ActivityCenter.shared.begin("Downloading \(site.name.isEmpty ? site.origin : site.name)…")
        DispatchQueue.global(qos: .utility).async {
            _ = try? SFTP.downloadDirectory(
                remoteRoot: site.remoteRoot, to: site.localProjectPath,
                host: site.host, username: site.username, port: site.port
            )
            SiteWorkspace.snapshot(site.localProjectPath, message: "Connected \(site.name)")
            DispatchQueue.main.async {
                ActivityCenter.shared.end(activity)
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
        let html = LocalPage.html(
            title: name == "index" ? (site.name.isEmpty ? "Home" : site.name) : name.capitalized,
            likeSiteAt: site.localProjectPath
        )
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PageWriter.write(html: html, folder: site.localProjectPath, relativePath: rel)
                switch site.target {
                case .sftp:
                    let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                    _ = try SFTP.upload(html: html, to: root + rel, host: site.host, username: site.username, port: site.port)
                case .cloudflare:
                    _ = try CloudflarePublisher.publish(site: site, folder: site.localProjectPath)
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
                        _ = try CloudflarePublisher.publish(site: site, folder: site.localProjectPath)
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

    /// Everything the toolbar's appearance depends on. Loading state is
    /// deliberately absent: the address bar observes that itself.
    private var toolbarKey: ToolbarKey {
        ToolbarKey(
            isEditing: tab.isEditing, isMobilePreview: tab.isMobilePreview, viewMode: viewMode,
            previewing: previewSha != nil, editable: isPageEditable,
            canBack: tab.canGoBack, canForward: tab.canGoForward,
            reviewDesktop: tab.reviewDesktop, reviewMobile: tab.reviewMobile,
            matchedSite: matchedSite?.id, siteIDs: siteStore.sites.map(\.id),
            tabID: tab.id, url: tab.urlString
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Button { tab.webView.goBack() } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .disabled(!tab.canGoBack)
                    .help("Back (⌘[)")
                    Button { tab.webView.goForward() } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .disabled(!tab.canGoForward)
                    .help("Forward (⌘])")
                }
                addressCapsule
                    .frame(minWidth: 280, idealWidth: 470, maxWidth: 560)
                    // macOS wraps the principal item in its own glass pill; our
                    // capsule ended flush against it on the right while the
                    // top and bottom kept the container's inset. Match it.
                    .padding(.trailing, 3)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("", selection: $viewMode) {
                Image(systemName: "desktopcomputer").tag(0)
                Image(systemName: "square.split.2x1").tag(1)
                Image(systemName: "iphone").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: viewMode) { _, mode in
                let wantsMobile = mode == 2
                if tab.isMobilePreview != wantsMobile { tab.setMobilePreview(wantsMobile) }
            }
            .onChange(of: tab.isMobilePreview) { _, mobile in
                if mobile { viewMode = 2 } else if viewMode == 2 { viewMode = 0 }
            }
            .help("Desktop, both side by side, or iPhone — same content, all of it must be excellent")
            .overlay(alignment: tab.isMobilePreview ? .topLeading : .topTrailing) {
                // The other layout has objects whose placement was guessed —
                // the dot sits on the side that wants a look.
                let pending = tab.isMobilePreview ? tab.reviewDesktop : tab.reviewMobile
                if tab.isEditing, pending > 0 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .offset(x: tab.isMobilePreview ? -3 : 3, y: -3)
                        .help(tab.isMobilePreview
                              ? "\(pending) object\(pending == 1 ? "" : "s") to review on desktop — flip over and they'll be outlined."
                              : "\(pending) object\(pending == 1 ? "" : "s") to review on iPhone — flip over and they'll be outlined.")
                        .allowsHitTesting(false)
                }
            }

            // Share — open in your default browser (the hero), copy, or
            // the system share sheet. Always present; disabled off-web.
            Menu {
                Button {
                    if let url = URL(string: tab.urlString) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open in Default Browser", systemImage: "safari")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.urlString, forType: .string)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                Divider()
                if let url = URL(string: tab.urlString) {
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(URL(string: tab.urlString)?.scheme?.hasPrefix("http") != true)
            .help("Open in your default browser, copy the link, or share")

            ActivityIndicator()

            // Fixed slots — the toolbar is the toolbar. Undo and redo are
            // always here (Keynote keeps them too), disabled outside an
            // edit session; Edit and Done share one slot. Each is its own
            // toolbar item: wrapping them in a stack made macOS render
            // the cluster as one prominent blob.
            Button {
                tab.undoEdit()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!tab.isEditing)
            .help("Undo (⌘Z)")

            Button {
                tab.redoEdit()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!tab.isEditing)
            .help("Redo (⇧⌘Z)")

            // The one button that IS Tim: brand yellow, with the pencil
            // that marks everything you own. It carries the most weight
            // in the toolbar because it's the whole point of the app.
            Button {
                if tab.isEditing { finishEditing() } else { beginEditing() }
            } label: {
                Label(tab.isEditing ? "Done" : "Edit",
                      systemImage: tab.isEditing ? "checkmark" : "pencil")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(timYellow)
            .disabled(!tab.isEditing && (!isPageEditable || previewSha != nil))
            .help(tab.isEditing ? "Done (⌘E) — your changes are saved" : "Edit This Page (⌘E)")

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
        // The strip must be able to get NARROWER than its buttons: a row of
        // fixed-size controls is a hard minimum to the window's split view,
        // and at the window's minimum width (sidebar + inspector + this)
        // AppKit could not settle its constraints and the app aborted at
        // launch. Scrolling sideways when cramped costs nothing.
        ScrollView(.horizontal, showsIndicators: false) {
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
                    Button {
                        var items: [NavKit.Item] = []
                        if let site {
                            items = LinkSources.pages(for: site).prefix(6).map { NavKit.Item(label: $0.label, href: site.origin + $0.href) }
                        }
                        if items.isEmpty { items = [NavKit.Item(label: "Home", href: "/")] }
                        tab.insertObject(html: NavKit.markup(items: items), colSpan: 24, rowSpan: 1)
                    } label: {
                        Label("Navigation", systemImage: "list.bullet.rectangle")
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

            Spacer()

            // One quiet status slot — no chatty hints that truncate, no
            // labels that come and go and shove the row around.
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
        }
        .padding(.horizontal, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .controlSize(.small)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            // The editing strip carries the ownership color, quietly.
            Rectangle().fill(timYellow.opacity(0.55)).frame(height: 1)
        }
        .sheet(isPresented: $showNewPageSheet) {
            NewPageSheet(site: site, tab: tab)
        }
        .sheet(item: $navBuilderSite) { navSite in
            NavBuilderSheet(site: navSite, tab: tab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .timEditNav)) { _ in
            if let site, tab.isEditing { navBuilderSite = site }
        }
        .onAppear { registerFileDrops() }
        .onDisappear { unregisterFileDrops() }
        .onReceive(NotificationCenter.default.publisher(for: .timUpscaleMedia)) { note in
            if let src = note.userInfo?["src"] as? String { upscaleSelectedMedia(src: src) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timReplaceMedia)) { _ in
            if tab.isEditing { replaceSelectedMedia() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timBounceVideo)) { _ in
            if tab.isEditing { bounceSelectedVideo() }
        }
    }

    /// Bounce is baked, not simulated: the video's forward+reverse
    /// rendition is generated once (reused thereafter), uploaded, and the
    /// element points at it — a plain looping video that bounces in every
    /// browser with zero runtime tricks.
    private func bounceSelectedVideo() {
        guard let info = tab.selectionInfo,
              let video = info["video"] as? [String: Any],
              let src = video["src"] as? String, !src.isEmpty,
              (video["bounce"] as? Int) != 1
        else { return }
        guard let s = site, !s.localProjectPath.isEmpty else {
            statusMessage = "Bounce needs a connected site."
            return
        }
        let fileName = (src as NSString).lastPathComponent
        let bounceName = ((fileName as NSString).deletingPathExtension) + "-bounce.mp4"
        let bounceSrc = ((src as NSString).deletingLastPathComponent as NSString).appendingPathComponent(bounceName)
        let mirrorFile = (s.localProjectPath as NSString).appendingPathComponent("media/" + fileName)
        let mirrorBounce = (s.localProjectPath as NSString).appendingPathComponent("media/" + bounceName)
        isWorking = true
        statusMessage = "Making \(fileName) bounce…"
        DispatchQueue.global(qos: .userInitiated).async {
            var activity = ActivityCenter.shared.begin("Making \(fileName) bounce…")
            do {
                if !FileManager.default.fileExists(atPath: mirrorBounce) {
                    guard FileManager.default.fileExists(atPath: mirrorFile) else {
                        throw MediaOptimizer.OptimizeError.failed("The video isn't in this site's local copy yet.")
                    }
                    let built = try MediaOptimizer.bounceVideo(URL(fileURLWithPath: mirrorFile))
                    try? FileManager.default.removeItem(atPath: mirrorBounce)
                    try FileManager.default.copyItem(atPath: built.path, toPath: mirrorBounce)
                }
                ActivityCenter.shared.end(activity)
                activity = ActivityCenter.shared.begin("Uploading \(bounceName)…")
                try Self.uploadStagedMedia(site: s, name: bounceName)
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    isWorking = false
                    statusMessage = nil
                    tab.setVideoBounceSrc(bounceSrc)
                }
            } catch {
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    isWorking = false
                    statusMessage = "Couldn’t make it bounce: \(error.localizedDescription)"
                }
            }
        }
    }

    /// One Media command: pick any file — images, video, and audio embed
    /// as their native elements; anything else becomes a linked file. The
    /// file lands in the site's mirror (media/) and is pushed to the
    /// site's target, or saved beside a local page.
    private func insertMedia() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { insertMediaFile(url, at: nil) }
    }

    /// Files dragged from the Finder land where they're dropped. Several
    /// at once stagger down the page so none hides another.
    private func registerFileDrops() {
        guard let view = tab.webView as? TimWebView else { return }
        view.fileDropHover = { point in tab.showDropHover(at: point) }
        view.fileDrop = { urls, point in
            guard tab.isEditing else { return false }
            for (i, url) in urls.enumerated() {
                insertMediaFile(url, at: CGPoint(x: point.x, y: point.y + CGFloat(i) * 40))
            }
            return true
        }
    }
    private func unregisterFileDrops() {
        guard let view = tab.webView as? TimWebView else { return }
        view.fileDrop = nil
        view.fileDropHover = nil
    }

    private func insertMediaFile(_ fileURL: URL, at point: CGPoint?) {
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
        let placeholderID = UUID().uuidString
        isWorking = true
        statusMessage = "Adding \(name)…"

        // The placeholder appears this instant — optimizing and uploading
        // can take a while, and the canvas should say so, beautifully.
        let spans = Self.mediaSpans(for: kind)
        tab.insertObject(
            html: Self.placeholderHTML(id: placeholderID, label: "Adding \(name)…"),
            colSpan: spans.cols, rowSpan: spans.rows, at: point
        )
        DispatchQueue.global(qos: .userInitiated).async {
            var activity = ActivityCenter.shared.begin("Adding \(name)…")
            do {
                // Web-appropriate, no questions asked: heavyweight files
                // convert automatically; the original stays in the mirror.
                var publishURL = fileURL
                if case .transcode = MediaOptimizer.plan(fileURL: fileURL, kind: kind) {
                    ActivityCenter.shared.end(activity)
                    activity = ActivityCenter.shared.begin("Optimizing \(name) for the web…")
                    DispatchQueue.main.async { statusMessage = "Optimizing \(name)…" }
                    publishURL = try MediaOptimizer.transcode(fileURL: fileURL, kind: kind)
                    if let s = resolvedSite { MediaOptimizer.stashOriginal(fileURL, mirror: s.localProjectPath) }
                }
                let publishName = publishURL.lastPathComponent
                var src = try Self.stage(fileURL: publishURL, site: resolvedSite, pageURL: pageURL, upload: false)
                // Relative to the current page, so it works under any base
                // path, on file:// previews, and on the live site alike.
                if let resolvedSite, let pageURL {
                    let rel = resolvedSite.relativePagePath(for: pageURL)
                    let depth = max(0, rel.split(separator: "/").count - 1)
                    src = String(repeating: "../", count: depth) + src
                }
                ActivityCenter.shared.end(activity)
                activity = ActivityCenter.shared.begin("Uploading \(publishName)…")
                DispatchQueue.main.async { statusMessage = "Uploading \(publishName)…" }
                try Self.uploadStagedMedia(site: resolvedSite, name: publishName)
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    isWorking = false
                    statusMessage = nil
                    tab.resolvePlaceholder(id: placeholderID, html: Self.mediaHTML(kind: kind, src: src, name: publishName))
                }
            } catch {
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    isWorking = false
                    statusMessage = "Couldn’t add \(name): \(error.localizedDescription)"
                    tab.failPlaceholder(id: placeholderID, message: "Couldn’t add \(name)")
                }
            }
        }
    }

    /// Replace the selected media in place: pick a new file, keep the
    /// element's placement, size, and styling. The old media stays visible
    /// until the new upload lands.
    private func replaceSelectedMedia() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        replaceSelectedMedia(with: fileURL)
    }

    /// Enlarge the selected image 2× and swap it in. The source is the
    /// mirror's copy when there is one, else the live file.
    private func upscaleSelectedMedia(src: String) {
        guard let pageURL = tab.webView.url, let absolute = URL(string: src, relativeTo: pageURL)?.absoluteURL else { return }
        var local: URL?
        if let site, !site.localProjectPath.isEmpty {
            let name = absolute.lastPathComponent
            let candidate = URL(fileURLWithPath: site.localProjectPath).appendingPathComponent("media").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { local = candidate }
        }
        if local == nil, absolute.isFileURL { local = absolute }
        isWorking = true
        statusMessage = "Enlarging \(absolute.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let activity = ActivityCenter.shared.begin("Enlarging \(absolute.lastPathComponent)…")
            do {
                var source = local
                if source == nil {
                    let (data, _) = try URLSession.shared.syncData(from: absolute)
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(absolute.lastPathComponent)
                    try data.write(to: tmp)
                    source = tmp
                }
                let bigger = try Upscaler.enlarge(source!, factor: 2)
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    isWorking = false
                    statusMessage = nil
                    replaceSelectedMedia(with: bigger)
                }
            } catch {
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    isWorking = false
                    statusMessage = "Couldn’t enlarge: \(error.localizedDescription)"
                }
            }
        }
    }

    private func replaceSelectedMedia(with fileURL: URL) {
        let name = fileURL.lastPathComponent
        let kind = MediaKind.of(fileExtension: fileURL.pathExtension)
        guard kind != .file else {
            statusMessage = "That's not a media file — use Insert → Media… to link files."
            return
        }
        let replaceID = UUID().uuidString
        tab.markSelectedMedia(id: replaceID) { marked in
            guard marked else {
                statusMessage = "Select an image, video, or audio object first."
                return
            }
            let resolvedSite = site
            let pageURL = tab.webView.url
            isWorking = true
            statusMessage = "Adding \(name)…"
            DispatchQueue.global(qos: .userInitiated).async {
                var activity = ActivityCenter.shared.begin("Adding \(name)…")
                do {
                    var publishURL = fileURL
                    if case .transcode = MediaOptimizer.plan(fileURL: fileURL, kind: kind) {
                        ActivityCenter.shared.end(activity)
                        activity = ActivityCenter.shared.begin("Optimizing \(name) for the web…")
                        DispatchQueue.main.async { statusMessage = "Optimizing \(name)…" }
                        publishURL = try MediaOptimizer.transcode(fileURL: fileURL, kind: kind)
                        if let s = resolvedSite { MediaOptimizer.stashOriginal(fileURL, mirror: s.localProjectPath) }
                    }
                    let publishName = publishURL.lastPathComponent
                    var src = try Self.stage(fileURL: publishURL, site: resolvedSite, pageURL: pageURL, upload: false)
                    if let resolvedSite, let pageURL {
                        let rel = resolvedSite.relativePagePath(for: pageURL)
                        let depth = max(0, rel.split(separator: "/").count - 1)
                        src = String(repeating: "../", count: depth) + src
                    }
                    ActivityCenter.shared.end(activity)
                    activity = ActivityCenter.shared.begin("Uploading \(publishName)…")
                    DispatchQueue.main.async { statusMessage = "Uploading \(publishName)…" }
                    try Self.uploadStagedMedia(site: resolvedSite, name: publishName)
                    DispatchQueue.main.async {
                        ActivityCenter.shared.end(activity)
                        isWorking = false
                        statusMessage = nil
                        tab.replaceMedia(id: replaceID, html: Self.mediaHTML(kind: kind, src: src, name: publishName))
                    }
                } catch {
                    DispatchQueue.main.async {
                        ActivityCenter.shared.end(activity)
                        isWorking = false
                        statusMessage = "Couldn’t replace with \(name): \(error.localizedDescription)"
                        tab.unmarkMedia(id: replaceID)
                    }
                }
            }
        }
    }

    static func mediaSpans(for kind: MediaKind) -> (cols: Int, rows: Int) {
        switch kind {
        case .image: return (8, 8)
        case .video: return (12, 8)
        case .audio: return (8, 2)
        case .file: return (6, 2)
        }
    }

    static func placeholderHTML(id: String, label: String) -> String {
        let escaped = label
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return "<div class=\"tim-object tim-media-loading\" data-tim-placeholder=\"\(id)\"><span class=\"tim-media-loading-label\">\(escaped)</span></div>"
    }

    static func stage(fileURL: URL, site: Site?, pageURL: URL?, upload: Bool = true) throws -> String {
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
            if upload { try uploadStagedMedia(site: site, name: name) }
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

    /// The slow half of staging: pushes an already-mirrored media file to
    /// the site's target. No-op for local pages.
    static func uploadStagedMedia(site: Site?, name: String) throws {
        guard let site, !site.localProjectPath.isEmpty,
              !AstroProject.isAstroProject(site.localProjectPath) else { return }
        switch site.target {
        case .sftp:
            let dest = ((site.localProjectPath as NSString).appendingPathComponent("media") as NSString).appendingPathComponent(name)
            let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
            _ = try SFTP.uploadFile(
                localPath: dest, toDirectory: root.isEmpty ? "media" : root + "/media", named: name,
                host: site.host, username: site.username, port: site.port
            )
        case .cloudflare:
            _ = try CloudflarePublisher.publish(site: site, folder: site.localProjectPath)
        case .githubPages:
            _ = try GitHubPagesPublisher.publish(repo: site.localProjectPath, message: "Add media \(name)")
        }
    }

    static func mediaHTML(kind: MediaKind, src: String, name: String) -> String {
        switch kind {
        case .image:
            return #"<img class="tim-object" src="\#(src)" alt="" />"#
        case .video:
            return #"<video class="tim-object" controls playsinline src="\#(src)"></video>"#
        case .audio:
            return #"<audio class="tim-object" controls src="\#(src)"></audio>"#
        case .file:
            return "<div class=\"tim-object tim-text tim-style-body\"><a href=\"\(src)\">\(name)</a></div>"
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
                    let html = LocalPage.html(
                        title: pageTitle.isEmpty ? pageSlug : pageTitle,
                        likeSiteAt: workingSite.localProjectPath
                    )
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
                        _ = try CloudflarePublisher.publish(site: workingSite, folder: workingSite.localProjectPath)
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
        case .cloudflare: return CloudflareAPI.token != nil || !site.cfProjectName.isEmpty
        case .githubPages: return !site.localProjectPath.isEmpty
        }
    }

    private var canPublish: Bool {
        if isAstro { return deployAfterBuild ? targetConfigured : true }
        switch target {
        case .sftp:
            return !host.isEmpty && !username.isEmpty && !remotePath.isEmpty
        case .cloudflare:
            return CloudflareAPI.token != nil
                || (site?.localProjectPath.isEmpty == false && site?.cfProjectName.isEmpty == false)
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
                    return try CloudflarePublisher.publish(site: site, folder: site.localProjectPath)
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
                            _ = try CloudflarePublisher.publish(site: site, folder: dist)
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
    @State private var cfConnected = CloudflareAPI.token != nil
    @State private var cfTokenDraft = ""
    @State private var cfStatus: String?

    private func connectCloudflare() {
        let candidate = cfTokenDraft.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return }
        cfStatus = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let status = try CloudflareAPI.verify(candidate)
                DispatchQueue.main.async {
                    if status == "active" {
                        CloudflareAPI.storeToken(candidate)
                        cfConnected = true
                        cfTokenDraft = ""
                        cfStatus = "Connected — Tim takes it from here."
                    } else {
                        cfStatus = "Token is \(status) — check it on the Cloudflare dashboard."
                    }
                }
            } catch {
                DispatchQueue.main.async { cfStatus = error.localizedDescription }
            }
        }
    }

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
                        Text("Cloudflare")
                        if cfConnected {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Connected")
                                    .font(.system(size: 12))
                                Spacer()
                                Button("Disconnect") {
                                    CloudflareAPI.storeToken("")
                                    cfConnected = false
                                }
                                .controlSize(.small)
                            }
                        } else {
                            HStack(spacing: 6) {
                                SecureField("Paste an API token", text: $cfTokenDraft)
                                Button("Connect") { connectCloudflare() }
                                    .disabled(cfTokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                    if !cfConnected {
                        GridRow {
                            Text("")
                            HStack(spacing: 8) {
                                // Cloudflare's token-template deep link:
                                // lands on Create Token with Tim's scopes
                                // pre-filled — Continue, Create, copy, paste.
                                Button("Create Token in Cloudflare…") {
                                    let scopes = """
                                    [{"key":"account_settings","type":"read"},{"key":"workers_scripts","type":"edit"},{"key":"zone","type":"read"},{"key":"workers_routes","type":"edit"}]
                                    """.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                                    let link = "https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=\(scopes)&name=Tim%20Publishing&accountId=all&zoneId=all"
                                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                                }
                                .controlSize(.small)
                                Spacer()
                            }
                        }
                        GridRow {
                            Text("")
                            Text("One token, once — Tim handles the rest. The button opens Cloudflare with the scopes pre-filled (Workers Scripts: Edit, Workers Routes: Edit, Account Settings: Read, Zone: Read); create it, copy, paste here. It lives in your Keychain and syncs via iCloud Keychain.")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let status = cfStatus {
                        GridRow {
                            Text("")
                            Text(status)
                                .font(.system(size: 10))
                                .foregroundStyle(status.hasPrefix("Connected") ? Color.green : Color.red)
                        }
                    }
                    GridRow {
                        Text("")
                        Text("The Address above is where the site lives — any path on a domain in your Cloudflare account (yourdomain.com/anything). Tim creates the Worker, uploads the pages, and wires the route.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GridRow {
                        Text("Worker name")
                        TextField("Optional — auto-named from the address", text: $draft.cfProjectName)
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
                    InspectorControls(tab: tab, site: site, info: info, allowsTemplates: allowsTemplates)
                        .id(info["seq"] as? Int ?? 0)
                } else {
                    PageOptionsPane(tab: tab)
                }
            }
        }
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

/// The inspector's picture of a navigation object — mirrors NavKit's markup.
struct NavModel: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        var label: String
        var href: String
        var depth: Int
        enum CodingKeys: String, CodingKey { case label, href, depth }
    }
    var d = "row", m = "menu", sel = "underline", align = "start", gap = 24, label = "icon"
    var items: [Item] = []

    static func from(_ any: Any?) -> NavModel? {
        guard let dict = any as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(NavModel.self, from: data)
    }
    var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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
    @State private var columnCount: Int = 1
    @State private var rotation: Double = 0
    @State private var showOnMobile: Bool = true
    @State private var fillIsGradient: Bool = false
    @State private var fillEndColor: Color = .blue
    @State private var fillAngle: Double = 180
    @State private var videoAutoplay: Bool = false
    @State private var videoRepeat: String = "none"
    @State private var videoSound: Bool = true
    @State private var videoControls: Bool = true
    @State private var textColor: Color
    @State private var fillColor: Color
    @State private var radius: Double
    @State private var padding: Double
    @State private var margin: Double
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
        let fillRaw = info["fill"] as? String ?? ""
        let fillGradient = parseLinearGradient(fillRaw)
        _fillIsGradient = State(initialValue: fillGradient != nil)
        _fillColor = State(initialValue: Color(cssColor: fillGradient?.start ?? fillRaw, fallback: .clear))
        _fillEndColor = State(initialValue: Color(cssColor: fillGradient?.end ?? "", fallback: .blue))
        _fillAngle = State(initialValue: fillGradient?.angle ?? 180)
        _radius = State(initialValue: info["radius"] as? Double ?? 0)
        _padding = State(initialValue: info["padding"] as? Double ?? 0)
        _margin = State(initialValue: info["margin"] as? Double ?? 0)
        _opacity = State(initialValue: info["opacity"] as? Double ?? 1)
        _hasShadow = State(initialValue: (info["hasShadow"] as? Int) == 1)
        _textShadowOn = State(initialValue: (info["hasTextShadow"] as? Int) == 1)
        _isItalic = State(initialValue: (info["italic"] as? Int) == 1)
        _isUnderlined = State(initialValue: (info["underline"] as? Int) == 1)
        _isStruck = State(initialValue: (info["strike"] as? Int) == 1)
        _capsMode = State(initialValue: info["caps"] as? String ?? "none")
        _columnCount = State(initialValue: min(4, max(1, info["columns"] as? Int ?? 1)))
        _rotation = State(initialValue: info["rotation"] as? Double ?? 0)
        _showOnMobile = State(initialValue: (info["mobileHidden"] as? Int) != 1)
        let video = info["video"] as? [String: Any] ?? [:]
        _videoAutoplay = State(initialValue: (video["autoplay"] as? Int) == 1)
        _videoRepeat = State(initialValue: (video["bounce"] as? Int) == 1
            ? "bounce" : ((video["loop"] as? Int) == 1 ? "loop" : "none"))
        _videoSound = State(initialValue: (video["muted"] as? Int) != 1)
        _videoControls = State(initialValue: (video["controls"] as? Int) == 1)
        _nav = State(initialValue: NavModel.from(info["nav"]))
    }

    @State private var nav: NavModel? = nil
    @EnvironmentObject private var siteStore: SiteStore

    private var isText: Bool {
        (info["isText"] as? Int) == 1
            || ["h1", "h2", "h3", "h4", "h5", "h6", "p", "blockquote", "li"].contains(info["tag"] as? String ?? "")
    }
    private var isMedia: Bool {
        ["img", "video", "audio"].contains(info["tag"] as? String ?? "")
    }

    // MARK: Navigation

    private func pushNav() { if let nav { tab.setNav(nav.json) } }

    private var navPages: [LinkOption] {
        guard let site = siteStore.match(URL(string: tab.urlString)) else { return [] }
        return LinkSources.pages(for: site).map { LinkOption(label: $0.label, href: site.origin + $0.href) }
    }

    private func layoutPicker(_ title: String, _ value: Binding<String>) -> some View {
        HStack {
            rowLabel(title)
            Picker("", selection: value) {
                Label("Row", systemImage: "rectangle.split.3x1").tag("row")
                Label("Column", systemImage: "rectangle.split.1x2").tag("column")
                Label("Menu", systemImage: "line.3.horizontal").tag("menu")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
        }
    }

    private var navCard: some View {
        card("Navigation") {
            let binding = Binding(get: { nav ?? NavModel() }, set: { nav = $0 })
            layoutPicker("Desktop", binding.d)
                .help("How the menu lays out on desktops: a row of links, a column, or a Menu button that opens a panel.")
            layoutPicker("iPhone", binding.m)
                .help("How the same menu lays out on phones.")
            HStack {
                rowLabel("Selected")
                Picker("", selection: binding.sel) {
                    Text("None").tag("none"); Text("Underline").tag("underline"); Text("Pill").tag("pill")
                    Text("Bold").tag("bold"); Text("Dim others").tag("dim")
                }
                .labelsHidden()
            }
            .help("How the current page's link stands out.")
            HStack {
                rowLabel("Align")
                Picker("", selection: binding.align) {
                    Image(systemName: "text.alignleft").tag("start")
                    Image(systemName: "text.aligncenter").tag("center")
                    Image(systemName: "text.alignright").tag("end")
                    Image(systemName: "arrow.left.and.right").tag("between")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                rowLabel("Button")
                Picker("", selection: binding.label) {
                    Text("Icon").tag("icon"); Text("“Menu”").tag("word"); Text("Both").tag("both")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .help("What the Menu layout's button shows.")
            sliderRow("Spacing", Binding(get: { Double(nav?.gap ?? 24) }, set: { nav?.gap = Int($0) }), 4...64, 2, "\(nav?.gap ?? 24)")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(binding.items) { $item in
                    HStack(spacing: 6) {
                        Button {
                            item.depth = item.depth == 0 ? 1 : 0
                            pushNav()
                        } label: {
                            Image(systemName: item.depth == 0 ? "arrow.turn.down.right" : "arrow.turn.up.left")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(item.depth == 0 ? "Make this a submenu item of the link above" : "Move back to the top level")
                        .padding(.leading, CGFloat(item.depth) * 12)
                        TextField("Label", text: $item.label, onEditingChanged: { if !$0 { pushNav() } })
                            .onSubmit { pushNav() }
                            .font(.system(size: 11.5))
                            .frame(minWidth: 40)
                        Menu {
                            ForEach(navPages) { page in
                                Button(page.label) { item.href = page.href; pushNav() }
                            }
                            if !navPages.isEmpty { Divider() }
                            Button("Home") { item.href = "/"; pushNav() }
                            Button("Top of this page") { item.href = "#"; pushNav() }
                        } label: {
                            Text(navPages.first { $0.href == item.href }?.label ?? item.href)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 78, alignment: .leading)
                        .help("Where this link goes. Type any address in the field to the right.")
                        TextField("Address", text: $item.href, onEditingChanged: { if !$0 { pushNav() } })
                            .onSubmit { pushNav() }
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 66)
                        Button {
                            nav?.items.removeAll { $0.id == item.id }
                            pushNav()
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button("Move Up") { move(item.id, by: -1) }
                        Button("Move Down") { move(item.id, by: 1) }
                    }
                }
                Button {
                    nav?.items.append(NavModel.Item(label: "New Link", href: navPages.first?.href ?? "/", depth: 0))
                    pushNav()
                } label: {
                    Label("Add Link", systemImage: "plus").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
            Text("Right-click a link to reorder. Row layouts open submenus on hover; Column and Menu show them indented. The current page is marked automatically on every page.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: nav?.d) { _, _ in pushNav() }
        .onChange(of: nav?.m) { _, _ in pushNav() }
        .onChange(of: nav?.sel) { _, _ in pushNav() }
        .onChange(of: nav?.align) { _, _ in pushNav() }
        .onChange(of: nav?.label) { _, _ in pushNav() }
        .onChange(of: nav?.gap) { _, _ in pushNav() }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard var items = nav?.items, let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
        nav?.items = items
        pushNav()
    }

    // MARK: Video

    private var videoCard: some View {
        card("Video") {
            HStack(spacing: 8) {
                rowLabel("Plays")
                Picker("", selection: $videoAutoplay) {
                    Text("On Click").tag(false)
                    Text("Auto").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: videoAutoplay) { _, auto in
                    if auto {
                        // The ambient preset: silent, looping, chromeless —
                        // the only way browsers allow autoplay, and the way
                        // it looks best.
                        videoSound = false
                        videoControls = false
                        if videoRepeat == "none" { videoRepeat = "loop" }
                    } else {
                        videoControls = true
                    }
                    applyVideo()
                }
            }
            HStack(spacing: 8) {
                rowLabel("Repeat")
                Picker("", selection: $videoRepeat) {
                    Text("None").tag("none")
                    Text("Loop").tag("loop")
                    Text("Bounce").tag("bounce")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: videoRepeat) { _, mode in
                    if mode == "bounce" {
                        videoSound = false
                        NotificationCenter.default.post(name: .timBounceVideo, object: nil)
                    } else {
                        tab.restorePlainVideo()
                    }
                    applyVideo()
                }
            }
            Toggle("Sound", isOn: $videoSound)
                .font(.system(size: 11))
                .disabled(videoAutoplay || videoRepeat == "bounce")
                .onChange(of: videoSound) { _, _ in applyVideo() }
            Toggle("Controls", isOn: $videoControls)
                .font(.system(size: 11))
                .onChange(of: videoControls) { _, _ in applyVideo() }
            if videoRepeat == "bounce" {
                Text("Bounce plays forward, then backward, forever — baked into the video itself so it works in every browser. Bounces are silent.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if videoAutoplay {
                Text("Autoplaying video is always silent — every browser requires it. Visitors get sound from videos they start themselves.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyVideo() {
        tab.setVideoOptions(
            autoplay: videoAutoplay,
            loop: videoRepeat != "none",
            muted: videoAutoplay || videoRepeat == "bounce" || !videoSound,
            controls: videoControls
        )
    }
    private var mediaFacts: (natW: Int, natH: Int, shownW: Int, src: String)? {
        guard let m = info["media"] as? [String: Any] else { return nil }
        return (m["natW"] as? Int ?? 0, m["natH"] as? Int ?? 0, m["shownW"] as? Int ?? 0, m["src"] as? String ?? "")
    }
    /// Retina needs about two device pixels per CSS pixel; under 1.5× the
    /// image will read as soft on every modern screen.
    private var imageTooSmall: Bool {
        guard (info["tag"] as? String) == "img", let f = mediaFacts, f.natW > 0, f.shownW > 0 else { return false }
        return Double(f.natW) < Double(f.shownW) * 1.5
    }

    private var mediaCard: some View {
        card {
            if imageTooSmall, let f = mediaFacts {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This image is \(f.natW)×\(f.natH) pixels but shows \(f.shownW) wide — it will look soft on Retina screens.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Choose Larger…") { NotificationCenter.default.post(name: .timReplaceMedia, object: nil) }
                        Button("Enlarge 2×") {
                            NotificationCenter.default.post(name: .timUpscaleMedia, object: nil, userInfo: ["src": f.src])
                        }
                        .help("Resamples the image to twice its size (\(Upscaler.methodName)). A real larger original will always look better.")
                    }
                    .controlSize(.small)
                }
            }
            Button("Replace Media…") {
                NotificationCenter.default.post(name: .timReplaceMedia, object: nil)
            }
            .font(.system(size: 11))
            Text("Swap the file — position, size, and styling stay put.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        Form {
            if nav != nil {
                navCard
            }
            if isText {
                styleCard
                typographyCard
            } else {
                HStack {
                    Text(info["label"] as? String ?? "Object")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    // The mirror of the Group button multi-selections get.
                    if (info["label"] as? String) == "Group" {
                        Button("Ungroup") { tab.ungroupSelection() }
                            .controlSize(.small)
                            .help("Dissolves the group — its objects return to the page, keeping their places.")
                    }
                }
            }
            if selectionCount > 1 {
                card {
                    HStack(spacing: 8) {
                        Text("\(selectionCount) objects — edits apply to all")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("Group") { tab.groupSelection() }
                            .controlSize(.small)
                            .help("One object from many: the group moves, resizes, fills, and rotates as a unit — and stays composed on phones.")
                    }
                }
            }
            if (info["tag"] as? String) == "video" {
                videoCard
            }
            if isMedia {
                mediaCard
            }
            if isCanvasObject, (info["label"] as? String) != "Canvas" {
                arrangeCard
            }
            appearanceCard
            if allowsTemplates, isCanvasObject {
                templateCard
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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

            sliderRow("Size", $fontSize, 10...200, 1, "\(Int(fontSize))", typed: 1...2000)
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
                .controlSize(.small)
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
                        .controlSize(.small)
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
                rowLabel("Columns")
                Picker("", selection: $columnCount) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: columnCount) { _, n in
                    // Real flowing text: fills one column, continues in the
                    // next, balances. Phones always read a single column.
                    tab.setSelectionStyle("columnCount", n <= 1 ? "" : "\(n)")
                    tab.setSelectionStyle("columnGap", n <= 1 ? "" : "16px")
                }
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
                .controlSize(.small)
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
                    .controlSize(.small)
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
        .controlSize(.small)
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

    private func applyFill() {
        tab.setSelectionStyle("background", fillIsGradient
            ? "linear-gradient(\(Int(fillAngle))deg, \(fillColor.hexString), \(fillEndColor.hexString))"
            : fillColor.hexString)
    }

    private func applyBoxShadow() {
        tab.setSelectionStyle(
            "boxShadow",
            hasShadow ? "0 8px 24px \(shadowColor.cssRGBA(0.30))" : ""
        )
    }

    // MARK: Arrange

    private var arrangeCard: some View {
        card("Arrange") {
            HStack(spacing: 3) {
                arrangeButton("Send to Back", "arrow.down.to.line", "back")
                arrangeButton("Send Backward", "arrow.down", "backward")
                arrangeButton("Bring Forward", "arrow.up", "forward")
                arrangeButton("Bring to Front", "arrow.up.to.line", "front")
                Spacer()
            }
            HStack(spacing: 3) {
                alignButton("Align Left", "align.horizontal.left", "left")
                alignButton("Center Horizontally", "align.horizontal.center", "centerX")
                alignButton("Align Right", "align.horizontal.right", "right")
                alignButton("Align Top", "align.vertical.top", "top")
                alignButton("Center Vertically", "align.vertical.center", "centerY")
                alignButton("Align Bottom", "align.vertical.bottom", "bottom")
                Spacer()
            }
            Text(selectionCount > 1
                 ? "Aligns the selected objects to each other."
                 : "Aligns to the page — select several to align them to each other.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            sliderRow("Rotate", $rotation, -180...180, 1, "\(Int(rotation))°", snap: { value in
                // Slider rotation clicks onto the 45° stops; typed values stay exact.
                let nearest = (value / 45).rounded() * 45
                return abs(value - nearest) <= 5 ? nearest : value
            })
                .onChange(of: rotation) { _, value in
                    tab.setSelectionStyle("transform", value == 0 ? "" : "rotate(\(String(format: "%g", value))deg)")
                }
            Toggle("Show on iPhone", isOn: $showOnMobile)
                .font(.system(size: 11))
                .onChange(of: showOnMobile) { _, on in
                    tab.setMobileHidden(!on)
                }
                .help("Off: this object appears on desktop only. Use it for decorative pieces the phone layout doesn't need.")
        }
    }

    private func alignButton(_ help: String, _ symbol: String, _ edge: String) -> some View {
        Button {
            tab.align(edge)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 22, height: 16)
        }
        .buttonStyle(.accessoryBar)
        .controlSize(.small)
        .help(help)
    }

    private func arrangeButton(_ help: String, _ symbol: String, _ action: String) -> some View {
        Button {
            tab.arrange(action)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 26, height: 16)
        }
        .buttonStyle(.accessoryBar)
        .controlSize(.small)
        .help(help)
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        card("Appearance") {
            HStack(spacing: 8) {
                rowLabel("Fill")
                ColorPicker("", selection: $fillColor)
                    .labelsHidden()
                    .onChange(of: fillColor) { _, _ in applyFill() }
                if fillIsGradient {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    ColorPicker("", selection: $fillEndColor)
                        .labelsHidden()
                        .onChange(of: fillEndColor) { _, _ in applyFill() }
                }
                Button {
                    fillIsGradient.toggle()
                    applyFill()
                } label: {
                    Image(systemName: "circle.bottomrighthalf.pattern.checkered")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .tint(fillIsGradient ? Color.accentColor : nil)
                .controlSize(.small)
                .help("Gradient fill")
                Button("None") {
                    fillIsGradient = false
                    tab.setSelectionStyle("background", "")
                }
                .controlSize(.small)
                Spacer()
            }
            if fillIsGradient {
                sliderRow("Angle", $fillAngle, 0...360, 5, "\(Int(fillAngle))°")
                    .onChange(of: fillAngle) { _, _ in applyFill() }
            }
            sliderRow("Corner", $radius, 0...40, 1, "\(Int(radius))")
                .onChange(of: radius) { _, v in tab.setSelectionStyle("borderRadius", "\(Int(v))px") }
            sliderRow("Padding", $padding, 0...48, 2, "\(Int(padding))")
                .onChange(of: padding) { _, v in tab.setSelectionStyle("padding", "\(Int(v))px") }
                .help("Space inside the object's edge — shown as a dashed line with arrows pointing in.")
            sliderRow("Margin", $margin, 0...48, 2, "\(Int(margin))")
                .onChange(of: margin) { _, v in tab.setSelectionStyle("margin", "\(Int(v))px") }
                .help("Space kept clear around the object inside its cells — dashed line, arrows pointing out.")
            sliderRow("Opacity", $opacity, 0.2...1, 0.05, "\(Int(opacity * 100))")
                .onChange(of: opacity) { _, v in tab.setSelectionStyle("opacity", String(format: "%.2f", v)) }
            HStack(spacing: 8) {
                rowLabel("Shadow")
                Toggle("", isOn: $hasShadow)
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
        Section {
            content()
        } header: {
            if let title { Text(title) }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 58, alignment: .leading)
    }

    private func sliderRow(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ display: String, snap: ((Double) -> Double)? = nil, typed: ClosedRange<Double>? = nil) -> some View {
        // The slider covers the sensible range; the field quietly accepts
        // any valid value for people who know exactly what they want.
        let typedRange = typed ?? range
        // Two lines so the slider gets the panel's full width: name and
        // value up top, the track beneath. The field quietly accepts any
        // valid value for people who know exactly what they want.
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Typed values are exact — snapping applies to the slider only.
                TextField("", value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = min(typedRange.upperBound, max(typedRange.lowerBound, $0)) }
                ), format: .number.precision(.fractionLength(0...2)))
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                Stepper("", value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = min(typedRange.upperBound, max(typedRange.lowerBound, $0)) }
                ), step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Slider(value: Binding(
                get: { min(range.upperBound, max(range.lowerBound, value.wrappedValue)) },
                set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, snap?($0) ?? $0)) }
            ), in: range, step: step)
        }
    }
}

// MARK: - Page pane: no selection = page options (edits the page's template)

struct PageOptionsPane: View {
    @ObservedObject var tab: Tab

    @State private var info: [String: Any]?
    @State private var loadCount = 0

    var body: some View {
        Group {
            if let info {
                PageOptionsControls(tab: tab, info: info, reload: reload)
                    .id(loadCount)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
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
    @State private var iconPageOnly: Bool
    @State private var hideFromSearch: Bool
    @State private var motionReveal: Bool
    @State private var motionFade: Bool
    private var motionModes: String {
        [motionReveal ? "reveal" : nil, motionFade ? "fade" : nil].compactMap { $0 }.joined(separator: " ")
    }
    @State private var makerRecipe: IconRecipe?
    @State private var makerImage: NSImage?
    @State private var editingSiteSettings: Site?
    @State private var pinnedFonts: [String] = []
    @State private var bgMode: String
    @State private var bgEnd: Color
    @State private var bgAngle: Double
    @State private var bgVideoBounce = false

    init(tab: Tab, info: [String: Any], reload: @escaping () -> Void) {
        self.tab = tab
        self.info = info
        self.reload = reload
        _template = State(initialValue: info["template"] as? String ?? "default")
        _title = State(initialValue: info["title"] as? String ?? "")
        let bgRaw = info["bg"] as? String ?? ""
        let gradient = parseLinearGradient(bgRaw)
        let mode: String
        if !(info["bgVideo"] as? String ?? "").isEmpty { mode = "video" }
        else if gradient != nil { mode = "gradient" }
        else if bgRaw.contains("url(") { mode = "image" }
        else { mode = "color" }
        _bgMode = State(initialValue: mode)
        _bg = State(initialValue: Color(cssColor: gradient?.start ?? bgRaw, fallback: .white))
        _bgEnd = State(initialValue: Color(cssColor: gradient?.end ?? "", fallback: .blue))
        _bgAngle = State(initialValue: gradient?.angle ?? 180)
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
        _iconPageOnly = State(initialValue: (info["ownIcons"] as? Int) == 1)
        _hideFromSearch = State(initialValue: (info["robotsMeta"] as? String ?? "").contains("noindex"))
        let motion = info["motion"] as? String ?? ""
        _motionReveal = State(initialValue: motion.contains("reveal"))
        _motionFade = State(initialValue: motion.contains("fade"))
    }

    private var currentSite: Site? { siteStore.match(tab.webView.url) }

    var body: some View {
        Form {
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

            card("Background") {
                Picker("", selection: $bgMode) {
                    Text("Color").tag("color")
                    Text("Gradient").tag("gradient")
                    Text("Image").tag("image")
                    Text("Video").tag("video")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: bgMode) { old, mode in
                    if old == "video", mode != "video" { tab.setPageBackgroundVideo("") }
                    switch mode {
                    case "color": tab.setPageOption("bg", bg.hexString)
                    case "gradient": applyPageGradient()
                    default: break  // image and video apply when a file is picked
                    }
                }
                switch bgMode {
                case "gradient":
                    HStack(spacing: 8) {
                        rowLabel("Colors")
                        ColorPicker("", selection: $bg, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: bg) { _, _ in applyPageGradient() }
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        ColorPicker("", selection: $bgEnd, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: bgEnd) { _, _ in applyPageGradient() }
                        Spacer()
                    }
                    sliderRow("Angle", $bgAngle, 0...360, 5, "\(Int(bgAngle))°")
                        .onChange(of: bgAngle) { _, _ in applyPageGradient() }
                case "image":
                    Button("Choose Image…") { choosePageBackground(video: false) }
                        .controlSize(.small)
                    Text("Fills the page edge to edge, behind everything, on every page with this template.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                case "video":
                    HStack(spacing: 8) {
                        Button("Choose Video…") { choosePageBackground(video: true) }
                            .controlSize(.small)
                        Toggle("Bounce", isOn: $bgVideoBounce)
                            .font(.system(size: 10))
                            .help("Forward, then backward, forever — baked into the file.")
                    }
                    Text("Plays silently behind the whole page, on this page. Optimized for the web automatically.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    HStack(spacing: 8) {
                        rowLabel("Color")
                        ColorPicker("", selection: $bg, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: bg) { _, c in
                                if bgMode == "color" { tab.setPageOption("bg", c.hexString) }
                            }
                        Spacer()
                    }
                }
            }

            card("Colors") {
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
                    tab.setPageBackgroundVideo("")
                    bgMode = "color"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { reload() }
                }
                .controlSize(.small)
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

            card("Motion") {
                Toggle("Reveal objects as they appear", isOn: $motionReveal)
                    .onChange(of: motionReveal) { _, _ in tab.setPageMotion(motionModes) }
                Toggle("Fade between pages", isOn: $motionFade)
                    .onChange(of: motionFade) { _, _ in tab.setPageMotion(motionModes) }
                Text("Objects fade up into place in reading order — quickly, one at a time — as they come into view. Page fades ease you in on arrival and out on the way to the next page. Both step aside for Reduce Motion.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

                // Social image — previewed as the unfurl it becomes. Auto
                // cards (social-<page>.png) preview too; only a filename
                // of the user's own means custom.
                VStack(alignment: .leading, spacing: 8) {
                    rowLabel("Social Image")
                    if !ogImage.isEmpty {
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
                    }
                    HStack(spacing: 6) {
                        Button { chooseMetaImage(kind: "ogImage") } label: {
                            Text("Choose…").frame(maxWidth: .infinity)
                        }
                        Button { tab.setPageMeta("ogImage", ""); ogImage = "" } label: {
                            Text("Automatic").frame(maxWidth: .infinity)
                        }
                        .disabled(socialIsAuto)
                        .help("Remake the card from the page itself on every save.")
                    }
                    Text(socialIsAuto
                         ? "Automatic — this page becomes its own share card on every save. How links unfurl in Messages and social apps."
                         : "Your image — Automatic returns to page snapshots.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // App icon and favicon — shown as they'll appear, with a
                // full row of room for each one's controls.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App Icon")
                                .font(.system(size: 12, weight: .medium))
                            Text("Dock and Home Screen")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Button { prepareIconMaker() } label: {
                            Text("Make…").frame(maxWidth: .infinity)
                        }
                        Button { chooseMetaImage(kind: "touchIcon") } label: {
                            Text("Choose…").frame(maxWidth: .infinity)
                        }
                        Button { tab.setPageMeta("touchIcon", ""); touchIcon = "" } label: {
                            Text("Clear").frame(maxWidth: .infinity)
                        }
                        .disabled(touchIcon.isEmpty)
                    }

                    HStack(spacing: 12) {
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
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Favicon")
                                .font(.system(size: 12, weight: .medium))
                            Text("Tabs and bookmarks")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                    HStack(spacing: 6) {
                        Button { chooseMetaImage(kind: "favicon") } label: {
                            Text("Choose…").frame(maxWidth: .infinity)
                        }
                        Button { tab.setPageMeta("favicon", ""); favicon = "" } label: {
                            Text("Clear").frame(maxWidth: .infinity)
                        }
                        .disabled(favicon.isEmpty)
                    }
                }
                Text(iconPageOnly
                     ? "Dock and Home Screen use the app icon; tabs and bookmarks use the favicon. These apply to this page alone."
                     : "Dock and Home Screen use the app icon; tabs and bookmarks use the favicon. Set once here, every page on the site gets them on Done.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if currentSite != nil {
                    Toggle("This page keeps its own icons", isOn: $iconPageOnly)
                        .font(.system(size: 10))
                        .onChange(of: iconPageOnly) { _, on in
                            tab.setPageMeta("ownIcons", on ? "1" : "")
                        }
                        .help("On: icons set here stay on this page. Off: this page follows the site's icons.")
                }
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
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
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

    private func applyPageGradient() {
        tab.setPageOption("bg", "linear-gradient(\(Int(bgAngle))deg, \(bg.hexString), \(bgEnd.hexString))")
    }

    /// A background image or video: picked, optimized for the web, staged
    /// into media/, uploaded, and applied — images as template background
    /// CSS, video as the page's full-bleed silent layer.
    private func choosePageBackground(video: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        let bounce = bgVideoBounce
        let kind = MediaKind.of(fileExtension: fileURL.pathExtension)
        guard kind == (video ? .video : .image) else {
            let alert = NSAlert()
            alert.messageText = video ? "That's not a video file." : "That's not an image file."
            alert.runModal()
            return
        }
        let resolvedSite = currentSite
        let pageURL = tab.webView.url
        var activity = ActivityCenter.shared.begin("Adding background…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var publishURL = fileURL
                if case .transcode = MediaOptimizer.plan(fileURL: fileURL, kind: kind) {
                    ActivityCenter.shared.end(activity)
                    activity = ActivityCenter.shared.begin("Optimizing \(fileURL.lastPathComponent) for the web…")
                    publishURL = try MediaOptimizer.transcode(fileURL: fileURL, kind: kind)
                    if let s = resolvedSite { MediaOptimizer.stashOriginal(fileURL, mirror: s.localProjectPath) }
                }
                if video, bounce {
                    ActivityCenter.shared.end(activity)
                    activity = ActivityCenter.shared.begin("Making \(fileURL.lastPathComponent) bounce…")
                    publishURL = try MediaOptimizer.bounceVideo(publishURL)
                }
                let staged = try EditingToolbar.stage(fileURL: publishURL, site: resolvedSite, pageURL: pageURL)
                let full = (resolvedSite?.origin.hasPrefix("http") == true)
                    ? resolvedSite!.origin + "/" + staged
                    : staged
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    if video {
                        tab.setPageBackgroundVideo(full)
                    } else {
                        tab.setPageOption("bg", "url(\"\(full)\") center / cover no-repeat")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    let alert = NSAlert()
                    alert.messageText = "Background"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Editing an icon means reopening its recipe, not starting over —
    /// recipes live in the site manifest (tim.json) so they follow the
    /// site to any Mac; local pages keep theirs in defaults.
    private func prepareIconMaker() {
        if let s = currentSite, let url = tab.webView.url {
            SiteManifest.refreshIfStale(site: s)
            let recipes = SiteManifest.load(fromMirror: s.localProjectPath).iconRecipes
            makerRecipe = iconPageOnly
                ? recipes[s.relativePagePath(for: url)]
                : (recipes["site"] ?? recipes[s.relativePagePath(for: url)])
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
            // Site icons keep one shared recipe; a page with its own icons
            // keeps its own.
            let rel = iconPageOnly ? s.relativePagePath(for: url) : "site"
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

    /// Auto cards carry the deterministic social- filename; anything
    /// else is an image the user chose.
    private var socialIsAuto: Bool {
        ogImage.isEmpty || (ogImage as NSString).lastPathComponent.hasPrefix("social-")
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
                    .controlSize(.small)
                if !value.isEmpty {
                    Button("Clear") {
                        tab.setPageMeta(kind, "")
                        if kind == "ogImage" { ogImage = "" } else { favicon = "" }
                    }
                    .controlSize(.small)
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
                    // Icons are site-level unless this page keeps its own:
                    // record them in the manifest so Done stamps every page.
                    if !iconPageOnly, let s = resolvedSite,
                       kinds.contains(where: { $0 == "favicon" || $0 == "touchIcon" }) {
                        var manifest = SiteManifest.load(fromMirror: s.localProjectPath)
                        if kinds.contains("favicon") { manifest.siteFavicon = staged }
                        if kinds.contains("touchIcon") { manifest.siteTouchIcon = staged }
                        manifest.iconsUpdated = Date()
                        let json = manifest.save(toMirror: s.localProjectPath)
                        if s.target == .sftp, let json {
                            DispatchQueue.global(qos: .utility).async {
                                let root = s.remoteRoot.hasSuffix("/") ? String(s.remoteRoot.dropLast()) : s.remoteRoot
                                _ = try? SFTP.upload(html: json, to: root + "/tim.json", host: s.host, username: s.username, port: s.port)
                            }
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
    private func card(_ title: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        Section {
            content()
        } header: {
            if let title { Text(title) }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 66, alignment: .leading)
    }

    private func sliderRow(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ display: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(display)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Slider(value: value, in: range, step: step)
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

            HStack(spacing: 6) {
                TextField("1–3 letters, or an emoji", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 160)
                Button {
                    // The system emoji picker — it types into the field.
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Text("😀")
                }
                .help("Pick an emoji")
            }
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
        let size: CGFloat = text.count > 2 ? 34 : (text.count == 2 ? 46 : 66)
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
        // A single character (or emoji) should own the icon.
        let fontSize: CGFloat = display.count == 1 ? 128 : (display.count == 2 ? 82 : 58)
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

    func makeNSView(context: Context) -> WKWebView {
        // A bare WKWebView reports a large fitting size, which starves
        // whatever shares its row — the inspector was being crushed to a
        // few points wide. The page takes the space it's given, never
        // the space it wants.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            webView.setContentHuggingPriority(.defaultLow, for: axis)
            webView.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - "Make It Mine": the page in the tab becomes a page on your
// site — assets localized, copy published, pencil lit.

/// Construction-site tape: yellow with black diagonals. The sign that a
/// page is being worked on right now, as opposed to merely being yours.
struct CautionTape: View {
    var stripe: CGFloat = 7
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(timYellow))
            var x = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + stripe, y: size.height))
                p.addLine(to: CGPoint(x: x + stripe + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.closeSubpath()
                ctx.fill(p, with: .color(Color.black.opacity(0.82)))
                x += stripe * 2
            }
        }
    }
}

extension URLSession {
    /// A blocking fetch for background queues (media enlargement).
    func syncData(from url: URL) throws -> (Data, URLResponse) {
        var result: (Data, URLResponse)?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        dataTask(with: url) { data, response, error in
            if let data, let response { result = (data, response) } else { failure = error }
            sem.signal()
        }.resume()
        sem.wait()
        if let result { return result }
        throw failure ?? URLError(.badServerResponse)
    }
}

/// File › Move… — a page is a file in a folder on your site, and moving
/// it is choosing a folder and a name, Save-dialog style. Tim fixes the
/// page's relative addresses for the new depth and can leave a small
/// forwarding page behind so old links keep working.
struct MovePageSheet: View {
    @ObservedObject var tab: Tab
    let site: Site
    @Environment(\.dismiss) private var dismiss
    @State private var folder = "/"
    @State private var newFolder = ""
    @State private var name = ""
    @State private var forward = true
    @State private var working = false
    @State private var error: String?

    private var folders: [String] { PageMover.folders(in: site.localProjectPath) }
    private var currentRel: String { tab.webView.url.map { site.relativePagePath(for: $0) } ?? "" }
    private var targetFolder: String {
        let extra = newFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let base = folder == "/" ? "" : folder
        return extra.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + extra.replacingOccurrences(of: " ", with: "-").lowercased()
    }
    private var targetRel: String {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "index" }
        if !n.hasSuffix(".html") { n += ".html" }
        return (targetFolder == "/" ? "" : targetFolder) + "/" + n
    }
    private var host: String { URL(string: site.origin)?.host() ?? site.origin }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Now at") { Text(host + currentRel).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                } header: { Text("Move Page") }
                Section("Where") {
                    Picker("Folder", selection: $folder) {
                        ForEach(folders, id: \.self) { f in
                            Text(f == "/" ? host : String(f.dropFirst()).replacingOccurrences(of: "/", with: " › ")).tag(f)
                        }
                    }
                    TextField("New folder inside it (optional)", text: $newFolder)
                    TextField("File name", text: $name, prompt: Text("index"))
                        .font(.system(size: 12, design: .monospaced))
                    LabeledContent("Will be at") { Text(host + targetRel).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Leave a forwarding page at the old address", isOn: $forward)
                    Text("Anyone with the old link lands on the new page. Search engines learn the new address too.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if let error { Section { Text(error).font(.system(size: 11)).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    move()
                } label: {
                    if working { ProgressView().controlSize(.small).frame(width: 44) } else { Text("Move") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(working || targetRel == currentRel || tab.isEditing)
                .help(tab.isEditing ? "Finish editing first (press Done)." : "")
            }
            .padding(14)
        }
        .frame(width: 460)
        .onAppear {
            let rel = currentRel
            let dir = (rel as NSString).deletingLastPathComponent
            folder = folders.contains(dir) ? (dir.isEmpty ? "/" : dir) : "/"
            name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    private func move() {
        let from = currentRel, to = targetRel
        guard from != to, let oldURL = URL(string: site.origin + from) else { return }
        working = true; error = nil
        let mirror = site.localProjectPath
        let fm = FileManager.default
        DispatchQueue.global(qos: .userInitiated).async {
            let activity = ActivityCenter.shared.begin("Moving \((from as NSString).lastPathComponent)…")
            do {
                let oldLocal = mirror + from
                guard var html = try? String(contentsOfFile: oldLocal, encoding: .utf8) else {
                    throw PublishError.failed("Tim doesn't have a local copy of this page yet. Open it, press Edit, then Done once — then move it.")
                }
                html = PageMover.rebase(html: html, from: from, to: to, origin: site.origin)
                let newLocal = mirror + to
                try fm.createDirectory(atPath: (newLocal as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try html.write(toFile: newLocal, atomically: true, encoding: .utf8)
                let newURL = site.origin + to
                let title = (try? NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>")).flatMap { re -> String? in
                    guard let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(m.range(at: 1), in: html) else { return nil }
                    return String(html[r])
                } ?? ""
                if forward {
                    try PageMover.forwardingPage(to: newURL, title: title).write(toFile: oldLocal, atomically: true, encoding: .utf8)
                } else {
                    try? fm.removeItem(atPath: oldLocal)
                }
                let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
                switch site.target {
                case .sftp:
                    _ = try SFTP.upload(html: html, to: root + to, host: site.host, username: site.username, port: site.port)
                    if forward {
                        _ = try SFTP.upload(html: PageMover.forwardingPage(to: newURL, title: title), to: root + from, host: site.host, username: site.username, port: site.port)
                    } else {
                        _ = try SFTP.remove(root + from, host: site.host, username: site.username, port: site.port)
                    }
                case .cloudflare:
                    _ = try CloudflarePublisher.publish(site: site, folder: mirror)
                case .githubPages:
                    _ = try GitHubPagesPublisher.publish(repo: mirror, message: "Move \(from) → \(to)")
                }
                SiteWorkspace.snapshot(mirror, message: "Move \(from) → \(to)")
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    working = false
                    PageRegistry.record(url: newURL, title: title)
                    tab.navigate(to: newURL)
                    _ = oldURL
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    ActivityCenter.shared.end(activity)
                    working = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// Page › Submit to Showcase… — the friction is the point: the page must
/// be live and made with Tim, you finish editing first, you sign it with
/// your name and a real sentence, and you say it's yours to show.
struct ShowcaseSheet: View {
    @ObservedObject var tab: Tab
    @Environment(\.dismiss) private var dismiss
    @State private var name = NSFullUserName()
    @State private var note = ""
    @State private var agree = false
    @State private var inspection: ShowcaseAPI.Inspection?
    @State private var working = false
    @State private var error: String?
    @State private var thanks: String?

    private var url: URL? {
        guard let u = URL(string: tab.urlString), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }
    private var noteOK: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 }
    private var nameOK: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 }
    private var pageOK: Bool { inspection?.reachable == true && inspection?.madeWithTim == true }
    private var canSubmit: Bool { url != nil && pageOK && !tab.isEditing && nameOK && noteOK && agree && !working }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if let img = inspection?.image {
                                AsyncImage(url: img) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() }
                                    else { Rectangle().fill(Color.primary.opacity(0.06)) }
                                }
                            } else {
                                Rectangle().fill(Color.primary.opacity(0.06))
                            }
                        }
                        .frame(width: 160, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(inspection?.title.isEmpty == false ? inspection!.title : (tab.title.isEmpty ? "This page" : tab.title))
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(2)
                            Text(tab.urlString)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            check(inspection == nil ? nil : pageOK,
                                  inspection == nil ? "Checking the live page…"
                                  : inspection?.reachable != true ? "Not reachable — publish it first."
                                  : !pageOK ? "Not made with Tim." : "Live, made with Tim.")
                            check(!tab.isEditing, tab.isEditing ? "Finish editing first (press Done)." : "Not being edited.")
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Submit to Showcase")
                } footer: {
                    Text("The Showcase is a hand-picked gallery of sites made with Tim. A person reads every submission; most hear back within a week.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Section("About it") {
                    TextField("Your name", text: $name)
                    TextField("A sentence about the site — what it is, who it's for", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("This is my site, and I'm happy for it to be shown publicly.", isOn: $agree)
                }
                if let error {
                    Section { Text(error).font(.system(size: 11.5)).foregroundStyle(.red) }
                }
                if let thanks {
                    Section { Label(thanks, systemImage: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Link("See the Showcase", destination: ShowcaseAPI.galleryURL)
                    .font(.system(size: 11.5))
                Spacer()
                if thanks != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button {
                        submit()
                    } label: {
                        if working { ProgressView().controlSize(.small).frame(width: 60) } else { Text("Submit") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(timYellow)
                    .foregroundStyle(.black)
                    .disabled(!canSubmit)
                }
            }
            .padding(14)
        }
        .frame(width: 480)
        .task {
            guard let url else { return }
            inspection = await ShowcaseAPI.inspect(url)
        }
    }

    @ViewBuilder private func check(_ ok: Bool?, _ text: String) -> some View {
        HStack(spacing: 5) {
            if let ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? Color.green : Color.orange)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func submit() {
        guard let url else { return }
        working = true; error = nil
        Task {
            do {
                thanks = try await ShowcaseAPI.submit(url: url, name: name.trimmingCharacters(in: .whitespaces),
                                                      note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

struct ImportSheet: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var siteStore: SiteStore
    @Environment(\.dismiss) private var dismiss
    @State private var siteID: UUID?
    @State private var path = ""
    @State private var working = false
    @State private var status: String?

    private var site: Site? {
        siteStore.sites.first(where: { $0.id == siteID }) ?? siteStore.sites.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Tim copies this page — its images, styles, fonts, and icons — onto your site. The copy is yours: edit its text and media, set its title and icons, publish changes like any page. The layout stays exactly as its author built it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Make It Mine")
                }
                Section("Destination") {
                    Picker("Site", selection: Binding(get: { site?.id }, set: { siteID = $0 })) {
                        ForEach(siteStore.sites) { s in
                            Text(s.name.isEmpty ? s.origin : s.name).tag(Optional(s.id))
                        }
                    }
                    TextField("Path", text: $path)
                        .font(.system(size: 11, design: .monospaced))
                }
                Section {
                    Text("Honest limits: the copy is a snapshot. Scripts and forms keep pointing at the original site, and linked pages aren't imported — their links lead back to the original.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let status {
                    Section {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    runImport()
                } label: {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Make It Mine")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || site == nil || path.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 470, height: 440)
        .onAppear {
            if let url = tab.webView.url { path = PageImporter.defaultPath(for: url) }
        }
    }

    private func runImport() {
        guard let chosen = site, let pageURL = tab.webView.url else { return }
        working = true
        status = "Reading the page…"
        tab.webView.evaluateJavaScript(PageImporter.gatherJS) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let html = dict["html"] as? String
            else {
                working = false
                status = "Couldn’t read the page."
                return
            }
            let resources = dict["resources"] as? [String] ?? []
            var rel = path
            while rel.hasPrefix("/") { rel.removeFirst() }
            var resolved = chosen
            if resolved.localProjectPath.isEmpty {
                resolved.localProjectPath = SiteWorkspace.defaultFolder(for: resolved.name.isEmpty ? resolved.origin : resolved.name)
                siteStore.upsert(resolved)
            }
            SiteWorkspace.ensure(resolved.localProjectPath)
            let siteCopy = resolved
            status = resources.isEmpty ? "Copying the page…" : "Fetching \(resources.count) assets…"
            Task {
                let page = await PageImporter.localize(html: html, resources: resources, pageURL: pageURL)
                do {
                    // Mirror first, then the server.
                    try PageWriter.write(html: page.html, folder: siteCopy.localProjectPath, relativePath: rel)
                    let relDir = (rel as NSString).deletingLastPathComponent
                    let assetsDirLocal = URL(fileURLWithPath: siteCopy.localProjectPath)
                        .appendingPathComponent(relDir.isEmpty ? "assets" : relDir + "/assets")
                    try FileManager.default.createDirectory(at: assetsDirLocal, withIntermediateDirectories: true)
                    for asset in page.assets {
                        try asset.data.write(to: assetsDirLocal.appendingPathComponent(asset.name))
                    }
                    await MainActor.run { status = "Publishing…" }
                    switch siteCopy.target {
                    case .sftp:
                        let root = siteCopy.remoteRoot.hasSuffix("/") ? String(siteCopy.remoteRoot.dropLast()) : siteCopy.remoteRoot
                        var batch = ""
                        var dir = root
                        for seg in relDir.split(separator: "/") {
                            dir += "/" + seg
                            batch += "-mkdir \"\(dir)\"\n"
                        }
                        let pageLocal = URL(fileURLWithPath: siteCopy.localProjectPath).appendingPathComponent(rel).path
                        batch += "put \"\(pageLocal)\" \"\(root)/\(rel)\"\n"
                        if !page.assets.isEmpty {
                            let remoteAssets = relDir.isEmpty ? "\(root)/assets" : "\(root)/\(relDir)/assets"
                            batch += "-mkdir \"\(remoteAssets)\"\n"
                            for asset in page.assets {
                                batch += "put \"\(assetsDirLocal.appendingPathComponent(asset.name).path)\" \"\(remoteAssets)/\(asset.name)\"\n"
                            }
                        }
                        _ = try SFTP.run(batch: batch, host: siteCopy.host, username: siteCopy.username, port: siteCopy.port)
                    case .cloudflare:
                        _ = try CloudflarePublisher.publish(site: siteCopy)
                    case .githubPages:
                        _ = try GitHubPagesPublisher.publish(repo: siteCopy.localProjectPath, message: "Imported \(pageURL.host() ?? "page") with Tim")
                    }
                    await MainActor.run {
                        working = false
                        let origin = siteCopy.origin.hasSuffix("/") ? String(siteCopy.origin.dropLast()) : siteCopy.origin
                        let newURL = origin + "/" + rel
                        PageRegistry.record(url: newURL, title: (rel as NSString).lastPathComponent)
                        dismiss()
                        tab.navigate(to: newURL)
                    }
                } catch {
                    await MainActor.run {
                        working = false
                        status = "Couldn’t publish: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}



// MARK: - The address bar, done the way a Mac browser does it: one field,
// in the toolbar, self-contained. Every input here is the tab reference
// or the environment — never the window's @State — so a keystroke
// re-evaluates THIS view and nothing above it. A toolbar item whose
// content is rebuilt loses first responder; this one's content never
// changes shape or identity, so it is never rebuilt.
struct AddressBar: View {
    @ObservedObject var tab: Tab
    let onCreate: () -> Void
    let onClaim: () -> Void
    @EnvironmentObject var siteStore: SiteStore
    @AppStorage("tim.experimental.makeItMine") private var makeItMineEnabled = false
    @AppStorage("tim.cleanAddresses") private var cleanAddresses = true
    @State private var text = ""
    /// Editing state comes from the field itself (begin/end editing), NOT
    /// from @FocusState. Yesterday's working field carried no .focused()
    /// modifier; every broken variant today did. Inside a toolbar item
    /// FocusState never registers the click, so on the first keystroke
    /// SwiftUI reconciles "not focused" against a focused field — and
    /// resigns it. One character, then nothing.
    @State private var editing = false

    private var isEditable: Bool {
        siteStore.isEditable(URL(string: tab.urlString), timAuthored: tab.isTimPage)
    }

    private var matchedSite: Site? {
        let url = URL(string: tab.urlString)
        if let site = siteStore.match(url) { return site }
        guard tab.isTimPage || tab.lastHTTPStatus == 404, let url else { return nil }
        return siteStore.derivedSite(for: url)
    }
    /// A missing page on your own site can be created; a page that isn't
    /// yours can be claimed. Both actions live in the field, Safari's way.
    private var canCreate: Bool { matchedSite != nil && tab.lastHTTPStatus == 404 && !tab.isEditing }
    private var canClaim: Bool {
        makeItMineEnabled && matchedSite == nil && !siteStore.sites.isEmpty && !tab.isEditing
            && (URL(string: tab.urlString)?.scheme?.hasPrefix("http") ?? false)
    }

    /// Safari's manner: at rest the address reads as a name — scheme and
    /// www gone — and the full URL appears the moment you click in. Done
    /// by changing what the ONE field shows, not by stacking a label over
    /// a transparent field.
    private var restText: String {
        guard cleanAddresses, let url = URL(string: tab.urlString), let host = url.host() else {
            return tab.urlString
        }
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = (url.path == "/" || url.path.isEmpty) ? "" : url.path
        return clean + path
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isEditable ? "pencil.circle.fill" : "globe")
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(isEditable ? .palette : .monochrome)
                .foregroundStyle(
                    isEditable ? AnyShapeStyle(Color.black) : AnyShapeStyle(.tertiary),
                    AnyShapeStyle(timYellow)
                )
                .help(isEditable ? "This page is yours — ⌘E edits it, Done publishes it." : "")

            // Always in the layout, shown by opacity — a structural change
            // beside the field would restart its editing session.
            Button {
                if canCreate { onCreate() } else if canClaim { onClaim() }
            } label: {
                Image(systemName: canCreate ? "plus.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black, AnyShapeStyle(timYellow))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(canCreate || canClaim ? 1 : 0)
            .allowsHitTesting(canCreate || canClaim)
            .help(canCreate
                  ? "This page doesn't exist on your site yet — create and publish it at this address."
                  : "Make It Mine — copy this page, with its images, styles, and fonts, onto your own site, ready to edit.")

            TextField("Search or enter address", text: $text, onEditingChanged: { began in
                // begin-editing re-fires on keystrokes (the trace showed five
                // trues with no false). Only the TRANSITION may touch the
                // text: reveal the real address when editing starts, restore
                // the name when it ends. Re-fires must never clobber typing.
                guard began != editing else { return }
                text = began ? tab.urlString : restText
                editing = began
                tab.addressEditing = began
            })
                .textFieldStyle(.plain)
                // CONSTANT while editing. Changing a field's font or
                // alignment on focus rebuilds its cell and field editor on
                // macOS — the editing session silently restarts and the
                // keyboard is gone after one character. This was the bug.
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .onSubmit {
                    tab.addressEditing = false
                    tab.navigate(to: text)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .frame(maxWidth: .infinity)

            Button {
                if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(tab.isLoading ? "Stop" : "Reload (⌘R)")
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .clipShape(Capsule(style: .continuous))
        .glassEffect(
            (isEditable ? Glass.regular.tint(timYellow.opacity(0.14)) : Glass.regular).interactive(),
            in: Capsule(style: .continuous)
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .opacity(editing ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(26, 500 * tab.loadingProgress), height: 2)
                .padding(.leading, 14)
                .padding(.bottom, 1.5)
                .opacity(tab.isLoading ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onAppear { text = restText }
        .onDisappear { tab.addressEditing = false }
        .onChange(of: tab.urlString) { _, _ in
            if !editing { text = restText }
        }
        .onChange(of: cleanAddresses) { _, _ in
            if !editing { text = restText }
        }
    }
}


// MARK: - Toolbar isolation

struct ToolbarKey: Equatable {
    var isEditing: Bool, isMobilePreview: Bool, viewMode: Int
    var previewing: Bool, editable: Bool
    var canBack: Bool, canForward: Bool
    var reviewDesktop: Int, reviewMobile: Int
    var matchedSite: UUID?, siteIDs: [UUID]
    var tabID: UUID
    var url: String
}

/// A zero-size view that carries the window's toolbar. Equatable on a
/// value key, so SwiftUI skips its body — and never re-supplies the
/// toolbar — when nothing the toolbar renders from has changed.
struct ToolbarAnchor<T: ToolbarContent>: View, Equatable {
    let key: ToolbarKey
    @ToolbarContentBuilder let content: () -> T

    static func == (a: ToolbarAnchor, b: ToolbarAnchor) -> Bool { a.key == b.key }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).toolbar { content() }
    }
}
