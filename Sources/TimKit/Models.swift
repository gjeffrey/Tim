import Foundation
import os
import WebKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// One browser tab. Owns its WKWebView and mirrors its state for SwiftUI.
/// WKWebView is the same engine on macOS, iOS, and iPadOS, so Tab is
/// fully cross-platform.
public final class Tab: NSObject, ObservableObject, Identifiable {
    public let id = UUID()

    /// True while the address bar is being typed into. Deliberately NOT
    /// published — nothing should re-render on it. The web view consults
    /// it to refuse focus stolen by page scripts.
    public var addressEditing = false {
        didSet {
            #if os(iOS)
            guard addressEditing != oldValue else { return }
            webView.evaluateJavaScript("window.__timAddressEditing = \(addressEditing);", completionHandler: nil)
            #endif
        }
    }

    @Published public var title: String = "New Tab"
    @Published public var urlString: String = ""
    @Published public var isEditing: Bool = false
    /// Pinned tabs stay at the top of the tab list and survive casual
    /// closing (no hover ✕ — unpin or use the menu, deliberately).
    @Published public var isPinned: Bool = false
    /// The loaded page identifies itself as Tim-authored (canvas attribute
    /// or generator meta) — what lets editing light up on any folder of a
    /// server we can already write to.
    @Published public var isTimPage: Bool = false
    /// Objects on each layout waiting for a look because an edit on the
    /// other layout guessed their placement (or outgrew their box).
    @Published public var reviewDesktop: Int = 0
    @Published public var reviewMobile: Int = 0
    var restoringDraft = false
    /// One-shot: the next page load must not auto-resume a draft (set
    /// while showing a version preview, which loads over the same URL).
    public var suppressDraftResume = false
    /// Set when TIM asks to go somewhere — the address bar, the sidebar,
    /// back, forward, reload. A navigation while editing that nobody asked
    /// for is a page acting on its own, and is not a reason to close the
    /// editor and stash a draft.
    /// A restored tab that hasn't been shown yet: it knows its address and
    /// title, and loads the first time it's selected — the way Safari
    /// reopens a window. Loading every tab at launch meant a dozen web
    /// processes and, for a site on one shared server, half a dozen
    /// requests in the same second, which is how pages timed out.
    @Published public var pendingURL: String?
    public func deferLoad(of url: String) {
        pendingURL = url
        urlString = url
        title = URL(string: url)?.host() ?? url
    }
    public func loadIfPending() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        navigate(to: url)
    }
    private var deliberateNavigation = false
    /// `log stream --predicate 'subsystem == "com.gabrieljeffrey.tim"'` —
    /// the life of a page load, so a blank tab can say what it did.
    static let navLog = Logger(subsystem: "com.gabrieljeffrey.tim", category: "navigation")
    func note(_ event: String) {
        Tab.navLog.notice("\(event, privacy: .public) \(self.urlString, privacy: .public)")
    }
    /// The address to retry from the load-failure page.
    public var pendingRetryURL: String = ""
    /// An unpublished draft of this page exists on this Mac.
    @Published public var hasDraft = false
    /// A non-empty text selection inside the text being edited: viewport
    /// rect in CSS px plus formatting state — what the floating bar shows.
    @Published public var textSelection: [String: Any]?
    @Published public var isLoading: Bool = false
    @Published public var loadingProgress: Double = 0
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var isMobilePreview: Bool = false
    @Published public var lastHTTPStatus: Int = 200
    /// Current Layout selection, as reported by the canvas layer — the
    /// Inspector's data source. Nil when nothing is selected.
    @Published public var selectionInfo: [String: Any]?

    public let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    /// When set (the app wires it to connected sites), main-frame loads of
    /// matching URLs bypass the HTTP cache — pages you publish are always
    /// shown fresh when you come back to them.
    public var cacheBypass: ((URL) -> Bool)?

    public override init() {
        let configuration = WKWebViewConfiguration()
        // Render exactly like Safari. The engine already is Safari's WebKit,
        // but WKWebView's default user agent stops at "(KHTML, like Gecko)" —
        // without the trailing "Version/… Safari/…" token, sites (apple.com
        // included) don't recognize Safari and serve different markup.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        webView = TimWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        #if os(macOS)
        webView.allowsMagnification = true
        #endif
        super.init()
        (webView as? TimWebView)?.addressEditing = { [weak self] in self?.addressEditing ?? false }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.add(self, name: "timSel")
        webView.configuration.userContentController.add(self, name: "timText")
        #if os(iOS)
        // The Mac refuses first responder while the address bar is being
        // typed in; on iOS the equivalent is stopping the page's own
        // focus() calls at the source — pages love to grab a search field
        // as they load, and that yanks the keyboard off the address bar.
        webView.configuration.userContentController.addUserScript(WKUserScript(source: """
        (function(){var f=HTMLElement.prototype.focus;window.__timAddressEditing=false;
        HTMLElement.prototype.focus=function(){if(window.__timAddressEditing)return;return f.apply(this,arguments)};})();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        #endif

        NotificationCenter.default.addObserver(forName: DraftStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDraftState()
        }
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let title = view.title, !title.isEmpty {
                    self.title = title
                } else if let host = view.url?.host() {
                    self.title = host
                }
            }
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let absolute = view.url?.absoluteString ?? ""
                self.urlString = absolute == "about:blank" ? "" : absolute
            }
        })
        // Publish only on real change: a page whose trackers never settle
        // fires these observers continuously, and every publish re-evaluates
        // the window — which rebuilt the toolbar under a typing cursor.
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                guard let self, self.isLoading != view.isLoading else { return }
                self.isLoading = view.isLoading
            }
        })
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let quantized = (view.estimatedProgress * 50).rounded() / 50
                if quantized != self.loadingProgress { self.loadingProgress = quantized }
            }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
        })
    }

    public func loadStartPage() {
        title = "Start"
        webView.loadHTMLString(StartPage.current, baseURL: nil)
    }

    /// Interprets the address bar text as a URL, a bare domain, or a search.
    public func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deliberateNavigation = true

        let url: URL?
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") {
            url = URL(string: trimmed)
        } else if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
        } else if trimmed.contains("."), !trimmed.contains(" ") {
            url = URL(string: "https://" + trimmed)
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            url = URL(string: "https://duckduckgo.com/?q=" + query)
        }

        guard let url else { return }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    public func goBack() { deliberateNavigation = true; webView.goBack() }
    public func goForward() { deliberateNavigation = true; webView.goForward() }
    public func reloadPage() { deliberateNavigation = true; webView.reload() }

    /// One edit mode: the canvas. Objects select, move, and resize on the
    /// grid; any text — box or flowing paragraph — edits on double-click.
    public func setEditing(_ editing: Bool) {
        isEditing = editing
        if editing {
            webView.evaluateJavaScript(Self.editTrackerJS, completionHandler: nil)
            webView.evaluateJavaScript(
                "window.__timNavCSS = \(Self.jsLiteral(NavKit.css)); window.__timNavJS = \(Self.jsLiteral(NavKit.script));",
                completionHandler: nil
            )
            webView.evaluateJavaScript(Self.canvasJS, completionHandler: nil)
            webView.evaluateJavaScript("window.__timCanvasOn && window.__timCanvasOn();", completionHandler: nil)
        } else {
            textSelection = nil
            webView.evaluateJavaScript("window.__timCanvasOff && window.__timCanvasOff();", completionHandler: nil)
        }
    }

    /// The link around the current text caret/selection, if any.
    public func selectionLink(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("(function(){var s=window.getSelection();var n=s&&s.anchorNode;if(!n)return '';var e=n.nodeType===1?n:n.parentElement;var a=e&&e.closest?e.closest('a[href]'):null;return a?(a.getAttribute('href')||''):''})()") { r, _ in
            completion(r as? String ?? "")
        }
    }

    /// Mobile preview: iPhone-width viewport + iPhone Safari user agent,
    /// so media queries and UA-sniffing sites both behave as on the phone.
    /// iPad: desktop view must mean desktop no matter how many points the
    /// pane happens to have (a portrait split or an open inspector can dip
    /// under the 700px breakpoint). The same move iPad Safari makes for
    /// desktop sites — pin the layout viewport wide, scaled to fit — via
    /// an injected meta that outranks the page's own and never survives a
    /// save. Live-mutable, so it holds mid-edit too.
    public var prefersDesktopViewport = false

    public func applyPreviewViewport() {
        // WebKit re-evaluates a viewport meta when its CONTENT changes,
        // but removing the node doesn't reliably revert to the page's own
        // — so the override meta stays put and is rewritten both ways.
        guard prefersDesktopViewport else { return }
        let wantWide = !isMobilePreview
        // minimum-scale leaves pinch-out headroom for the pasteboard —
        // objects past the page edge are one pinch away on iPad.
        let content = wantWide ? "width=1180, minimum-scale=0.25" : "width=device-width, initial-scale=1"
        let js = """
        (function () {
          var m = document.querySelector('meta[name="viewport"][data-tim-preview]');
          if (!m) {
            m = document.createElement('meta');
            m.name = 'viewport';
            m.setAttribute('data-tim-preview', '');
            document.head.appendChild(m);
          }
          m.setAttribute('content', '\(content)');
          window.dispatchEvent(new Event('resize'));
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    public func setMobilePreview(_ mobile: Bool) {
        isMobilePreview = mobile
        applyPreviewViewport()
        // While editing, only the viewport changes — media queries respond
        // instantly and the edit session survives. Entering phone width
        // mid-edit switches the canvas to the mobile layout (creating it
        // from the automatic stack the first time). The UA swap and
        // reload happen only while browsing.
        guard !isEditing else {
            if mobile {
                webView.evaluateJavaScript(
                    "setTimeout(function () { window.__timEnsureMobileLayout && window.__timEnsureMobileLayout(); }, 300);",
                    completionHandler: nil
                )
            } else {
                webView.evaluateJavaScript(
                    "setTimeout(function () { window.__timBeginReview && window.__timBeginReview('desktop'); }, 300);",
                    completionHandler: nil
                )
            }
            refreshReviewCounts()
            return
        }
        webView.customUserAgent = mobile
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
            : nil
        // Pages loaded from strings (the start page) have no URL — reload()
        // would blank them. Re-load them instead.
        if webView.url == nil || webView.url?.absoluteString == "about:blank" {
            loadStartPage()
        } else {
            webView.reload()
        }
    }

    /// Headings and titled text objects on the page — link targets.
    public func pageAnchors(_ completion: @escaping ([String]) -> Void) {
        webView.evaluateJavaScript("window.__timAnchorList ? window.__timAnchorList() : '[]'") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { completion([]); return }
            completion(array)
        }
    }

    /// Ensures the indexed anchor has an id and returns its "#id" href.
    public func anchorHref(at index: Int, _ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__timAnchorHref ? window.__timAnchorHref(\(index)) : ''") { result, _ in
            completion(result as? String ?? "")
        }
    }

    public func format(_ command: String, value: String? = nil) {
        let js: String
        if let value {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            js = "document.execCommand('\(command)', false, '\(escaped)');"
        } else {
            js = "document.execCommand('\(command)');"
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    public func currentHTML(_ completion: @escaping (String?) -> Void) {
        // Serialize a cleaned clone: Tim's overlay and transient editing
        // attributes must never end up in a saved page.
        let js = """
        (function () {
          var clone = document.documentElement.cloneNode(true);
          clone.classList.remove('tim-editing');
          clone.classList.remove('tim-mobile-custom');
          var overlay = clone.querySelector('#__tim-overlay');
          if (overlay) { overlay.remove(); }
          var editables = clone.querySelectorAll('[contenteditable]');
          for (var i = 0; i < editables.length; i++) { editables[i].removeAttribute('contenteditable'); }
          var loading = clone.querySelectorAll('.tim-loading');
          for (var j = 0; j < loading.length; j++) { loading[j].classList.remove('tim-loading'); }
          // Everything the editor adds carries an id starting __tim- (its
          // stylesheet, the column pin, the overlay). None of it may be
          // saved: a leaked phone-width pin once came back on desktop.
          var chrome = clone.querySelectorAll('[id^="__tim-"]');
          for (var c = 0; c < chrome.length; c++) { chrome[c].remove(); }
          var pending = clone.querySelectorAll('[data-tim-placeholder]');
          for (var p = 0; p < pending.length; p++) { pending[p].remove(); }
          var replacing = clone.querySelectorAll('[data-tim-replace], .tim-media-replacing');
          for (var q = 0; q < replacing.length; q++) {
            replacing[q].removeAttribute('data-tim-replace');
            replacing[q].classList.remove('tim-media-replacing');
          }
          // Classes the page puts on ITSELF while it is being looked at —
          // an object revealed by scrolling, a menu left open, the fade
          // marked ready. They describe a moment, not the page, and a
          // saved copy that carries them starts life already half-played.
          var runtime = clone.querySelectorAll('.tim-in, .tim-nav-open');
          for (var t = 0; t < runtime.length; t++) {
            runtime[t].classList.remove('tim-in', 'tim-nav-open');
          }
          clone.classList.remove('tim-ready', 'tim-reveal', 'tim-fade');
          var reviewing = clone.querySelectorAll('[data-tim-review]');
          for (var v = 0; v < reviewing.length; v++) { reviewing[v].removeAttribute('data-tim-review'); }
          var offpage = clone.querySelectorAll('[data-tim-offpage]');
          for (var op = 0; op < offpage.length; op++) { offpage[op].removeAttribute('data-tim-offpage'); }
          var previewVp = clone.querySelector('meta[name="viewport"][data-tim-preview]');
          if (previewVp) { previewVp.remove(); }
          // The product page's try-the-editor chrome is runtime-only.
          var demo = clone.querySelectorAll('[data-tim-demo]');
          for (var dm = 0; dm < demo.length; dm++) { demo[dm].remove(); }
          // CDN-injected scripts (Cloudflare beacons, Rocket Loader) must
          // never be saved back — each publish would re-accumulate them.
          var injected = clone.querySelectorAll('script[src*="cloudflareinsights"], script[src*="cdn-cgi"], script[data-cf-settings], script[data-cf-beacon]');
          for (var ci = 0; ci < injected.length; ci++) { injected[ci].remove(); }
          var head = clone.querySelector('head');
          if (head && !head.querySelector('meta[name="generator"]')) {
            var gen = document.createElement('meta');
            gen.setAttribute('name', 'generator');
            gen.setAttribute('content', 'Tim');
            head.insertBefore(gen, head.firstChild);
          }
          return (document.doctype ? '<!DOCTYPE html>\\n' : '') + clone.outerHTML;
        })()
        """
        webView.evaluateJavaScript(js) { result, _ in
            completion(result as? String)
        }
    }

    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode([value]),
              var text = String(data: data, encoding: .utf8) else { return "''" }
        text.removeFirst()
        text.removeLast()
        return text
    }

    /// Inserts an object (text box, image, video) into the page's canvas,
    /// creating the canvas if the page doesn't have one yet. Spans are in
    /// grid cells (24 columns wide; rows are fixed units).
    public func insertObject(html: String, colSpan: Int = 12, rowSpan: Int = 3, at point: CGPoint? = nil) {
        if let point {
            webView.evaluateJavaScript(
                "window.__timInsertAt && window.__timInsertAt(\(Self.jsLiteral(html)), \(colSpan), \(rowSpan), \(Int(point.x)), \(Int(point.y)));",
                completionHandler: nil
            )
            return
        }
        webView.evaluateJavaScript(
            "window.__timInsert && window.__timInsert(\(Self.jsLiteral(html)), \(colSpan), \(rowSpan));",
            completionHandler: nil
        )
    }

    /// The live contents of a component region on the current page, or nil
    /// when the page has none — the editor seeds from this so it reflects
    /// unsaved styling and edits, not just the master on disk.
    public func componentHTML(name: String, _ completion: @escaping (String?) -> Void) {
        let js = """
        (function () {
          var region = document.querySelector('[data-tim-component=' + JSON.stringify(\(Self.jsLiteral(name))) + ']');
          return region ? region.innerHTML : null;
        })()
        """
        webView.evaluateJavaScript(js) { result, _ in
            completion(result as? String)
        }
    }

    /// Replaces the live contents of a component region on the current
    /// page. Completion reports whether the region was found — callers
    /// insert the component fresh when it wasn't.
    public func updateComponent(name: String, html: String, _ completion: @escaping (Bool) -> Void) {
        let js = """
        (function () {
          var region = document.querySelector('[data-tim-component=' + JSON.stringify(\(Self.jsLiteral(name))) + ']');
          if (!region) { return false; }
          var tmp = document.createElement('div');
          tmp.innerHTML = \(Self.jsLiteral(html));
          var fresh = tmp.firstElementChild;
          var old = region.firstElementChild;
          if (old && fresh && old.tagName === fresh.tagName) {
            // The live element is the truth for styling and grid position —
            // only its contents change.
            old.innerHTML = fresh.innerHTML;
          } else {
            var keepArea = (old && old.style) ? old.style.gridArea : '';
            region.innerHTML = \(Self.jsLiteral(html));
            var el = region.firstElementChild;
            if (el && keepArea) { el.style.gridArea = keepArea; }
          }
          return true;
        })()
        """
        webView.evaluateJavaScript(js) { result, _ in
            completion(result as? Bool ?? false)
        }
    }

    /// Undo/redo across canvas operations (move, resize, style, insert,
    /// delete, arrange) — text editing keeps the browser's native undo.
    public func undoEdit() {
        webView.evaluateJavaScript(
            "window.__timUndo ? window.__timUndo() : document.execCommand('undo');",
            completionHandler: nil
        )
    }

    public func redoEdit() {
        webView.evaluateJavaScript(
            "window.__timRedo ? window.__timRedo() : document.execCommand('redo');",
            completionHandler: nil
        )
    }

    /// Groups the multi-selection into a container object (its own little
    /// canvas — moves, fills, and rotates as one), and back.
    /// Typed placement from the inspector's cell fields — row/column
    /// start and end in the current layout's grid.
    public func setSelectionArea(rs: Int, cs: Int, re: Int, ce: Int) {
        webView.evaluateJavaScript(
            "window.__timSetArea && window.__timSetArea(\(rs), \(cs), \(re), \(ce));",
            completionHandler: nil
        )
    }

    public func groupSelection() {
        webView.evaluateJavaScript("window.__timGroupSel && window.__timGroupSel();", completionHandler: nil)
    }

    public func ungroupSelection() {
        webView.evaluateJavaScript("window.__timUngroupSel && window.__timUngroupSel();", completionHandler: nil)
    }

    /// Standard alignment: "left", "centerX", "right", "top", "centerY",
    /// "bottom" — several objects align to each other, one to its page.
    public func align(_ edge: String) {
        webView.evaluateJavaScript(
            "window.__timAlign && window.__timAlign(\(Self.jsLiteral(edge)));",
            completionHandler: nil
        )
    }

    /// Keynote-style arrange: "front", "forward", "backward", or "back",
    /// reordering the selection among the objects it overlaps.
    public func arrange(_ action: String) {
        webView.evaluateJavaScript(
            "window.__timZ && window.__timZ(\(Self.jsLiteral(action)));",
            completionHandler: nil
        )
    }

    /// Swaps a media placeholder for the real element once its upload
    /// lands (any move/resize of the placeholder carries over).
    public func resolvePlaceholder(id: String, html: String) {
        webView.evaluateJavaScript(
            "window.__timResolvePlaceholder && window.__timResolvePlaceholder(\(Self.jsLiteral(id)), \(Self.jsLiteral(html)));",
            completionHandler: nil
        )
    }

    public func failPlaceholder(id: String, message: String) {
        webView.evaluateJavaScript(
            "window.__timFailPlaceholder && window.__timFailPlaceholder(\(Self.jsLiteral(id)), \(Self.jsLiteral(message)));",
            completionHandler: nil
        )
    }

    /// Tags the selected media element for replacement; false when the
    /// selection holds no media.
    public func markSelectedMedia(id: String, _ completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript(
            "window.__timMarkSelMedia ? window.__timMarkSelMedia(\(Self.jsLiteral(id))) : false"
        ) { result, _ in
            completion(result as? Bool ?? false)
        }
    }

    /// Sets (or clears, with "") the page's full-bleed background video.
    public func setPageBackgroundVideo(_ src: String) {
        webView.evaluateJavaScript(
            "window.__timSetPageBackgroundVideo && window.__timSetPageBackgroundVideo(\(Self.jsLiteral(src)));",
            completionHandler: nil
        )
    }

    /// Marks the selection (or group) desktop-only: hidden on phones by
    /// the generated mobile stylesheet.
    public func setMobileHidden(_ hidden: Bool) {
        webView.evaluateJavaScript(
            "window.__timSetMobileHidden && window.__timSetMobileHidden(\(hidden ? "true" : "false"));",
            completionHandler: nil
        )
    }

    /// Returns the phone layout to Tim's natural-height, full-width stack.
    /// The canvas checkpoints first, so this remains a normal undoable edit.
    public func resetMobileLayout() {
        webView.evaluateJavaScript(
            "window.__timResetMobileLayout && window.__timResetMobileLayout();",
            completionHandler: nil
        )
    }

    /// Applies video behavior (autoplay, loop, sound, controls) to the
    /// selected video as one coherent state.
    public func setVideoOptions(autoplay: Bool, loop: Bool, muted: Bool, controls: Bool) {
        let json = """
        {"autoplay":\(autoplay ? 1 : 0),"loop":\(loop ? 1 : 0),"muted":\(muted ? 1 : 0),"controls":\(controls ? 1 : 0)}
        """
        webView.evaluateJavaScript(
            "window.__timSetVideo && window.__timSetVideo(\(Self.jsLiteral(json)));",
            completionHandler: nil
        )
    }

    /// Points the selected video at its baked bounce file (remembering
    /// the plain one), or back again.
    public func setVideoBounceSrc(_ src: String) {
        webView.evaluateJavaScript(
            "window.__timBounceVideoSrc && window.__timBounceVideoSrc(\(Self.jsLiteral(src)));",
            completionHandler: nil
        )
    }

    public func restorePlainVideo() {
        webView.evaluateJavaScript(
            "window.__timRestorePlainVideo && window.__timRestorePlainVideo();",
            completionHandler: nil
        )
    }

    /// Clears a replace mark (the upload failed or was abandoned).
    public func unmarkMedia(id: String) {
        webView.evaluateJavaScript(
            "window.__timUnmarkMedia && window.__timUnmarkMedia(\(Self.jsLiteral(id)));",
            completionHandler: nil
        )
    }

    /// Swaps the tagged media element for a new one — placement, styling,
    /// and classes survive the swap.
    public func replaceMedia(id: String, html: String) {
        webView.evaluateJavaScript(
            "window.__timReplaceMedia && window.__timReplaceMedia(\(Self.jsLiteral(id)), \(Self.jsLiteral(html)));",
            completionHandler: nil
        )
    }

    /// Applies a global text style class (tim-style-*) to the selected
    /// object or the paragraph the caret is in.
    public func applyTextStyle(_ styleClass: String) {
        webView.evaluateJavaScript("window.__timApplyStyle && window.__timApplyStyle(\(Self.jsLiteral(styleClass)));", completionHandler: nil)
    }

    /// The page's template and its options (background, colors, layout).
    /// The page as the editor sees it. The engine is injected
    /// asynchronously, so this can be asked before there is anything to
    /// answer — and an empty answer is worse than a slow one: every field
    /// in Page Options would quietly fall back to its default, which is
    /// how a plainly gradient page came up reading "Color".
    public func pageInfo(_ completion: @escaping ([String: Any]) -> Void) {
        pageInfo(attemptsLeft: 12, completion)
    }

    private func pageInfo(attemptsLeft: Int, _ completion: @escaping ([String: Any]) -> Void) {
        webView.evaluateJavaScript("window.__timPageInfo ? window.__timPageInfo() : ''") { [weak self] result, _ in
            if let json = result as? String, !json.isEmpty,
               let data = json.data(using: .utf8),
               let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               info["template"] != nil {
                completion(info)
                return
            }
            guard let self, attemptsLeft > 0 else { completion([:]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.pageInfo(attemptsLeft: attemptsLeft - 1, completion)
            }
        }
    }

    /// Swaps the page's look for a theme's: styles, named styles, templates
    /// and fonts. Objects stay where they are. Undoable; the previous look
    /// is kept for the session so it can be restored.
    public func applyTheme(styles: String, overrides: [String: String], templates: [String: [String: Any]], fonts: String, defaultTemplate: String) {
        let o = (try? JSONSerialization.data(withJSONObject: overrides)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let t = (try? JSONSerialization.data(withJSONObject: templates)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        webView.evaluateJavaScript(
            "window.__timApplyTheme && window.__timApplyTheme(\(Self.jsLiteral(styles)), \(Self.jsLiteral(o)), \(Self.jsLiteral(t)), \(Self.jsLiteral(fonts)), \(Self.jsLiteral(defaultTemplate)));",
            completionHandler: nil
        )
    }
    public func restoreTheme() {
        webView.evaluateJavaScript("window.__timRestoreTheme && window.__timRestoreTheme();", completionHandler: nil)
    }
    /// Replaces the page's own objects with a layout's. Shared objects stay.
    public func replaceObjects(html: String) {
        webView.evaluateJavaScript("window.__timReplaceObjects && window.__timReplaceObjects(\(Self.jsLiteral(html)));", completionHandler: nil)
    }

    /// Edits a page option — applied to the page's template, so every page
    /// on that template follows.
    public func setPageOption(_ property: String, _ value: String) {
        webView.evaluateJavaScript(
            "window.__timSetPageOption && window.__timSetPageOption(\(Self.jsLiteral(property)), \(Self.jsLiteral(value)));",
            completionHandler: nil
        )
    }

    /// Sharing & search metadata: description, social image, favicon.
    /// Page motion modes ("reveal", "fade", both, or "") — stored on the
    /// body, emitted as style+script at save by PageMotion.
    /// Drop target preview while files hover over the page (nil hides it).
    /// `canReplace` offers the swap-this-picture target under the pointer.
    public func showDropHover(at point: CGPoint?, colSpan: Int = 8, rowSpan: Int = 8, label: String = "", canReplace: Bool = false) {
        let js = point.map { "window.__timDropHover && window.__timDropHover(\(Int($0.x)), \(Int($0.y)), \(colSpan), \(rowSpan), \(Self.jsLiteral(label)), \(canReplace));" }
            ?? "window.__timDropHover && window.__timDropHover(-1, -1, 0, 0, '', false);"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Marks the picture under a dropped point for replacement — true only
    /// when the pointer was inside its swap target.
    public func markMedia(at point: CGPoint, id: String, _ completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript(
            "window.__timMarkMediaAt ? window.__timMarkMediaAt(\(Int(point.x)), \(Int(point.y)), \(Self.jsLiteral(id))) : false"
        ) { result, _ in
            completion(result as? Bool ?? false)
        }
    }

    /// Reads the page as material for a NEW page — palette, fonts,
    /// writing, photographs — without needing the editor loaded.
    public func pageSeed(_ completion: @escaping ([String: Any]) -> Void) {
        webView.evaluateJavaScript(PageSeed.gatherJS) { result, _ in
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let seed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { completion([:]); return }
            completion(seed)
        }
    }

    /// Gives an imported page a strip of its own at the top, so shared
    /// objects have somewhere to live. Answers whether one was added.
    public func addCanvasBand(_ completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("window.__timAddCanvasBand ? window.__timAddCanvasBand() : false") { result, _ in
            completion((result as? Bool) ?? false)
        }
    }

    /// A page Tim laid out has a canvas; an imported snapshot does not,
    /// and a shared object has nowhere to live on one.
    public func hasCanvas(_ completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("!!document.querySelector('[data-tim-canvas]')") { result, _ in
            completion((result as? Bool) ?? false)
        }
    }

    /// Which shared objects this page has, which it keeps its own copy
    /// of, and which it has sent away.
    public func componentState(_ completion: @escaping ([String: Any]) -> Void) {
        webView.evaluateJavaScript("window.__timComponentState ? window.__timComponentState() : ''") { result, _ in
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { completion([:]); return }
            completion(info)
        }
    }

    public func setComponentOwn(_ name: String, _ own: Bool) {
        webView.evaluateJavaScript(
            "window.__timSetComponentOwn && window.__timSetComponentOwn(\(Self.jsLiteral(name)), \(own));",
            completionHandler: nil
        )
    }

    public func deleteComponent(_ name: String) {
        webView.evaluateJavaScript(
            "window.__timDeleteComponent && window.__timDeleteComponent(\(Self.jsLiteral(name)));",
            completionHandler: nil
        )
    }

    public func removeComponent(_ name: String) {
        webView.evaluateJavaScript(
            "window.__timRemoveComponent && window.__timRemoveComponent(\(Self.jsLiteral(name)));",
            completionHandler: nil
        )
    }

    public func addComponent(_ name: String, html: String) {
        webView.evaluateJavaScript(
            "window.__timAddComponent && window.__timAddComponent(\(Self.jsLiteral(name)), \(Self.jsLiteral(html)));",
            completionHandler: nil
        )
    }

    public func resetComponent(_ name: String, html: String) {
        webView.evaluateJavaScript(
            "window.__timResetComponent && window.__timResetComponent(\(Self.jsLiteral(name)), \(Self.jsLiteral(html)));",
            completionHandler: nil
        )
    }

    /// Rewrites the selected navigation object from its model (NavKit).
    public func setNav(_ json: String) {
        webView.evaluateJavaScript("window.__timNavSet && window.__timNavSet(\(Self.jsLiteral(json)));", completionHandler: nil)
    }

    public func setPageMotion(_ modes: String) {
        let js = modes.isEmpty
            ? "document.body.removeAttribute('data-tim-motion');"
            : "document.body.setAttribute('data-tim-motion', \(Self.jsLiteral(modes)));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    public func setPageMeta(_ kind: String, _ value: String) {
        webView.evaluateJavaScript(
            "window.__timSetMeta && window.__timSetMeta(\(Self.jsLiteral(kind)), \(Self.jsLiteral(value)));",
            completionHandler: nil
        )
    }

    /// Pages-style "Update Style": the selection's current look becomes
    /// the definition of its named style — every block using it follows.
    public func updateStyleFromSelection() {
        webView.evaluateJavaScript("window.__timUpdateStyleFromSel && window.__timUpdateStyleFromSel();", completionHandler: nil)
    }

    /// Creates a named style from the selection's look and applies it.
    public func createStyleFromSelection(className: String) {
        webView.evaluateJavaScript("window.__timCreateStyleFromSel && window.__timCreateStyleFromSel(\(Self.jsLiteral(className)));", completionHandler: nil)
    }

    /// Renames a custom style everywhere on the page.
    public func renameStyle(from oldClass: String, to newClass: String) {
        webView.evaluateJavaScript("window.__timRenameStyle && window.__timRenameStyle(\(Self.jsLiteral(oldClass)), \(Self.jsLiteral(newClass)));", completionHandler: nil)
    }

    /// Deletes a custom style; its blocks fall back to Body.
    public func deleteStyle(className: String) {
        webView.evaluateJavaScript("window.__timDeleteStyle && window.__timDeleteStyle(\(Self.jsLiteral(className)));", completionHandler: nil)
    }

    /// Clears the selection's local typography tweaks so it derives from
    /// its named style again.
    public func revertSelectionToStyle() {
        webView.evaluateJavaScript("window.__timRevertSel && window.__timRevertSel();", completionHandler: nil)
    }

    /// Makes sure the page loads a Google Font (a <link> that persists
    /// when the page is saved), so styled text renders after publish.
    public func ensurePageFont(family: String, cssURL: String) {
        webView.evaluateJavaScript(
            "window.__timEnsureFont && window.__timEnsureFont(\(Self.jsLiteral(family)), \(Self.jsLiteral(cssURL)));",
            completionHandler: nil
        )
    }

    /// Live styling from the Inspector: sets one CSS property on the
    /// selected element (design vocabulary in the UI, CSS underneath).
    /// Crop editing for the selected picture, the way Keynote edits a mask.
    public func setCropping(_ on: Bool) {
        webView.evaluateJavaScript("window.__timCropSel && window.__timCropSel(\(on ? "true" : "false"));", completionHandler: nil)
    }
    public func setCropScale(_ percent: Double) {
        webView.evaluateJavaScript("window.__timSetCropScale && window.__timSetCropScale(\(Int(percent)));", completionHandler: nil)
    }
    public func resetCrop() {
        webView.evaluateJavaScript("window.__timResetCrop && window.__timResetCrop();", completionHandler: nil)
    }
    /// How text treats the selected object: "auto", "around", "above-below", or "none".
    public func setSelectionWrap(_ mode: String) {
        webView.evaluateJavaScript("window.__timSetWrap && window.__timSetWrap(\(Self.jsLiteral(mode)));", completionHandler: nil)
    }
    public func setSelectionStyle(_ property: String, _ value: String) {
        webView.evaluateJavaScript(
            "window.__timSetStyle && window.__timSetStyle(\(Self.jsLiteral(property)), \(Self.jsLiteral(value)));",
            completionHandler: nil
        )
    }

    /// Deselects — back to the Page pane.
    public func clearSelection() {
        webView.evaluateJavaScript("window.__timDeselect && window.__timDeselect();", completionHandler: nil)
    }

    /// Selects an enclosing element from the breadcrumb path.
    public func selectAncestor(_ index: Int) {
        webView.evaluateJavaScript("window.__timSelectAncestor && window.__timSelectAncestor(\(index));", completionHandler: nil)
    }

    /// Template membership: wraps the selection so it appears on every
    /// page of the template (injected on Done), or unwraps it.
    public func setSelectionOnEveryPage(_ on: Bool, name: String) {
        if on {
            webView.evaluateJavaScript("window.__timWrapSelTemplate && window.__timWrapSelTemplate(\(Self.jsLiteral(name)));", completionHandler: nil)
        } else {
            webView.evaluateJavaScript("window.__timUnwrapSelTemplate && window.__timUnwrapSelTemplate();", completionHandler: nil)
        }
    }

    /// The selected element's HTML (Layout selection).
    public func selectedHTML(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__timSelHTML ? window.__timSelHTML() : ''") { result, _ in
            completion(result as? String ?? "")
        }
    }

    /// Replaces the selected element with new HTML.
    public func replaceSelection(with html: String) {
        webView.evaluateJavaScript("window.__timReplaceSel && window.__timReplaceSel(\(Self.jsLiteral(html)));", completionHandler: nil)
    }

    /// Google Fonts the page already links (data-tim-font).
    public func pageFonts(_ completion: @escaping ([String]) -> Void) {
        webView.evaluateJavaScript("window.__timPageFonts ? window.__timPageFonts() : '[]'") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { completion([]); return }
            completion(array)
        }
    }

    /// The page's canvas region, serialized for the source round trip.
    public func canvasHTML(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__timCanvasHTML ? window.__timCanvasHTML() : ''") { result, _ in
            completion(result as? String ?? "")
        }
    }

    /// Collects (old text, new text) pairs recorded since edit mode began.
    public func collectEdits(_ completion: @escaping ([(String, String)]) -> Void) {
        webView.evaluateJavaScript("window.__timCollect ? window.__timCollect() : '[]'") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String]]
            else {
                completion([])
                return
            }
            completion(array.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil })
        }
    }

    /// Records the first-seen old value and current value of every text
    /// node changed during this edit session (outside the canvas, which
    /// round-trips wholesale), and provides the canvas serializer.
    private static let editTrackerJS = """
    (function () {
      if (window.__timTracker) { return; }
      var edits = new Map();
      var observer = new MutationObserver(function (list) {
        for (var i = 0; i < list.length; i++) {
          var m = list[i];
          if (m.type !== 'characterData') { continue; }
          var p = m.target.parentElement;
          if (p && p.closest && p.closest('[data-tim-canvas]')) { continue; }
          if (!edits.has(m.target)) { edits.set(m.target, m.oldValue); }
        }
      });
      observer.observe(document.documentElement, {
        characterData: true, characterDataOldValue: true, subtree: true
      });
      window.__timTracker = observer;
      window.__timCollect = function () {
        var out = [];
        edits.forEach(function (oldValue, node) {
          var now = node.textContent;
          if (oldValue !== null && now !== oldValue) { out.push([oldValue, now]); }
        });
        return JSON.stringify(out);
      };
      window.__timPageFonts = function () {
        var out = [];
        var links = document.querySelectorAll('link[data-tim-font]');
        for (var i = 0; i < links.length; i++) { out.push(links[i].getAttribute('data-tim-font')); }
        return JSON.stringify(out);
      };
      window.__timCanvasHTML = function () {
        var canvas = document.querySelector('[data-tim-canvas]');
        if (!canvas) { return ''; }
        var clone = canvas.cloneNode(true);
        var editables = clone.querySelectorAll('[contenteditable]');
        for (var j = 0; j < editables.length; j++) { editables[j].removeAttribute('contenteditable'); }
        var loading = clone.querySelectorAll('.tim-loading');
        for (var k = 0; k < loading.length; k++) { loading[k].classList.remove('tim-loading'); }
        var chrome = clone.querySelectorAll('[id^="__tim-"]');
        for (var c = 0; c < chrome.length; c++) { chrome[c].remove(); }
        return clone.outerHTML;
      };
    })();
    """

    /// The canvas layer, Fluid Engine-style: a true two-axis grid — 24
    /// columns, fixed-unit rows — where every object owns an explicit
    /// rectangle of cells (grid-area). Dragging is completely free and
    /// snaps to cells (graph-paper feedback while dragging); objects may
    /// overlap; resize from any edge snaps to cells; text rows are minimums
    /// so text still grows downward. DOM order is kept sorted by (row, col)
    /// after every drag, so the mobile collapse stacks in reading order.
    private static let canvasJS = """
    (function () {
      if (window.__timCanvasLayer) { return; }
      var doc = document;

      if (!doc.querySelector('style[data-tim-styles]')) {
        var st = doc.createElement('style');
        st.setAttribute('data-tim-styles', '');
        st.textContent = '.tim-canvas{display:grid;grid-template-columns:repeat(24,1fr);grid-auto-rows:32px;gap:16px;align-items:stretch;box-sizing:border-box;width:100vw;margin-left:calc(50% - 50vw);margin-right:calc(50% - 50vw);padding:48px max(32px,calc(50vw - 660px));min-height:70vh}' +
          '.tim-object{min-width:0}' +
          '.tim-text{min-height:1em;outline:none;padding:2px 4px}' +
          'html.tim-editing .tim-object{cursor:grab}' +
          'html.tim-editing .tim-object:active{cursor:grabbing}' +
          '.tim-canvas img.tim-object{width:100%;height:100%;object-fit:cover;display:block}' +
          '.tim-canvas video.tim-object{width:100%;display:block}' +
          '.tim-canvas audio.tim-object{width:100%}' +
          '.tim-object.tim-loading{background:rgba(10,132,255,0.07);outline:1.5px dashed rgba(10,132,255,0.45);outline-offset:-1px;border-radius:6px;min-height:48px}' +
          '@media (max-width:700px){.tim-canvas{grid-template-columns:1fr;grid-auto-rows:auto;padding:24px 16px;min-height:0}.tim-canvas>.tim-object{grid-area:auto !important}}' +
          '.tim-style-title{font-family:var(--tim-font-heading,inherit);font-size:2.5rem;font-weight:700;line-height:1.15}' +
          '.tim-style-heading{font-family:var(--tim-font-heading,inherit);font-size:1.6rem;font-weight:700;line-height:1.25}' +
          '.tim-style-subheading{font-family:var(--tim-font-heading,inherit);font-size:1.25rem;font-weight:600;line-height:1.3}' +
          '.tim-style-body{font-family:var(--tim-font-body,inherit);font-size:1rem;line-height:1.6}' +
          '.tim-style-caption{font-size:0.85rem;opacity:0.7;line-height:1.4}';
        doc.head.appendChild(st);
      }

      var COLS = 24;
      var MOBILE_COLS = 8;

      // The mobile layout: explicit 8-column placements per object id,
      // living in <style data-tim-mobile-layout>. Editing at phone width
      // reads and writes THIS map — the desktop page never changes when
      // you design for the phone.
      var mobileLayout = {};
      // An untouched phone layout remains a self-healing, full-width
      // reading-order stack. The first deliberate move or resize turns it
      // into a freeform custom grid. Older saved layouts predate this flag
      // and are conservatively treated as custom.
      var mobileLayoutMode = 'stack';
      (function parseMobileLayout() {
        var el = doc.querySelector('style[data-tim-mobile-layout]');
        if (!el) { return; }
        try { mobileLayout = JSON.parse(el.getAttribute('data-props') || '{}') || {}; } catch (e) {}
        mobileLayoutMode = el.getAttribute('data-mode') === 'stack' ? 'stack' : 'custom';
      })();
      function syncMobileModeClass() {
        doc.documentElement.classList.toggle('tim-mobile-custom', Object.keys(mobileLayout).length > 0);
      }
      syncMobileModeClass();
      function mobileActive() { return collapsed() && Object.keys(mobileLayout).length > 0; }
      function colCount() { return mobileActive() ? MOBILE_COLS : COLS; }
      // Type sized BY HAND at phone width is the author's word for that
      // layout: it lives in its own mobile rule (higher specificity than
      // the synthesized readability sizes, so it always wins), leaves the
      // desktop size untouched, and persists with the page.
      var mobileType = {};
      (function parseMobileType() {
        var el = doc.querySelector('style[data-tim-mobile-type]');
        if (!el) { return; }
        try { mobileType = JSON.parse(el.getAttribute('data-props') || '{}') || {}; } catch (e) {}
      })();
      function writeMobileType() {
        var st = doc.querySelector('style[data-tim-mobile-type]');
        if (!st) {
          st = doc.createElement('style');
          st.setAttribute('data-tim-mobile-type', '');
          doc.head.appendChild(st);
        }
        var css = '@media (max-width: 700px){\\n';
        for (var id in mobileType) {
          css += '.tim-canvas [data-tim-id="' + id + '"]{font-size:' + mobileType[id] + 'px !important}\\n';
        }
        css += '}';
        st.textContent = css;
        st.setAttribute('data-props', JSON.stringify(mobileType));
      }
      function ensureObjectId(el) {
        var id = el.getAttribute('data-tim-id');
        if (!id) {
          id = 't' + Math.random().toString(16).slice(2, 8);
          el.setAttribute('data-tim-id', id);
        }
        return id;
      }
      function mobileStackRows(el, availableWidth) {
        var height = 0;
        var nw = el.naturalWidth || el.videoWidth || 0;
        var nh = el.naturalHeight || el.videoHeight || 0;
        if (el.matches && el.matches('img,video') && nw > 0 && nh > 0) {
          height = availableWidth * nh / nw;
        } else {
          // Fixed grid tracks otherwise masquerade as content height. Let
          // the object hug its contents for one measurement, then restore
          // the authored styles. Text and groups can now grow without
          // colliding with the next object in the default stack.
          var prevHeight = el.style.height;
          var prevAlign = el.style.alignSelf;
          el.style.height = 'max-content';
          el.style.alignSelf = 'start';
          height = Math.max(el.scrollHeight || 0, el.getBoundingClientRect().height || 0);
          el.style.height = prevHeight;
          el.style.alignSelf = prevAlign;
        }
        return Math.max(1, Math.ceil((Math.max(1, height) + 16) / 48));
      }
      function reflowMobileStack() {
        if (mobileLayoutMode !== 'stack') { return; }
        var canvas = doc.querySelector('[data-tim-canvas]');
        if (!canvas) { return; }
        var cs = getComputedStyle(canvas);
        var availableWidth = Math.max(200, 390 - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0));
        var row = 1;
        var all = Array.prototype.slice.call(canvas.querySelectorAll('.tim-object')).filter(function (el) {
          return canvasFor(el) === canvas;
        });
        // Hidden decorations remain reachable while editing, but live at
        // the end so they cannot leave mysterious holes in the published
        // reading flow.
        var objs = all.filter(function (el) { return !el.hasAttribute('data-tim-mobile-hidden'); })
          .concat(all.filter(function (el) { return el.hasAttribute('data-tim-mobile-hidden'); }));
        for (var i = 0; i < objs.length; i++) {
          var el = objs[i];
          var rows = mobileStackRows(el, availableWidth);
          mobileLayout[ensureObjectId(el)] = [row, 1, row + rows, MOBILE_COLS + 1];
          row += rows;
        }
      }
      // Every top-level object must hold a place in an explicit mobile
      // layout — anything that slipped through (a group made after the
      // freeze, an object added by other means) joins at the bottom,
      // full width. Heals existing pages on entry.
      function ensureMobileCoverage() {
        var canvas = doc.querySelector('[data-tim-canvas]');
        if (!canvas || !Object.keys(mobileLayout).length) { return; }
        var objs = Array.prototype.slice.call(canvas.querySelectorAll('.tim-object'))
          .filter(function (el) { return canvasFor(el) === canvas; });
        var width = collapsed() ? Math.max(200, canvas.clientWidth - 32) : 358;
        for (var i = 0; i < objs.length; i++) {
          var el = objs[i];
          var id = el.getAttribute('data-tim-id');
          if (id && mobileLayout[id]) { continue; }
          // Full width, sized to its own content — never the desktop rows,
          // which stretched or crushed everything they touched.
          var rows = mobileStackRows(el, width);
          // And in reading order: directly beneath the nearest earlier
          // object that already has a place, pushing the rest down. An
          // object added at the top of the page belongs at the top here.
          var at = 1;
          for (var j = i - 1; j >= 0; j--) {
            var prevID = objs[j].getAttribute('data-tim-id');
            if (prevID && mobileLayout[prevID]) { at = mobileLayout[prevID][2]; break; }
          }
          for (var key in mobileLayout) {
            var a = mobileLayout[key];
            if (a[0] >= at) { a[0] += rows; a[2] += rows; }
          }
          mobileLayout[ensureObjectId(el)] = [at, 1, at + rows, MOBILE_COLS + 1];
        }
      }
      function writeMobileLayout() {
        var styleEl = doc.querySelector('style[data-tim-mobile-layout]');
        if (!styleEl) {
          styleEl = doc.createElement('style');
          styleEl.setAttribute('data-tim-mobile-layout', '');
          doc.head.appendChild(styleEl);
        }
        for (var stale in mobileLayout) {
          if (!doc.querySelector('[data-tim-id="' + stale + '"]')) { delete mobileLayout[stale]; }
        }
        ensureMobileCoverage();
        reflowMobileStack();
        syncMobileModeClass();
        // Once customized, overlap on the phone grid is the author's call,
        // exactly as on desktop — objects go where they're put. (An earlier "politeness"
        // pass pushed anything overlapping downward, which read as the
        // editor refusing a perfectly good spot.)
        var css = '@media (max-width: 700px){\\n'
          + '.tim-canvas{grid-template-columns:repeat(8, 1fr) !important;grid-auto-rows:32px !important}\\n'
          // Nothing may inherit its DESKTOP columns at phone width; the
          // per-object rules below are more specific and still win.
          + '.tim-canvas>.tim-object{grid-column:1 / -1 !important}\\n'
          // A group is a desktop composition boundary, not a reason for
          // its contents to become illegible on a phone.
          + '.tim-canvas .tim-container{grid-template-columns:minmax(0,1fr) !important;grid-auto-rows:auto !important;height:auto !important;align-self:start !important}\\n'
          + '.tim-canvas .tim-container>.tim-object{grid-area:auto !important;transform:none !important;margin-left:0 !important;margin-right:0 !important}\\n';
        if (mobileLayoutMode === 'stack') {
          css += '.tim-canvas>.tim-object{transform:none !important;margin-left:0 !important;margin-right:0 !important}\\n';
        }
        for (var id2 in mobileLayout) {
          var a = mobileLayout[id2];
          css += '.tim-canvas .tim-object[data-tim-id="' + id2 + '"]{grid-area:'
            + a[0] + ' / ' + a[1] + ' / ' + a[2] + ' / ' + a[3] + ' !important;margin-top:0 !important}\\n';
        }
        css += '}';
        styleEl.textContent = css;
        styleEl.setAttribute('data-props', JSON.stringify(mobileLayout));
        styleEl.setAttribute('data-mode', mobileLayoutMode);
      }
      // Cross-layout review: edits on one layout that leave a GUESS on the
      // other (a new object's default placement, text that outgrew its
      // fixed mobile box) flag that object for review over there. Routine
      // edits — shared content, deletions, styling — never nag.
      var reviewSets = { desktop: {}, mobile: {} };
      function flagReview(mode, el) {
        reviewSets[mode][ensureObjectId(el)] = 1;
      }
      window.__timReviewCounts = function () {
        return JSON.stringify({
          desktop: Object.keys(reviewSets.desktop).length,
          mobile: Object.keys(reviewSets.mobile).length
        });
      };
      window.__timBeginReview = function (mode) {
        var set = reviewSets[mode];
        var first = null;
        for (var id in set) {
          var el = doc.querySelector('[data-tim-id="' + id + '"]');
          if (el) {
            el.setAttribute('data-tim-review', '');
            if (!first) { first = el; }
          }
        }
        if (first) { first.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
      };
      function clearReview(el) {
        if (!el || !el.getAttribute) { return; }
        var id = el.getAttribute('data-tim-id');
        if (!id) { return; }
        el.removeAttribute('data-tim-review');
        delete reviewSets.desktop[id];
        delete reviewSets.mobile[id];
      }
      // Text with a fixed mobile box that its content no longer fits —
      // the silent-overlap case, caught on every entry into phone width.
      function scanMobileOverflow() {
        if (mobileLayoutMode === 'stack') {
          writeMobileLayout();
          return;
        }
        for (var id in mobileLayout) {
          var el = doc.querySelector('[data-tim-id="' + id + '"]');
          if (!el || !el.classList || !el.classList.contains('tim-text')) { continue; }
          var a = mobileLayout[id];
          var boxH = (a[2] - a[0]) * 48 - 16;
          var prev = el.style.height;
          el.style.height = 'max-content';
          var content = el.scrollHeight;
          el.style.height = prev;
          if (content > boxH + 4) { reviewSets.mobile[id] = 1; }
        }
      }

      // First entry into phone-width editing: start with the boring good
      // answer — every top-level object, full width, in reading order.
      // Natural content height determines the rows. Only an intentional
      // mobile drag/resize graduates this stack into a custom 8-col grid.
      window.__timEnsureMobileLayout = function () {
        if (!collapsed()) { return; }
        if (Object.keys(mobileLayout).length) {
          // Heal any objects that slipped in without a mobile place.
          writeMobileLayout();
          scanMobileOverflow();
          window.__timBeginReview('mobile');
          layout();
          return;
        }
        var canvas = doc.querySelector('[data-tim-canvas]');
        if (!canvas) { return; }
        var objs = Array.prototype.slice.call(canvas.querySelectorAll('.tim-object')).filter(function (el) {
          // Top-level objects only: a group's children live in the
          // group's own grid and travel with it.
          if (canvasFor(el) !== canvas) { return false; }
          return el.getBoundingClientRect().height > 0 || !el.hasAttribute('data-tim-mobile-hidden');
        });
        if (!objs.length) { return; }
        var cs2 = getComputedStyle(canvas);
        var innerWidth = Math.max(200, canvas.clientWidth
          - (parseFloat(cs2.paddingLeft) || 0) - (parseFloat(cs2.paddingRight) || 0));
        var row = 1;
        mobileLayoutMode = 'stack';
        for (var i = 0; i < objs.length; i++) {
          var rows = mobileStackRows(objs[i], innerWidth);
          mobileLayout[ensureObjectId(objs[i])] = [row, 1, row + rows, MOBILE_COLS + 1];
          row += rows;
        }
        writeMobileLayout();
        layout();
        notifySel(true);
      };
      window.__timResetMobileLayout = function () {
        if (!collapsed()) { return; }
        checkpoint('mobile-reset');
        mobileLayoutMode = 'stack';
        ensureMobileCoverage();
        reflowMobileStack();
        writeMobileLayout();
        scanMobileOverflow();
        layout();
        notifySel(true);
      };

      // Editor chrome styles: ALWAYS (re)injected so every page gets the
      // current rules, and stripped from saves like the overlay itself.
      var editorCSS = doc.getElementById('__tim-editor-css');
      if (!editorCSS) {
        editorCSS = doc.createElement('style');
        editorCSS.id = '__tim-editor-css';
        doc.head.appendChild(editorCSS);
      }
      editorCSS.textContent =
        'html.tim-editing .tim-object{cursor:grab;touch-action:none}' +
        'html.tim-editing .tim-object:active{cursor:grabbing}' +
        'html.tim-editing [data-tim-handle]{touch-action:none}' +
        '.tim-object.tim-loading{background:rgba(10,132,255,0.07);outline:1.5px dashed rgba(10,132,255,0.45);outline-offset:-1px;border-radius:6px;min-height:48px}' +
        '.tim-media-loading{position:relative;min-height:64px;border-radius:8px;display:flex;align-items:center;justify-content:center;' +
          'outline:1.5px dashed rgba(127,127,127,0.5);outline-offset:-1px;' +
          'background:linear-gradient(100deg,rgba(127,127,127,0.10) 30%,rgba(127,127,127,0.22) 50%,rgba(127,127,127,0.10) 70%);' +
          'background-size:200% 100%;animation:timShimmer 1.4s linear infinite}' +
        '@keyframes timShimmer{from{background-position:200% 0}to{background-position:-200% 0}}' +
        '.tim-media-loading-label{font:500 12px -apple-system,sans-serif;color:rgba(127,127,127,0.95);padding:4px 12px;text-align:center}' +
        '.tim-media-failed{animation:none;outline-color:rgba(255,59,48,0.65);background:rgba(255,59,48,0.06)}' +
        '.tim-media-replacing{outline:2px dashed rgba(10,132,255,0.7) !important;outline-offset:-1px;animation:timPulse 1.1s ease-in-out infinite}' +
        '@keyframes timPulse{50%{opacity:0.55}}' +
        '@media (max-width:700px){html.tim-editing [data-tim-mobile-hidden]{display:revert !important;opacity:0.25;outline:1.5px dashed rgba(127,127,127,0.5);outline-offset:-1px}}' +
        // The editor's mirror of the saved mobile rule: media renders at
        // its own aspect at phone width, never stretched into its grid
        // box — so what you see while editing is what publishes.
        '@media (max-width:700px){html.tim-editing .tim-canvas img.tim-object,html.tim-editing .tim-canvas video.tim-object{height:auto !important;align-self:start}}' +
        // Off-page objects: reachable (the page scrolls sideways while
        // editing) and unmistakable (faded, dashed) — never just gone.
        // One scroll context: the WINDOW scrolls onto the pasteboard.
        // (body overflow-x:auto would nest a second scrollport that
        // clips the overflow — the bug that hid everything.)
        'html.tim-editing{overflow-x:auto !important}' +
        'html.tim-editing body{overflow-x:visible !important;overflow-y:visible !important}' +
        // The pasteboard is always there while editing: a probe extends
        // the scrollable area past the page edge so there is somewhere
        // to put things even before anything lives out there.
        'html.tim-editing body::after{content:"";position:absolute;top:0;left:calc(100vw + 320px);width:1px;height:1px;}' +
        // The bottom is a pasteboard too: while editing, the canvas keeps
        // a third of a screen of empty rows under its last object, so
        // there is always somewhere to drop, drag, and grab handles.
        'html.tim-editing .tim-canvas:not(.tim-container):not(.tim-band){padding-bottom:36vh !important}' +
        // Links look exactly as they will, and do nothing at all. A live
        // link while editing is a trapdoor: press one to drag the nav and
        // WebKit starts dragging the LINK, or follows it on release.
        'html.tim-editing a{-webkit-user-drag:none !important}' +
        'html.tim-editing [data-tim-offpage]{opacity:0.4;filter:saturate(0.5);outline:1.5px dashed rgba(127,127,127,0.55);outline-offset:2px}' +
        'html.tim-editing [data-tim-review]{outline:2px solid rgba(255,159,10,0.85) !important;outline-offset:3px;animation:timReviewPulse 1.6s ease-in-out infinite}' +
        '@keyframes timReviewPulse{50%{outline-color:rgba(255,159,10,0.25)}}';

      var overlay = doc.createElement('div');
      overlay.id = '__tim-overlay';
      overlay.style.cssText = 'position:absolute;left:0;top:0;z-index:2147483000;pointer-events:none;';
      var gridBox = doc.createElement('div');
      gridBox.style.cssText = 'position:absolute;pointer-events:none;display:none;';
      var box = doc.createElement('div');
      box.style.cssText = 'position:absolute;border:1.5px solid #0a84ff;pointer-events:none;display:none;box-sizing:border-box;';
      var badge = doc.createElement('div');
      // The badge doubles as the move grip — grab it to drag the object.
      badge.style.cssText = 'position:absolute;background:#0a84ff;color:#fff;font:11px -apple-system,sans-serif;padding:3px 8px;border-radius:5px;display:none;white-space:nowrap;pointer-events:auto;cursor:grab;';
      var hoverBox = doc.createElement('div');
      hoverBox.style.cssText = 'position:absolute;border:1px dashed rgba(10,132,255,0.55);pointer-events:none;display:none;box-sizing:border-box;';
      // A group sized smaller than its contents: the dotted line shows
      // where the contents actually reach.
      var extentBox = doc.createElement('div');
      extentBox.style.cssText = 'position:absolute;border:1.5px dotted rgba(10,132,255,0.5);border-radius:4px;pointer-events:none;display:none;box-sizing:border-box;';
      var groupBox = doc.createElement('div');
      groupBox.style.cssText = 'position:absolute;pointer-events:none;';
      // Box-model guides, the way layout tools draw them: a dashed line
      // inside the frame for padding (arrows pointing in), one outside
      // for margin (arrows pointing out). They live inside the selection
      // box so they turn with a rotated object.
      var GUIDE = 'rgba(10,132,255,0.55)';
      var padBox = doc.createElement('div');
      padBox.style.cssText = 'position:absolute;border:1px dashed ' + GUIDE + ';pointer-events:none;display:none;box-sizing:border-box;';
      var marBox = doc.createElement('div');
      marBox.style.cssText = 'position:absolute;border:1px dashed ' + GUIDE + ';pointer-events:none;display:none;box-sizing:border-box;';
      var guideArrows = [];
      function mkArrow(parent) {
        var a = doc.createElement('div');
        a.style.cssText = 'position:absolute;width:6px;height:6px;border-right:1.5px solid ' + GUIDE + ';border-bottom:1.5px solid ' + GUIDE + ';pointer-events:none;display:none;';
        parent.appendChild(a); guideArrows.push(a); return a;
      }
      // Eight arrows: [0-3] padding (n,e,s,w pointing inward), [4-7] margin (pointing outward).
      for (var gi = 0; gi < 8; gi++) { mkArrow(box); }
      box.appendChild(padBox); box.appendChild(marBox);
      var dropBox = doc.createElement('div');
      dropBox.style.cssText = 'position:absolute;border:2px dashed rgba(10,132,255,0.7);background:rgba(10,132,255,0.08);border-radius:6px;pointer-events:none;display:none;box-sizing:border-box;';
      overlay.appendChild(gridBox); overlay.appendChild(hoverBox); overlay.appendChild(extentBox); overlay.appendChild(box); overlay.appendChild(badge); overlay.appendChild(groupBox); overlay.appendChild(dropBox);
      // Arrow glyph: a chevron; rotation picks its direction. 0 = points right.
      function aimArrow(a, x, y, deg) {
        a.style.display = 'block';
        a.style.left = (x - 3) + 'px'; a.style.top = (y - 3) + 'px';
        a.style.transform = 'rotate(' + (deg - 45) + 'deg)';
      }
      function layoutGuides(w0, h0) {
        for (var i = 0; i < guideArrows.length; i++) { guideArrows[i].style.display = 'none'; }
        padBox.style.display = 'none'; marBox.style.display = 'none';
        if (!sel || !isObject(sel)) { return; }
        var cs = getComputedStyle(sel);
        var pt = parseFloat(cs.paddingTop) || 0, pr = parseFloat(cs.paddingRight) || 0, pb = parseFloat(cs.paddingBottom) || 0, pl = parseFloat(cs.paddingLeft) || 0;
        var mt = parseFloat(cs.marginTop) || 0, mr = parseFloat(cs.marginRight) || 0, mb = parseFloat(cs.marginBottom) || 0, ml = parseFloat(cs.marginLeft) || 0;
        if (pt + pr + pb + pl > 0 && w0 > pl + pr + 4 && h0 > pt + pb + 4) {
          padBox.style.display = 'block';
          padBox.style.left = pl + 'px'; padBox.style.top = pt + 'px';
          padBox.style.width = (w0 - pl - pr) + 'px'; padBox.style.height = (h0 - pt - pb) + 'px';
          if (pt >= 9) { aimArrow(guideArrows[0], w0 / 2, pt / 2, 90); }
          if (pr >= 9) { aimArrow(guideArrows[1], w0 - pr / 2, h0 / 2, 180); }
          if (pb >= 9) { aimArrow(guideArrows[2], w0 / 2, h0 - pb / 2, 270); }
          if (pl >= 9) { aimArrow(guideArrows[3], pl / 2, h0 / 2, 0); }
        }
        if (mt + mr + mb + ml > 0) {
          marBox.style.display = 'block';
          marBox.style.left = (-ml) + 'px'; marBox.style.top = (-mt) + 'px';
          marBox.style.width = (w0 + ml + mr) + 'px'; marBox.style.height = (h0 + mt + mb) + 'px';
          if (mt >= 9) { aimArrow(guideArrows[4], w0 / 2, -mt / 2, 270); }
          if (mr >= 9) { aimArrow(guideArrows[5], w0 + mr / 2, h0 / 2, 0); }
          if (mb >= 9) { aimArrow(guideArrows[6], w0 / 2, h0 + mb / 2, 90); }
          if (ml >= 9) { aimArrow(guideArrows[7], -ml / 2, h0 / 2, 180); }
        }
      }
      // Where dropped files would land: the target cells, live.
      var dropLabel = doc.createElement('div');
      dropLabel.style.cssText = 'position:absolute;left:8px;top:8px;background:#0a84ff;color:#fff;font:11px -apple-system,sans-serif;padding:3px 8px;border-radius:5px;white-space:nowrap;';
      dropBox.appendChild(dropLabel);
      // Dropping a photo ONTO a photo is ambiguous — add another, or swap
      // this one? The answer is where you let go: a small target appears
      // over the picture under the pointer, and only that target replaces.
      var replaceBox = doc.createElement('div');
      replaceBox.style.cssText = 'position:absolute;display:none;pointer-events:none;box-sizing:border-box;'
        + 'border-radius:999px;border:2px solid #0a84ff;font:600 12px -apple-system,sans-serif;'
        + 'text-align:center;white-space:nowrap;overflow:hidden;'
        + 'box-shadow:0 2px 12px rgba(0,0,0,0.22);transition:background .12s,color .12s;';
      overlay.appendChild(replaceBox);
      function mediaUnder(x, y) {
        var el = doc.elementFromPoint(x, y);
        if (!el || !el.closest) { return null; }
        var obj = el.closest('.tim-object');
        if (!obj) { return null; }
        return (obj.matches && obj.matches('img,video')) ? obj : obj.querySelector('img,video');
      }
      // The target lives inside the picture, never larger than it.
      function replaceRect(media) {
        var r = media.getBoundingClientRect();
        if (r.width < 60 || r.height < 26) { return null; }
        var w = Math.max(56, Math.min(116, r.width - 8));
        var h = Math.max(22, Math.min(34, r.height - 8));
        return { x: r.left + (r.width - w) / 2, y: r.top + (r.height - h) / 2, w: w, h: h };
      }
      function inRect(rect, x, y) {
        return x >= rect.x && x <= rect.x + rect.w && y >= rect.y && y <= rect.y + rect.h;
      }
      window.__timMarkMediaAt = function (x, y, id) {
        var media = mediaUnder(x, y);
        if (!media) { return false; }
        var rect = replaceRect(media);
        if (!rect || !inRect(rect, x, y)) { return false; }
        checkpoint('media');
        media.setAttribute('data-tim-replace', id);
        media.classList.add('tim-media-replacing');
        return true;
      };
      window.__timDropHover = function (x, y, colSpan, rowSpan, label, canReplace) {
        var canvas = doc.querySelector('[data-tim-canvas]');
        if (x < 0 || !canvas) { dropBox.style.display = 'none'; replaceBox.style.display = 'none'; return; }
        var media = canReplace ? mediaUnder(x, y) : null;
        var rect = media ? replaceRect(media) : null;
        if (rect) {
          var active = inRect(rect, x, y);
          replaceBox.style.display = 'block';
          replaceBox.style.left = (rect.x + window.scrollX) + 'px';
          replaceBox.style.top = (rect.y + window.scrollY) + 'px';
          replaceBox.style.width = rect.w + 'px';
          replaceBox.style.height = rect.h + 'px';
          replaceBox.style.lineHeight = (rect.h - 4) + 'px';
          replaceBox.textContent = rect.w >= 80 ? 'Replace' : '⇄';
          replaceBox.style.background = active ? '#0a84ff' : 'rgba(255,255,255,0.94)';
          replaceBox.style.color = active ? '#fff' : '#0a84ff';
          if (active) { dropBox.style.display = 'none'; return; }
        } else {
          replaceBox.style.display = 'none';
        }
        dropLabel.textContent = label || '';
        dropLabel.style.display = label ? 'block' : 'none';
        var cell = cellAt(canvas, x, y);
        var g = gridInfo(canvas);
        var cr = canvas.getBoundingClientRect();
        var cols = Math.min(colSpan || 8, colCount());
        var left = cr.left + window.scrollX + (cell.cs - 1) * (g.colW + g.gap);
        var top = cr.top + window.scrollY + (cell.rs - 1) * (g.rowH + g.rowGap);
        dropBox.style.display = 'block';
        dropBox.style.left = left + 'px'; dropBox.style.top = top + 'px';
        dropBox.style.width = (cols * g.colW + (cols - 1) * g.gap) + 'px';
        dropBox.style.height = ((rowSpan || 8) * g.rowH + ((rowSpan || 8) - 1) * g.rowGap) + 'px';
      };
      function cellAt(canvas, clientX, clientY) {
        var g = gridInfo(canvas);
        var cr = canvas.getBoundingClientRect();
        var cs = 1 + Math.floor((clientX - cr.left) / (g.colW + g.gap));
        var rs = 1 + Math.floor((clientY - cr.top) / (g.rowH + g.rowGap));
        return { rs: Math.max(1, rs), cs: Math.max(1, Math.min(colCount(), cs)) };
      }
      var handles = {};
      ['w', 'e', 'n', 's', 'nw', 'ne', 'sw', 'se'].forEach(function (k) {
        // Forgiving targets: a 22px hit area around an 11px dot.
        var h = doc.createElement('div');
        h.style.cssText = 'position:absolute;width:22px;height:22px;background:transparent;pointer-events:auto;display:none;';
        var dot = doc.createElement('div');
        dot.style.cssText = 'position:absolute;left:5.5px;top:5.5px;width:11px;height:11px;background:#fff;border:1.5px solid #0a84ff;border-radius:50%;box-sizing:border-box;pointer-events:none;';
        h.appendChild(dot);
        h.style.cursor = (k === 'w' || k === 'e') ? 'ew-resize'
          : (k === 'n' || k === 's') ? 'ns-resize'
          : (k === 'ne' || k === 'sw') ? 'nesw-resize' : 'nwse-resize';
        h.setAttribute('data-tim-handle', k);
        overlay.appendChild(h); handles[k] = h;
      });
      // The rotation lollipop: a stem off the box's top edge ending in a
      // knob — grab it and turn. The touch-first way to rotate (fingers
      // can't option-drag); on the Mac both ways work.
      var rotStem = doc.createElement('div');
      rotStem.style.cssText = 'position:absolute;width:1.5px;height:22px;background:#0a84ff;opacity:0.85;display:none;pointer-events:none;';
      overlay.appendChild(rotStem);
      var rotKnob = doc.createElement('div');
      rotKnob.style.cssText = 'position:absolute;width:28px;height:28px;background:transparent;pointer-events:auto;display:none;cursor:grab;';
      var rotDot = doc.createElement('div');
      rotDot.style.cssText = 'position:absolute;left:6px;top:6px;width:16px;height:16px;background:#fff;border:1.5px solid #0a84ff;border-radius:50%;box-sizing:border-box;pointer-events:none;color:#0a84ff;font:600 10px/13px -apple-system,sans-serif;text-align:center;';
      rotDot.textContent = '\\u21bb';
      rotKnob.appendChild(rotDot);
      rotKnob.setAttribute('data-tim-handle', 'rotate');
      overlay.appendChild(rotKnob);
      // The page's right edge, drawn — Keynote's slide boundary. Only
      // meaningful while editing, when the pasteboard extends past it.
      var pageEdge = doc.createElement('div');
      pageEdge.style.cssText = 'position:absolute;width:0;border-left:1.5px dashed rgba(127,127,127,0.5);display:none;pointer-events:none;';
      overlay.appendChild(pageEdge);
      doc.body.appendChild(overlay);

      // The pasteboard: while editing at desktop width, the 24 columns
      // pin to true pixel widths, so an object past column 24 extends
      // BEYOND the page edge (visible, reachable) instead of squeezing
      // every column — the CSS-grid behavior that made things vanish.
      // Editor-only; published pages keep their elastic 1fr tracks.
      // Pins that leaked into a saved page (before the serializer stripped
      // them) would pin THIS session to a stale width — clear them first.
      Array.prototype.forEach.call(doc.querySelectorAll('style#__tim-pin-cols'), function (stale) { stale.remove(); });
      var pinCols = doc.createElement('style');
      pinCols.id = '__tim-pin-cols';
      doc.head.appendChild(pinCols);
      var lastPin = '';
      function pinPageColumns() {
        var canvas = doc.querySelector('[data-tim-canvas]');
        var mobile = mobileActive();
        if (!canvas || !active || (collapsed() && !mobile)) {
          if (lastPin) { lastPin = ''; pinCols.textContent = ''; }
          return;
        }
        // Both layouts get the pasteboard: 24 pinned columns at desktop,
        // 8 at phone width — off-page objects extend past the edge in
        // either mode. Higher specificity than the layout styles, so it
        // wins regardless of document order.
        var cols = mobile ? MOBILE_COLS : COLS;
        var cs2 = getComputedStyle(canvas);
        var padL = parseFloat(cs2.paddingLeft) || 0;
        var padR = parseFloat(cs2.paddingRight) || 0;
        var gap = parseFloat(cs2.columnGap) || 16;
        // Mobile editing happens in a widened view: the PAGE stays a true
        // 390 pinned to the left; everything beside it is pasteboard.
        var inner = (mobile ? 390 : canvas.clientWidth) - padL - padR;
        var colW = Math.max(8, (inner - gap * (cols - 1)) / cols).toFixed(2);
        var css = 'html.tim-editing .tim-canvas:not(.tim-container){'
          + 'grid-template-columns:repeat(' + cols + ', ' + colW + 'px) !important;'
          + 'grid-auto-columns:' + colW + 'px !important'
          + (mobile ? ';width:390px !important;margin-left:0 !important;margin-right:0 !important' : '')
          + '}';
        if (css !== lastPin) { lastPin = css; pinCols.textContent = css; }
      }

      var sel = null, drag = null, active = false, editingEl = null;
      var selGroup = [];
      // Keynote's group model: clicking a grouped object selects the
      // GROUP; double-clicking enters it, and clicks then reach the
      // children until you click outside again.
      var enteredGroup = null;
      function selectionTarget(raw) {
        if (!raw) { return raw; }
        if (enteredGroup && enteredGroup !== raw && enteredGroup.contains(raw)) { return raw; }
        var target = raw;
        var node = raw;
        while (node && node !== doc.body) {
          if (node.classList && node.classList.contains('tim-container')) { target = node; }
          node = node.parentElement;
        }
        return target;
      }

      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return { x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height };
      }
      function isObject(el) { return !!(el && el.classList && el.classList.contains('tim-object')); }
      // In the collapsed (mobile) layout, placement is automatic — objects
      // can be selected and their text edited, but not moved or resized.
      function collapsed() { return window.innerWidth <= 700; }
      // A group container is both an object (in its parent's grid) and a
      // canvas (for its children) — so an element's canvas is found from
      // its PARENT, never itself.
      function canvasFor(el) {
        return el && el.parentElement && el.parentElement.closest
          ? el.parentElement.closest('[data-tim-canvas]') : null;
      }
      function stopTextEditing() {
        if (editingEl) { editingEl.removeAttribute('contenteditable'); editingEl = null; }
      }
      function groupAll() { return sel ? [sel].concat(selGroup) : []; }
      function clearGroup() { selGroup = []; groupBox.innerHTML = ''; }
      function layoutGroup() {
        groupBox.innerHTML = '';
        for (var gi = 0; gi < selGroup.length; gi++) {
          var gel = selGroup[gi];
          if (!doc.contains(gel)) { continue; }
          var gr = rectOf(gel);
          var gAngle = effectiveAngle(gel);
          var gw = gAngle ? gel.offsetWidth : gr.w;
          var gh = gAngle ? gel.offsetHeight : gr.h;
          var gb = doc.createElement('div');
          gb.style.cssText = 'position:absolute;border:1.5px dashed #0a84ff;box-sizing:border-box;border-radius:3px;';
          gb.style.left = (gr.x + gr.w / 2 - gw / 2) + 'px';
          gb.style.top = (gr.y + gr.h / 2 - gh / 2) + 'px';
          gb.style.width = gw + 'px'; gb.style.height = gh + 'px';
          if (gAngle) { gb.style.transform = 'rotate(' + gAngle + 'deg)'; }
          groupBox.appendChild(gb);
        }
      }

      function gridInfo(canvas) {
        var cs = getComputedStyle(canvas);
        var gap = parseFloat(cs.columnGap) || 12;
        var rowGap = parseFloat(cs.rowGap) || gap;
        var padL = parseFloat(cs.paddingLeft) || 0;
        var padT = parseFloat(cs.paddingTop) || 0;
        var padR = parseFloat(cs.paddingRight) || 0;
        var rowM = String(cs.gridAutoRows || '').match(/(\\d+(?:\\.\\d+)?)px/);
        var rowH = rowM ? parseFloat(rowM[1]) : 28;
        var inner = canvas.clientWidth - padL - padR;
        var r = rectOf(canvas);
        return {
          gap: gap, rowGap: rowGap, rowH: rowH,
          colW: (inner - gap * (colCount() - 1)) / colCount(),
          originX: r.x + padL, originY: r.y + padT,
          inner: inner, height: Math.max(canvas.clientHeight, 240)
        };
      }
      function desktopPlacement(el) {
        var m = String(el.style.gridArea || '').match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*\\/\\s*(\\d+)\\s*\\/\\s*(\\d+)/);
        if (m) { return { rs: +m[1], cs: +m[2], re: +m[3], ce: +m[4] }; }
        return null;
      }
      function placement(el) {
        if (mobileActive()) {
          var a = el.getAttribute ? mobileLayout[el.getAttribute('data-tim-id')] : null;
          return a ? { rs: a[0], cs: a[1], re: a[2], ce: a[3] } : null;
        }
        return desktopPlacement(el);
      }
      // The page ends at its columns; the pasteboard doesn't. An object
      // may rest this many columns past the right edge while composing —
      // published pages hide whatever still lives out there.
      var PASTE_COLS = 12;
      var PASTE_COLS_MOBILE = 6;
      function setDesktopArea(el, rs, cs, re, ce) {
        var rh = Math.max(1, re - rs), cw = Math.max(1, ce - cs);
        cs = Math.max(1, Math.min(COLS + PASTE_COLS + 1 - cw, cs));
        rs = Math.max(1, rs);
        el.style.gridArea = rs + ' / ' + cs + ' / ' + (rs + rh) + ' / ' + (cs + cw);
      }
      function setArea(el, rs, cs, re, ce) {
        if (mobileActive()) {
          var cols = colCount();
          var rh = Math.max(1, re - rs), cw = Math.max(1, Math.min(cols, ce - cs));
          var ncs = Math.max(1, Math.min(cols + PASTE_COLS_MOBILE + 1 - cw, cs));
          var nrs = Math.max(1, rs);
          mobileLayout[ensureObjectId(el)] = [nrs, ncs, nrs + rh, ncs + cw];
          writeMobileLayout();
          return;
        }
        setDesktopArea(el, rs, cs, re, ce);
      }
      // Rows are fixed height, so text boxes grow by extending their row
      // span to fit content — geometry stays deterministic while dragging.
      function fitSpan(el) {
        if (!el || !el.classList || !el.classList.contains('tim-text')) { return; }
        var canvas = canvasFor(el);
        var p = placement(el);
        if (!canvas || !p || (collapsed() && !mobileActive())) { return; }
        var g = gridInfo(canvas);
        var unit = g.rowH + g.rowGap;
        // Grid stretch makes scrollHeight >= the box, so a stretched box
        // can never measure smaller than itself. Collapse to max-content
        // for one beat to learn the text's true height — the box can then
        // shrink right down to its content, and no further.
        var prevHeight = el.style.height;
        el.style.height = 'max-content';
        var content = el.scrollHeight;
        el.style.height = prevHeight;
        var needed = Math.max(1, Math.ceil((content + g.rowGap) / unit));
        if (p.re - p.rs < needed) {
          setArea(el, p.rs, p.cs, p.rs + needed, p.ce);
          layout();
        }
      }

      function resort(canvas) {
        var objs = Array.prototype.slice.call(canvas.children).filter(isObject);
        objs.sort(function (a, b) {
          var pa = placement(a) || { rs: 9999, cs: 9999 };
          var pb = placement(b) || { rs: 9999, cs: 9999 };
          return (pa.rs - pb.rs) || (pa.cs - pb.cs);
        });
        objs.forEach(function (o) { canvas.appendChild(o); });
      }

      function showGrid(canvas) {
        var g = gridInfo(canvas);
        gridBox.style.left = g.originX + 'px';
        gridBox.style.top = g.originY + 'px';
        gridBox.style.width = g.inner + 'px';
        gridBox.style.height = g.height + 'px';
        var ux = g.colW + g.gap, uy = g.rowH + g.rowGap;
        gridBox.style.backgroundImage =
          'repeating-linear-gradient(to right, rgba(10,132,255,0.10) 0 1px, transparent 1px ' + ux + 'px),' +
          'repeating-linear-gradient(to bottom, rgba(10,132,255,0.10) 0 1px, transparent 1px ' + uy + 'px)';
        gridBox.style.display = 'block';
      }
      function hideGrid() { gridBox.style.display = 'none'; }

      function hide() {
        box.style.display = badge.style.display = 'none';
        if (typeof ghost !== 'undefined') { ghost.style.display = 'none'; cropHud.style.display = 'none'; }
        extentBox.style.display = 'none';
        groupBox.innerHTML = '';
        hideGrid();
        for (var k in handles) { handles[k].style.display = 'none'; }
        rotStem.style.display = 'none';
        rotKnob.style.display = 'none';
      }
      function angleOf(el) {
        var m = /rotate\\((-?[0-9.]+)deg\\)/.exec((el && el.style && el.style.transform) || '');
        return m ? parseFloat(m[1]) : 0;
      }
      // What the eye sees: an object inside a rotated parent renders
      // rotated by inheritance — boxes, handles, and resize math follow
      // the summed rotation of the whole ancestor chain.
      function effectiveAngle(el) {
        var total = 0;
        var node = el;
        while (node && node !== doc.body && node.style) {
          total += angleOf(node);
          node = node.parentElement;
        }
        return total;
      }
      // Illustrator's pasteboard, adapted: an object that has slipped
      // entirely past the page's left or right edge stays visible while
      // editing — faded, still clickable, draggable back on. (Vertical
      // has no off-page: the page simply grows.)
      function markOffPage() {
        var canvas = doc.querySelector('[data-tim-canvas]');
        if (!canvas) { return; }
        var cr = canvas.getBoundingClientRect();
        var cols = colCount();
        if (active && (!collapsed() || mobileActive())) {
          var pr = rectOf(canvas);
          pageEdge.style.display = 'block';
          pageEdge.style.left = (pr.x + canvas.clientWidth) + 'px';
          pageEdge.style.top = pr.y + 'px';
          pageEdge.style.height = Math.max(canvas.clientHeight, 240) + 'px';
        } else {
          pageEdge.style.display = 'none';
        }
        Array.prototype.forEach.call(canvas.querySelectorAll('.tim-object'), function (el) {
          var r = el.getBoundingClientRect();
          // Off the page two ways: the rendered box sits wholly past an
          // edge (transforms, margins), or the placement runs past the
          // page's columns — the grid then squeezes every column to fit,
          // which reads as the whole page quietly distorting.
          var p = canvasFor(el) === canvas ? placement(el) : null;
          var off = (r.width > 0 && (r.left >= cr.right - 4 || r.right <= cr.left + 4))
            || !!(p && (p.cs > cols || p.ce > cols + 1));
          if (off) {
            if (!el.hasAttribute('data-tim-offpage')) { el.setAttribute('data-tim-offpage', ''); }
          } else if (el.hasAttribute('data-tim-offpage')) {
            el.removeAttribute('data-tim-offpage');
          }
        });
      }
      // Text wrap, the Pages way: an object says how text should treat it —
      // flow Around it, stay Above and Below it, or ignore it — and every
      // text box it overlaps obeys. CSS has no way to make one box's text
      // flow around a sibling, so each overlapping text box gets an
      // invisible float the size of the overlap, sitting where the object
      // sits. Widths are written in grid units so the wrap holds at any
      // desktop width; heights are rows, which never change. The floats
      // are part of the page (a published page needs no script), and
      // phones hide them — nothing overlaps in a stack.
      // ---- Crop, the Keynote way (Edit Mask) ----
      // A picture you never crop is a plain <img>. The first crop turns it
      // into a frame — a div that keeps the object's classes, placement
      // and styling — with the picture positioned inside. The picture's
      // size and offset are written in container-query units (cqw/cqh),
      // so the same crop holds at any width, on phones, with no script.
      // data-tim-crop = "scale x y ratio": scale is picture width over
      // frame width; x and y run 0..1 from one edge of the frame to the
      // other; ratio is the picture's own height over width.
      var cropping = null;
      function mediaOf(el) {
        if (!el) { return null; }
        if (el.matches && el.matches('img,video')) { return el; }
        return el.querySelector ? el.querySelector('img,video') : null;
      }
      function cropWrap(el) { return (el && el.classList && el.classList.contains('tim-crop')) ? el : null; }
      function readCrop(w) {
        var m = String(w.getAttribute('data-tim-crop') || '').split(/\\s+/).map(parseFloat);
        return { s: m[0] > 0 ? m[0] : 1, x: isFinite(m[1]) ? m[1] : 0.5, y: isFinite(m[2]) ? m[2] : 0.5, r: m[3] > 0 ? m[3] : 1 };
      }
      function writeCrop(w, c) {
        w.setAttribute('data-tim-crop', c.s.toFixed(4) + ' ' + c.x.toFixed(4) + ' ' + c.y.toFixed(4) + ' ' + c.r.toFixed(5));
        var img = mediaOf(w);
        if (!img) { return; }
        var pw = (c.s * 100).toFixed(3), ph = (c.s * c.r * 100).toFixed(3);
        img.style.cssText = 'position:absolute;display:block;max-width:none;height:auto;width:' + pw + 'cqw;'
          + 'left:calc((100cqw - ' + pw + 'cqw) * ' + c.x.toFixed(4) + ');'
          + 'top:calc((100cqh - ' + ph + 'cqw) * ' + c.y.toFixed(4) + ');';
      }
      // The picture's rectangle on the page, from the frame and the crop.
      function cropGeometry(w) {
        var f = rectOf(w), c = readCrop(w);
        var pw = c.s * f.w, ph = pw * c.r;
        return { f: f, c: c, pic: { x: f.x + (f.w - pw) * c.x, y: f.y + (f.h - ph) * c.y, w: pw, h: ph } };
      }
      // The smallest scale at which the picture still covers the frame.
      function coverScale(w) {
        var f = rectOf(w), c = readCrop(w);
        return f.w > 0 ? Math.max(1, (f.h / f.w) / c.r) : 1;
      }
      function setCrop(w, c) {
        c.s = Math.max(0.2, Math.min(6, c.s));
        c.x = Math.max(0, Math.min(1, c.x));
        c.y = Math.max(0, Math.min(1, c.y));
        writeCrop(w, c);
      }
      function ensureCropWrapper(el) {
        if (cropWrap(el)) { return el; }
        var img = mediaOf(el);
        if (!img || img.tagName !== 'IMG' || img !== el) { return null; }
        var w = doc.createElement('div');
        // The frame takes over as the object: classes, placement, styling.
        w.className = img.className;
        w.classList.add('tim-crop');
        w.style.cssText = img.style.cssText;
        var radius = getComputedStyle(img).borderRadius;
        if (radius && radius !== '0px') { w.style.borderRadius = radius; }
        w.style.position = 'relative';
        w.style.overflow = 'hidden';
        w.style.containerType = 'size';
        ['data-tim-id', 'data-tim-wrap', 'data-tim-mobile-hidden', 'id', 'data-tim-review'].forEach(function (a) {
          if (img.hasAttribute(a)) { w.setAttribute(a, img.getAttribute(a)); img.removeAttribute(a); }
        });
        var natW = img.naturalWidth || img.offsetWidth || 1, natH = img.naturalHeight || img.offsetHeight || 1;
        img.className = '';
        img.style.cssText = '';
        img.parentNode.insertBefore(w, img);
        w.appendChild(img);
        ensureObjectId(w);
        var f = rectOf(w);
        if (f.w > 0 && f.h > 0) { w.setAttribute('data-tim-aspect', f.w.toFixed(2) + ' / ' + f.h.toFixed(2)); }
        var r = natH / natW;
        writeCrop(w, { s: f.w > 0 ? Math.max(1, (f.h / f.w) / r) : 1, x: 0.5, y: 0.5, r: r });
        return w;
      }
      function unwrapCrop(w) {
        var img = mediaOf(w);
        if (!img) { return w; }
        img.className = w.className.replace(/\\btim-crop\\b/, '').replace(/\\s+/g, ' ').trim();
        img.style.cssText = w.style.cssText;
        img.style.position = ''; img.style.overflow = ''; img.style.containerType = '';
        ['data-tim-id', 'data-tim-wrap', 'data-tim-mobile-hidden', 'id'].forEach(function (a) {
          if (w.hasAttribute(a)) { img.setAttribute(a, w.getAttribute(a)); }
        });
        w.parentNode.insertBefore(img, w);
        w.remove();
        return img;
      }
      // The frame's edges moved; the picture didn't. Read the crop back.
      function recrop(w, pic) {
        var f = rectOf(w), c = readCrop(w);
        if (f.w <= 0) { return; }
        c.s = pic.w / f.w;
        var spanX = pic.w - f.w, spanY = pic.h - f.h;
        c.x = Math.abs(spanX) > 1 ? (f.x - pic.x) / spanX : 0.5;
        c.y = Math.abs(spanY) > 1 ? (f.y - pic.y) / spanY : 0.5;
        setCrop(w, c);
        w.setAttribute('data-tim-aspect', f.w.toFixed(2) + ' / ' + f.h.toFixed(2));
      }
      // The frame keeps its shape in the phone's stack — and only there.
      // Inline, aspect-ratio would also pin the frame on the desktop, and a
      // vertical resize would do nothing at all.
      function updateCropAspects() {
        var frames = doc.querySelectorAll('.tim-crop[data-tim-aspect]');
        var css = '';
        Array.prototype.forEach.call(frames, function (w) {
          var id = w.getAttribute('data-tim-id');
          if (id) { css += '[data-tim-id="' + id + '"]{aspect-ratio:' + w.getAttribute('data-tim-aspect') + '}\\n'; }
        });
        var st = doc.getElementById('__tim-cropaspect');
        if (!css) { if (st) { st.remove(); } return; }
        if (!st) { st = doc.createElement('style'); st.id = '__tim-cropaspect'; doc.head.appendChild(st); }
        var text = '@media (max-width:700px){\\n' + css + '}';
        if (st.textContent !== text) { st.textContent = text; }
      }
      // Editing chrome: the whole picture, faded where the frame doesn't
      // show it, and a small bar beneath the frame with a Size slider.
      var ghost = doc.createElement('img');
      ghost.id = '__tim-cropghost';
      ghost.setAttribute('alt', '');
      ghost.style.cssText = 'position:absolute;display:none;opacity:0.4;pointer-events:none;max-width:none;';
      overlay.insertBefore(ghost, overlay.firstChild);
      var cropHud = doc.createElement('div');
      cropHud.id = '__tim-crophud';
      cropHud.style.cssText = 'position:absolute;display:none;align-items:center;gap:10px;padding:8px 12px;border-radius:10px;'
        + 'background:rgba(28,28,30,0.92);color:#fff;font:12px -apple-system,system-ui,sans-serif;pointer-events:auto;'
        + 'box-shadow:0 6px 24px rgba(0,0,0,0.25);white-space:nowrap;';
      cropHud.innerHTML = '<span>Size</span><input type="range" min="100" max="400" step="1" style="width:150px">'
        + '<span data-crop-val style="min-width:38px;text-align:right;font-variant-numeric:tabular-nums">100%</span>'
        + '<button type="button" style="margin-left:4px;padding:3px 10px;border-radius:6px;border:0;background:#ffd60a;color:#111;font-weight:600;font:inherit;cursor:pointer">Done</button>';
      overlay.appendChild(cropHud);
      var cropRange = cropHud.querySelector('input');
      cropRange.addEventListener('input', function () {
        var w = cropWrap(sel);
        if (!w) { return; }
        var c = readCrop(w);
        c.s = parseFloat(cropRange.value) / 100;
        setCrop(w, c);
        layout();
        notifySel();
      });
      cropRange.addEventListener('pointerdown', function () { checkpoint('crop'); });
      cropHud.querySelector('button').addEventListener('click', function (e) { e.stopPropagation(); exitCrop(); });
      function inHud(t) { return !!(t && t.closest && t.closest('#__tim-crophud')); }
      function updateCropChrome() {
        if (cropping && (sel !== cropping || !doc.contains(cropping))) { cropping = null; }
        if (!cropping) { ghost.style.display = 'none'; cropHud.style.display = 'none'; return; }
        var img = mediaOf(cropping);
        var geo = cropGeometry(cropping);
        if (img && ghost.getAttribute('src') !== (img.currentSrc || img.getAttribute('src'))) {
          ghost.src = img.currentSrc || img.getAttribute('src') || '';
        }
        ghost.style.left = geo.pic.x + 'px'; ghost.style.top = geo.pic.y + 'px';
        ghost.style.width = geo.pic.w + 'px'; ghost.style.height = geo.pic.h + 'px';
        // Cut the frame out of the ghost, so what the frame shows stays crisp.
        var fx = geo.f.x - geo.pic.x, fy = geo.f.y - geo.pic.y;
        ghost.style.clipPath = 'path(evenodd, "M0 0H' + geo.pic.w.toFixed(1) + 'V' + geo.pic.h.toFixed(1) + 'H0Z'
          + 'M' + fx.toFixed(1) + ' ' + fy.toFixed(1) + 'H' + (fx + geo.f.w).toFixed(1) + 'V' + (fy + geo.f.h).toFixed(1) + 'H' + fx.toFixed(1) + 'Z")';
        ghost.style.display = 'block';
        cropRange.min = String(Math.round(Math.min(380, coverScale(cropping) * 100)));
        cropRange.value = String(Math.round(geo.c.s * 100));
        cropHud.querySelector('[data-crop-val]').textContent = Math.round(geo.c.s * 100) + '%';
        cropHud.style.display = 'flex';
        var hw = cropHud.offsetWidth || 300;
        cropHud.style.left = Math.max(8, geo.f.x + geo.f.w / 2 - hw / 2) + 'px';
        cropHud.style.top = (geo.f.y + geo.f.h + 12) + 'px';
      }
      function enterCrop(el) {
        var w = cropWrap(el) || ensureCropWrapper(el);
        if (!w) { return false; }
        stopTextEditing();
        clearGroup();
        sel = w;
        cropping = w;
        layout();
        notifySel(true);
        return true;
      }
      function exitCrop() {
        if (!cropping) { return; }
        cropping = null;
        layout();
        notifySel(true);
      }
      // For the test harness and for anyone debugging a crop.
      window.__timDebugCrop = function () {
        return JSON.stringify({ cropping: cropping ? cropping.className : null, selIsCropping: !!(sel && sel === cropping),
                                selClass: sel ? sel.className : null, drag: drag ? { mode: drag.mode, hasPic: !!drag.picRect, hasFit: !!drag.lastFit } : null,
                                frame: sel ? rectOf(sel) : null, pic: drag && drag.picRect ? drag.picRect : null,
                                geo: (sel && cropWrap(sel)) ? cropGeometry(sel).pic : null });
      };
      window.__timCropSel = function (on) {
        if (!sel) { return; }
        if (on === false) { exitCrop(); return; }
        checkpoint('crop');
        enterCrop(sel);
      };
      window.__timSetCropScale = function (pct) {
        var w = cropWrap(sel);
        if (!w) { return; }
        checkpoint('crop');
        var c = readCrop(w);
        c.s = parseFloat(pct) / 100;
        setCrop(w, c);
        layout();
        notifySel();
      };
      window.__timResetCrop = function () {
        var w = cropWrap(sel);
        if (!w) { return; }
        checkpoint('crop');
        cropping = null;
        sel = unwrapCrop(w);
        layout();
        notifySel(true);
      };

      var WRAP_GAP = 12;
      function wrapMode(el) { return (el.getAttribute && el.getAttribute('data-tim-wrap')) || 'none'; }
      function updateWraps() {
        var canvas = canvasEl();
        if (!canvas) { return; }
        var texts = Array.prototype.filter.call(canvas.children, function (c) {
          return c.classList && c.classList.contains('tim-text') && !c.classList.contains('tim-nav');
        });
        var wrappers = Array.prototype.filter.call(canvas.querySelectorAll('[data-tim-wrap]'), function (el) {
          return wrapMode(el) !== 'none' && desktopPlacement(el);
        });
        texts.forEach(function (t) {
          Array.prototype.forEach.call(t.querySelectorAll('.tim-wrap-spacer'), function (sp) { sp.remove(); });
          var tp = desktopPlacement(t);
          if (!tp || !wrappers.length) { return; }
          var tCols = tp.ce - tp.cs;
          var specs = [];
          wrappers.forEach(function (w) {
            if (w === t || w.contains(t) || t.contains(w)) { return; }
            var wp = desktopPlacement(w);
            var cs = Math.max(tp.cs, wp.cs), ce = Math.min(tp.ce, wp.ce);
            var rs = Math.max(tp.rs, wp.rs), re = Math.min(tp.re, wp.re);
            if (ce <= cs || re <= rs) { return; }
            var mode = wrapMode(w);
            // Automatic: a narrow object is wrapped around; a wide one is
            // stepped over.
            if (mode === 'auto') { mode = ((wp.ce - wp.cs) <= tCols * 0.55) ? 'around' : 'above-below'; }
            var side = 'left';
            if (mode === 'around') { side = ((wp.cs + wp.ce) / 2 <= (tp.cs + tp.ce) / 2) ? 'left' : 'right'; }
            var kCols = side === 'left' ? (ce - tp.cs) : (tp.ce - cs);
            if (mode === 'around' && kCols >= tCols) { mode = 'above-below'; }
            specs.push({ mode: mode, side: side, kCols: kCols, rows: re - rs, offset: rs - tp.rs });
          });
          if (!specs.length) { return; }
          specs.sort(function (a, b) { return a.offset - b.offset; });
          var padTop = parseFloat(getComputedStyle(t).paddingTop) || 0;
          var frag = doc.createDocumentFragment();
          // Floats can't be told where to start — a top margin becomes part
          // of the box text avoids, and a full-width one walls off the whole
          // column. So each spacer is two floats: a zero-width one whose
          // height is the distance down to the object, and the real one,
          // which clears it and lands exactly at the object's top. Left,
          // right and full-width spacers each keep their own running bottom.
          var bottom = { left: 0, right: 0 };
          function spacer(side, clear, width, height) {
            var el = doc.createElement('span');
            el.className = 'tim-wrap-spacer';
            el.setAttribute('contenteditable', 'false');
            el.setAttribute('aria-hidden', 'true');
            el.style.cssText = 'float:' + side + ';clear:' + clear + ';width:' + width + ';height:' + height + 'px;pointer-events:none;';
            frag.appendChild(el);
          }
          specs.forEach(function (sp) {
            var full = sp.mode !== 'around';
            var side = full ? 'left' : sp.side;
            var clear = full ? 'both' : side;
            var top = Math.max(0, sp.offset * 48 - WRAP_GAP - padTop);
            var height = sp.rows * 48 - 16 + 2 * WRAP_GAP;
            var from = full ? Math.max(bottom.left, bottom.right) : bottom[side];
            if (top > from) { spacer(side, clear, '0px', top - from); from = top; }
            // One column of this text box = (its width − the gaps) / its columns.
            var width = full ? '100%'
              : 'calc((100% - ' + ((tCols - 1) * 16) + 'px) / ' + tCols + ' * ' + sp.kCols + ' + ' + ((sp.kCols - 1) * 16 + WRAP_GAP) + 'px)';
            spacer(side, clear, width, height);
            if (full) { bottom.left = bottom.right = from + height; } else { bottom[side] = from + height; }
          });
          t.insertBefore(frag, t.firstChild);
        });
      }
      window.__timUpdateWraps = updateWraps;
      window.__timSetWrap = function (mode) {
        if (!sel) { return; }
        checkpoint('wrap');
        groupAll().forEach(function (member) {
          if (!mode || mode === 'none') { member.removeAttribute('data-tim-wrap'); }
          else { member.setAttribute('data-tim-wrap', mode); }
        });
        layout();
        notifySel(true);
      };

      function layout() {
        pinPageColumns();
        markOffPage();
        updateWraps();
        updateCropAspects();
        if (!sel || !doc.contains(sel)) { hide(); return; }
        updateCropChrome();
        var r = rectOf(sel);
        // The selection box matches the object's own frame — a rotated
        // object gets a rotated box, Keynote-style, not the upright
        // bounding rectangle CSS reports. Rotation preserves the center,
        // and offsetWidth/Height are the untransformed layout size.
        var ownAngle = angleOf(sel);
        var angle = effectiveAngle(sel);
        var cx = r.x + r.w / 2, cy = r.y + r.h / 2;
        var w0 = angle ? sel.offsetWidth : r.w;
        var h0 = angle ? sel.offsetHeight : r.h;
        box.style.display = 'block';
        box.style.left = (cx - w0 / 2) + 'px'; box.style.top = (cy - h0 / 2) + 'px';
        box.style.width = w0 + 'px'; box.style.height = h0 + 'px';
        box.style.transform = angle ? 'rotate(' + angle + 'deg)' : '';
        layoutGuides(w0, h0);
        badge.style.display = 'block';
        badge.style.left = r.x + 'px';
        badge.style.top = Math.max(2, r.y - 24) + 'px';
        if (!drag) {
          var p = placement(sel);
          badge.textContent = (p ? '✥ ' : '') + labelFor(sel) +
            (p ? ' · ' + (p.ce - p.cs) + '×' + (p.re - p.rs) + ' cells' : '') +
            (ownAngle ? ' · ' + ownAngle + '°' : '');
        }
        var resizable = isObject(sel) && canvasFor(sel) && placement(sel) && (!collapsed() || mobileActive());
        for (var k in handles) { handles[k].style.display = resizable ? 'block' : 'none'; }
        if (resizable) {
          var rad = angle * Math.PI / 180;
          var cos = Math.cos(rad), sin = Math.sin(rad);
          function place(h, dx, dy) {
            h.style.left = (cx + dx * cos - dy * sin - 11) + 'px';
            h.style.top = (cy + dx * sin + dy * cos - 11) + 'px';
          }
          place(handles.w, -w0 / 2, 0);
          place(handles.e, w0 / 2, 0);
          place(handles.n, 0, -h0 / 2);
          place(handles.s, 0, h0 / 2);
          place(handles.nw, -w0 / 2, -h0 / 2);
          place(handles.ne, w0 / 2, -h0 / 2);
          place(handles.sw, -w0 / 2, h0 / 2);
          place(handles.se, w0 / 2, h0 / 2);
          // Lollipop: stem from the top edge, knob at its tip — both
          // riding the box's rotation so the handle turns with it.
          function world(dx, dy) { return { x: cx + dx * cos - dy * sin, y: cy + dx * sin + dy * cos }; }
          var stemC = world(0, -h0 / 2 - 11);
          rotStem.style.display = 'block';
          rotStem.style.left = (stemC.x - 0.75) + 'px';
          rotStem.style.top = (stemC.y - 11) + 'px';
          rotStem.style.transform = angle ? 'rotate(' + angle + 'deg)' : '';
          var knobC = world(0, -h0 / 2 - 30);
          rotKnob.style.display = 'block';
          rotKnob.style.left = (knobC.x - 14) + 'px';
          rotKnob.style.top = (knobC.y - 14) + 'px';
        } else {
          rotStem.style.display = 'none';
          rotKnob.style.display = 'none';
        }
        // A selected group whose contents reach beyond its box gets the
        // dotted truth: the actual extent of what's inside.
        extentBox.style.display = 'none';
        if (sel.classList && sel.classList.contains('tim-container')) {
          var exL = Infinity, exT = Infinity, exR = -Infinity, exB = -Infinity;
          var kids = sel.querySelectorAll(':scope > .tim-object');
          for (var ki = 0; ki < kids.length; ki++) {
            var kr = rectOf(kids[ki]);
            exL = Math.min(exL, kr.x); exT = Math.min(exT, kr.y);
            exR = Math.max(exR, kr.x + kr.w); exB = Math.max(exB, kr.y + kr.h);
          }
          if (exR > exL && (exR - exL > r.w + 6 || exB - exT > r.h + 6
              || exL < r.x - 6 || exT < r.y - 6)) {
            extentBox.style.left = (exL - 3) + 'px';
            extentBox.style.top = (exT - 3) + 'px';
            extentBox.style.width = (exR - exL + 6) + 'px';
            extentBox.style.height = (exB - exT + 6) + 'px';
            extentBox.style.display = 'block';
          }
        }
        layoutGroup();
      }

      function onDown(e) {
        if (collapsed() && !mobileActive()) { return; }
        if (inHud(e.target)) { return; }
        var k = e.target && e.target.getAttribute ? e.target.getAttribute('data-tim-handle') : null;
        if (!k && cropping && sel === cropping && !mobileActive()) {
          // Inside the picture: drag moves it within its frame.
          var geo = cropGeometry(cropping);
          if (e.pageX >= geo.pic.x && e.pageX <= geo.pic.x + geo.pic.w && e.pageY >= geo.pic.y && e.pageY <= geo.pic.y + geo.pic.h) {
            checkpoint('crop');
            drag = { mode: 'crop-pan', sx: e.pageX, sy: e.pageY, c0: geo.c, geo: geo, moved: false };
            e.preventDefault(); e.stopPropagation();
            return;
          }
        }
        if (k && sel && isObject(sel)) {
          // The rotate knob turns; option-drag on any handle does too.
          if (e.altKey || k === 'rotate') {
            var rr = rectOf(sel);
            checkpoint('rotate');
            if (mobileActive() && mobileLayoutMode === 'stack') {
              mobileLayoutMode = 'custom';
              writeMobileLayout();
            }
            drag = {
              mode: 'rotate',
              cx: rr.x + rr.w / 2, cy: rr.y + rr.h / 2,
              a0: Math.atan2(e.pageY - (rr.y + rr.h / 2), e.pageX - (rr.x + rr.w / 2)) * 180 / Math.PI,
              r0: angleOf(sel), moved: false
            };
            e.preventDefault(); e.stopPropagation();
            return;
          }
          var canvas = canvasFor(sel);
          var p0 = placement(sel);
          if (!canvas || !p0) { return; }
          checkpoint('drag');
          // A picture's corners keep its proportions; its edges are free,
          // and cover-fit crops what no longer fits — Keynote's behavior.
          // Shift breaks the corner lock.
          var ratio = 0;
          var cornerHandle = k === 'nw' || k === 'ne' || k === 'sw' || k === 'se';
          if ((sel.tagName === 'IMG' || sel.tagName === 'VIDEO') && cornerHandle && !e.shiftKey) {
            var natW = sel.naturalWidth || sel.videoWidth || 0;
            var natH = sel.naturalHeight || sel.videoHeight || 0;
            ratio = (natW > 0 && natH > 0) ? natW / natH
              : (sel.offsetHeight > 0 ? sel.offsetWidth / sel.offsetHeight : 0);
          }
          drag = { mode: k, canvas: canvas, sx: e.pageX, sy: e.pageY, p0: p0, angle: effectiveAngle(sel), ratio: ratio, moved: false };
          // Editing a crop: the frame moves, the picture stays where it is.
          if (cropping === sel && k !== 'move') { drag.picRect = cropGeometry(sel).pic; }
          showGrid(canvas);
          e.preventDefault(); e.stopPropagation();
          return;
        }
        if (!active) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        obj = selectionTarget(obj);
        // Shift-click toggles group membership — handled on click. Starting
        // a drag here would clear the group before the click ever fires.
        if (obj && e.shiftKey) { return; }
        if (obj && obj !== editingEl && !(editingEl && editingEl.contains(e.target))) {
          var canvas2 = canvasFor(obj);
          var p1 = placement(obj);
          if (canvas2 && p1) {
            stopTextEditing();
            if (obj !== sel && selGroup.indexOf(obj) < 0) { clearGroup(); }
            if (selGroup.indexOf(obj) >= 0) {
              selGroup.splice(selGroup.indexOf(obj), 1);
              if (sel && sel !== obj) { selGroup.push(sel); }
            }
            sel = obj;
            var items = groupAll().map(function (member) {
              return { el: member, p: placement(member) };
            }).filter(function (item) { return !!item.p; });
            checkpoint('drag');
            drag = { mode: 'move', canvas: canvas2, sx: e.pageX, sy: e.pageY, p0: p1, items: items,
                     angle: effectiveAngle(obj), ownAngle: angleOf(obj), moved: false };
            showGrid(canvas2);
            layout();
            e.preventDefault(); e.stopPropagation();
          }
        }
      }

      function onMove(e) {
        if (!drag || !sel) { return; }
        e.preventDefault();
        if (drag.mode === 'crop-pan') {
          var g0 = drag.geo, c = { s: drag.c0.s, x: drag.c0.x, y: drag.c0.y, r: drag.c0.r };
          var spanX = g0.pic.w - g0.f.w, spanY = g0.pic.h - g0.f.h;
          if (Math.abs(spanX) > 1) { c.x = drag.c0.x - (e.pageX - drag.sx) / spanX; }
          if (Math.abs(spanY) > 1) { c.y = drag.c0.y - (e.pageY - drag.sy) / spanY; }
          drag.moved = true;
          setCrop(sel, c);
          layout();
          return;
        }
        if (drag.mode === 'rotate') {
          var a = Math.atan2(e.pageY - drag.cy, e.pageX - drag.cx) * 180 / Math.PI;
          var next = drag.r0 + (a - drag.a0);
          while (next > 180) { next -= 360; }
          while (next <= -180) { next += 360; }
          var nearest = Math.round(next / 45) * 45;
          if (Math.abs(next - nearest) <= 5) { next = nearest; }
          next = Math.round(next);
          drag.moved = true;
          sel.style.transform = next === 0 ? '' : 'rotate(' + next + 'deg)';
          badge.textContent = next + '°';
          layout();
          return;
        }
        var g = gridInfo(drag.canvas);
        var rawX = e.pageX - drag.sx;
        var rawY = e.pageY - drag.sy;
        // The pointer's travel maps onto the frame the gesture lives in.
        // Resizing uses the object's full rotated frame (its own angle
        // plus inherited), so dragging an angled edge grows along that
        // edge. Moving uses only the PARENT's frame: a top-level rotated
        // object follows the mouse in screen space, but a child inside a
        // rotated parent moves along the parent's rotated grid.
        var frameAngle = drag.mode === 'move'
          ? ((drag.angle || 0) - (drag.ownAngle || 0))
          : (drag.angle || 0);
        if (frameAngle) {
          var lrad = -frameAngle * Math.PI / 180;
          var localX = rawX * Math.cos(lrad) - rawY * Math.sin(lrad);
          var localY = rawX * Math.sin(lrad) + rawY * Math.cos(lrad);
          rawX = localX;
          rawY = localY;
        }
        var dc = Math.round(rawX / (g.colW + g.gap));
        var dr = Math.round(rawY / (g.rowH + g.rowGap));
        var p = drag.p0;
        if (dc !== 0 || dr !== 0) {
          drag.moved = true;
          // This is the exact boundary between Tim's resilient default and
          // the author's explicit composition. A click changes nothing; a
          // real mobile move or resize opts into the custom grid.
          if (mobileActive() && mobileLayoutMode === 'stack') { mobileLayoutMode = 'custom'; }
        }

        if (drag.mode === 'move') {
          var members = drag.items || [{ el: sel, p: p }];
          for (var di = 0; di < members.length; di++) {
            var member = members[di];
            setArea(member.el, member.p.rs + dr, member.p.cs + dc, member.p.re + dr, member.p.ce + dc);
          }
        } else if (drag.mode === 'e') {
          setArea(sel, p.rs, p.cs, p.re, Math.max(p.cs + 1, Math.min(colCount() + 1, p.ce + dc)));
        } else if (drag.mode === 'w') {
          var ncs = Math.max(1, Math.min(p.ce - 1, p.cs + dc));
          setArea(sel, p.rs, ncs, p.re, p.ce);
        } else if (drag.mode === 'n') {
          setArea(sel, Math.max(1, Math.min(p.re - 1, p.rs + dr)), p.cs, p.re, p.ce);
        } else if (drag.mode === 's') {
          setArea(sel, p.rs, p.cs, Math.max(p.rs + 1, p.re + dr), p.ce);
        } else if (drag.mode === 'nw') {
          setArea(sel, Math.max(1, Math.min(p.re - 1, p.rs + dr)), Math.max(1, Math.min(p.ce - 1, p.cs + dc)), p.re, p.ce);
        } else if (drag.mode === 'ne') {
          setArea(sel, Math.max(1, Math.min(p.re - 1, p.rs + dr)), p.cs, p.re, Math.max(p.cs + 1, Math.min(colCount() + 1, p.ce + dc)));
        } else if (drag.mode === 'sw') {
          setArea(sel, p.rs, Math.max(1, Math.min(p.ce - 1, p.cs + dc)), Math.max(p.rs + 1, p.re + dr), p.ce);
        } else if (drag.mode === 'se') {
          setArea(sel, p.rs, p.cs, Math.max(p.rs + 1, p.re + dr), Math.max(p.cs + 1, Math.min(colCount() + 1, p.ce + dc)));
        }
        // Aspect lock for media: after the mode applied its axis, the
        // other axis follows the file's own proportions.
        if (drag.ratio && drag.mode !== 'move') {
          var pl = placement(sel);
          if (pl) {
            if (drag.mode === 'n' || drag.mode === 's') {
              var rowsNow = pl.re - pl.rs;
              var hPx = rowsNow * g.rowH + (rowsNow - 1) * g.rowGap;
              var colsFit = Math.max(1, Math.min(colCount(), Math.round((hPx * drag.ratio + g.gap) / (g.colW + g.gap))));
              setArea(sel, pl.rs, pl.cs, pl.re, pl.cs + colsFit);
            } else {
              var colsNow = pl.ce - pl.cs;
              var wPx = colsNow * g.colW + (colsNow - 1) * g.gap;
              var rowsFit = Math.max(1, Math.round((wPx / drag.ratio + g.rowGap) / (g.rowH + g.rowGap)));
              if (drag.mode === 'ne' || drag.mode === 'nw') {
                setArea(sel, pl.re - rowsFit, pl.cs, pl.re, pl.ce);
              } else {
                setArea(sel, pl.rs, pl.cs, pl.rs + rowsFit, pl.ce);
              }
            }
          }
        }
        if (drag.picRect && cropping === sel) {
          // The frame may not leave the picture: each edge stops at the
          // last row or column that still lies inside it.
          var pic = drag.picRect, cur = placement(sel), fr = rectOf(sel);
          var unit = g.rowH + g.rowGap, cunit = g.colW + g.gap;
          var rs = cur.rs, re = cur.re, cs = cur.cs, ce = cur.ce;
          if (fr.y < pic.y - 0.5) { rs += Math.ceil((pic.y - fr.y - 0.5) / unit); }
          if (fr.y + fr.h > pic.y + pic.h + 0.5) { re -= Math.ceil((fr.y + fr.h - pic.y - pic.h - 0.5) / unit); }
          if (fr.x < pic.x - 0.5) { cs += Math.ceil((pic.x - fr.x - 0.5) / cunit); }
          if (fr.x + fr.w > pic.x + pic.w + 0.5) { ce -= Math.ceil((fr.x + fr.w - pic.x - pic.w - 0.5) / cunit); }
          if (re <= rs) { re = rs + 1; }
          if (ce <= cs) { ce = cs + 1; }
          if (rs !== cur.rs || re !== cur.re || cs !== cur.cs || ce !== cur.ce) { setArea(sel, rs, cs, re, ce); }
          recrop(sel, pic);
        }
        var np = placement(sel);
        badge.textContent = drag.mode === 'move'
          ? 'row ' + np.rs + ' · col ' + np.cs
          : (np.ce - np.cs) + '×' + (np.re - np.rs) + ' cells';
        layout();
      }

      var lastDragMoved = false;
      function onUp() {
        if (!drag) { return; }
        if (drag.mode === 'crop-pan') {
          lastDragMoved = !!drag.moved;
          drag = null;
          layout();
          notifySel();
          return;
        }
        var canvas = drag.canvas;
        var moved = drag.moved;
        lastDragMoved = !!moved;
        var wasRotate = drag.mode === 'rotate';
        var wasCropResize = !!drag.picRect;
        drag = null;
        // A cropped picture whose frame changed outside crop editing keeps
        // covering it — no gaps at the edges — and remembers its shape.
        if (sel && cropWrap(sel) && !wasRotate && moved && !wasCropResize) {
          var cw = sel, cc = readCrop(cw), need = coverScale(cw), fr = rectOf(cw);
          if (cc.s < need) { cc.s = need; setCrop(cw, cc); }
          if (fr.w > 0 && fr.h > 0) { cw.setAttribute('data-tim-aspect', fr.w.toFixed(2) + ' / ' + fr.h.toFixed(2)); }
        }
        hideGrid();
        if (sel && !wasRotate) { fitSpan(sel); }
        // DOM order belongs to the desktop layout — mobile placements are
        // explicit, so a mobile rearrangement must never reorder the DOM.
        if (moved && canvas && !mobileActive()) { resort(canvas); }
        layout();
        // Reseed the inspector so its Rotate control shows the new angle.
        if (wasRotate) { notifySel(true); }
      }

      function onClick(e) {
        if (!active || drag) { return; }
        if (e.target && e.target.getAttribute && e.target.getAttribute('data-tim-handle')) { return; }
        if (inHud(e.target)) { e.preventDefault(); e.stopPropagation(); return; }
        if (cropping) {
          var clickedObj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
          if (clickedObj === cropping) { e.preventDefault(); e.stopPropagation(); return; }
          exitCrop();
        }
        if (editingEl && editingEl.contains(e.target)) {
          // Text editing inside a link (a nav item, say): the caret works,
          // but the link must not fire and navigate the tab away.
          var link = e.target && e.target.closest ? e.target.closest('a[href]') : null;
          if (link) { e.preventDefault(); }
          return;
        }
        // Demo pages set __timDemoLinks: a clean click on a link navigates
        // like a normal page (the Download button must download); only
        // drags, double-clicks, and non-link clicks reveal the editor.
        if (window.__timDemoLinks && !lastDragMoved) {
          var throughLink = e.target && e.target.closest ? e.target.closest('a[href]') : null;
          if (throughLink) { stopTextEditing(); return; }
        }
        lastDragMoved = false;
        e.preventDefault(); e.stopPropagation();
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        obj = selectionTarget(obj);
        if (e.shiftKey && obj && sel && obj !== sel && isObject(sel)
            && canvasFor(obj) && canvasFor(obj) === canvasFor(sel)) {
          stopTextEditing();
          var slot = selGroup.indexOf(obj);
          if (slot >= 0) { selGroup.splice(slot, 1); } else { selGroup.push(obj); }
          layout();
          notifySel(true);
          return;
        }
        stopTextEditing();
        clearGroup();
        var el = obj || e.target;
        if (!obj) {
          while (el && el !== doc.body) {
            if (el.tagName === 'IMG' || getComputedStyle(el).display !== 'inline') { break; }
            el = el.parentElement;
          }
        }
        sel = (!el || el === doc.body) ? null : el;
        // Clicking outside an entered group leaves it.
        if (enteredGroup && (!sel || !(enteredGroup === sel || enteredGroup.contains(sel)))) {
          enteredGroup = null;
        }
        if (sel) { clearReview(sel); layout(); } else { hide(); }
        notifySel(true);
      }

      function onDblClick(e) {
        if (!active) { return; }
        if (inHud(e.target)) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        // A picture: double-click edits its crop; double-click again, done.
        if (obj && (cropWrap(obj) || (obj.tagName === 'IMG'))) {
          e.preventDefault(); e.stopPropagation();
          if (cropping === obj) { exitCrop(); }
          else { checkpoint('crop'); enterCrop(obj); }
          return;
        }
        // Double-clicking a group enters it: the child under the cursor
        // becomes selectable and editable until you click outside.
        var resolved = selectionTarget(obj);
        if (resolved && resolved.classList && resolved.classList.contains('tim-container')
            && obj && obj !== resolved && sel === resolved) {
          e.preventDefault(); e.stopPropagation();
          enteredGroup = resolved;
          stopTextEditing();
          clearGroup();
          sel = obj;
          layout();
          notifySel(true);
          return;
        }
        var target = null;
        if (obj && obj.classList.contains('tim-text')) {
          target = obj;
        } else if (!obj) {
          var el = e.target;
          while (el && el !== doc.body) {
            if (getComputedStyle(el).display !== 'inline' && !el.hasAttribute('data-tim-canvas')) { break; }
            el = el.parentElement;
          }
          if (el && el !== doc.body) { target = el; }
        }
        if (target) {
          e.preventDefault(); e.stopPropagation();
          stopTextEditing();
          checkpoint('text');
          editingEl = target;
          target.setAttribute('contenteditable', 'true');
          target.focus();
          sel = target;
          layout();
        }
      }

      function onKey(e) {
        if (active && e.metaKey && !e.ctrlKey && !e.altKey && (e.key === 'z' || e.key === 'Z')) {
          e.preventDefault(); e.stopPropagation();
          if (e.shiftKey) { window.__timRedo(); } else { window.__timUndo(); }
          return;
        }
        // Select All: every top-level object — then Group, style, or move
        // the lot as one.
        if (active && e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey && (e.key === 'a' || e.key === 'A') && !editingEl) {
          var allCanvas = doc.querySelector('[data-tim-canvas]');
          if (allCanvas) {
            var everyObj = Array.prototype.slice.call(allCanvas.querySelectorAll('.tim-object')).filter(function (el) {
              return canvasFor(el) === allCanvas && desktopPlacement(el);
            });
            if (everyObj.length) {
              e.preventDefault(); e.stopPropagation();
              stopTextEditing();
              sel = everyObj[0];
              selGroup = everyObj.slice(1);
              layout();
              notifySel(true);
              return;
            }
          }
        }
        if (e.key === 'Escape') {
          if (cropping) { exitCrop(); return; }
          stopTextEditing();
          sel = null;
          hide();
          notifySel(true);
          return;
        }
        if ((e.key === 'Backspace' || e.key === 'Delete') && active && !editingEl) {
          var t = e.target;
          if (t && (t.isContentEditable || t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) { return; }
          // While editing, delete deletes — it never navigates back.
          e.preventDefault();
          if (sel) {
            checkpoint('delete');
            groupAll().forEach(function (member) {
              // Deleting a component's element takes its wrapper too —
              // an empty husk would harvest as a blank master and wipe
              // the component from every page. Template components also
              // mark this page as opting out, so Done doesn't re-inject.
              var wrap = member.parentElement && member.parentElement.closest
                ? member.parentElement.closest('[data-tim-component]') : null;
              if (wrap) {
                var cname = wrap.getAttribute('data-tim-component') || '';
                if (cname.indexOf('tpl-') === 0) {
                  var omit = (doc.body.getAttribute('data-tim-omit') || '').split(' ').filter(Boolean);
                  if (omit.indexOf(cname) < 0) { omit.push(cname); }
                  doc.body.setAttribute('data-tim-omit', omit.join(' '));
                }
                wrap.remove();
              } else {
                member.remove();
              }
            });
            clearGroup();
            sel = null;
            hide();
            if (mobileActive()) { writeMobileLayout(); }
            notifySel();
          }
        }
      }

      function onOver(e) {
        if (!active || drag) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        if (obj && obj !== sel && obj !== editingEl) {
          var r = rectOf(obj);
          var hAngle = effectiveAngle(obj);
          var hw = hAngle ? obj.offsetWidth : r.w;
          var hh = hAngle ? obj.offsetHeight : r.h;
          hoverBox.style.display = 'block';
          hoverBox.style.left = (r.x + r.w / 2 - hw / 2) + 'px';
          hoverBox.style.top = (r.y + r.h / 2 - hh / 2) + 'px';
          hoverBox.style.width = hw + 'px'; hoverBox.style.height = hh + 'px';
          hoverBox.style.transform = hAngle ? 'rotate(' + hAngle + 'deg)' : '';
        } else {
          hoverBox.style.display = 'none';
        }
      }

      // The badge is a move grip: dragging it moves the selected object.
      badge.addEventListener('pointerdown', function (e) {
        if (!sel || !isObject(sel)) { return; }
        var canvas = canvasFor(sel);
        var p = placement(sel);
        if (!canvas || !p) { return; }
        drag = { mode: 'move', canvas: canvas, sx: e.pageX, sy: e.pageY, p0: p, moved: false };
        showGrid(canvas);
        e.preventDefault(); e.stopPropagation();
      });

      // Pointer events cover mouse, trackpad, finger, and Pencil alike —
      // the same canvas engine on a Mac or an iPad.
      doc.addEventListener('click', onClick, true);
      doc.addEventListener('dblclick', onDblClick, true);
      doc.addEventListener('pointerdown', onDown, true);
      doc.addEventListener('pointermove', onMove, true);
      doc.addEventListener('pointerup', onUp, true);
      doc.addEventListener('pointercancel', onUp, true);
      doc.addEventListener('pointerover', onOver, true);
      doc.addEventListener('keydown', onKey, true);
      doc.addEventListener('input', function () {
        if (editingEl) { fitSpan(editingEl); }
      }, true);
      window.addEventListener('scroll', layout, true);
      window.addEventListener('resize', layout);

      // Navigation objects: read the model, rebuild from it, and make sure
      // the page carries the nav style + script (handed in by the app).
      window.__timNavAssets = function () {
        if (!doc.querySelector('style[data-tim-nav]') && window.__timNavCSS) {
          var st = doc.createElement('style'); st.setAttribute('data-tim-nav', ''); st.textContent = window.__timNavCSS;
          (doc.head || doc.body).appendChild(st);
        }
        if (!doc.querySelector('script[data-tim-nav]') && window.__timNavJS) {
          var sc = doc.createElement('script'); sc.setAttribute('data-tim-nav', ''); sc.textContent = window.__timNavJS;
          doc.body.appendChild(sc);
        }
        if (window.__timNavRefresh) { window.__timNavRefresh(); }
      };
      function navRead(nav) {
        var items = [];
        var top = nav.querySelector(':scope > details > ul') || nav.querySelector('ul');
        if (top) {
          Array.prototype.forEach.call(top.children, function (li) {
            var a = li.querySelector(':scope > a');
            if (a) { items.push({ label: a.textContent.trim(), href: a.getAttribute('href') || '', depth: 0 }); }
            var sub = li.querySelector(':scope > ul');
            if (sub) {
              Array.prototype.forEach.call(sub.children, function (li2) {
                var a2 = li2.querySelector(':scope > a');
                if (a2) { items.push({ label: a2.textContent.trim(), href: a2.getAttribute('href') || '', depth: 1 }); }
              });
            }
          });
        }
        return {
          d: nav.getAttribute('data-nav-d') || 'row',
          m: nav.getAttribute('data-nav-m') || 'menu',
          sel: nav.getAttribute('data-nav-sel') || 'underline',
          align: nav.getAttribute('data-nav-align') || 'start',
          gap: parseInt(nav.style.getPropertyValue('--nav-gap') || '24', 10) || 24,
          label: nav.getAttribute('data-nav-label') || 'icon',
          items: items
        };
      }
      window.__timNavSet = function (json) {
        var nav = sel && sel.closest ? sel.closest('.tim-nav') : null;
        if (!nav) { return; }
        var o = JSON.parse(json);
        checkpoint('nav');
        nav.setAttribute('data-nav-d', o.d || 'row');
        nav.setAttribute('data-nav-m', o.m || 'menu');
        nav.setAttribute('data-nav-sel', o.sel || 'underline');
        nav.setAttribute('data-nav-align', o.align || 'start');
        nav.setAttribute('data-nav-label', o.label || 'icon');
        nav.style.setProperty('--nav-gap', (o.gap || 24) + 'px');
        var det = nav.querySelector(':scope > details');
        if (!det) {
          det = doc.createElement('details'); det.open = true;
          var sum = doc.createElement('summary'); sum.setAttribute('aria-label', 'Menu');
          sum.innerHTML = '<span class="tim-nav-bars"></span><span class="tim-nav-word">Menu</span>';
          det.appendChild(sum);
          nav.innerHTML = ''; nav.appendChild(det);
        }
        var ul = doc.createElement('ul'), lastTop = null;
        (o.items || []).forEach(function (it) {
          var li = doc.createElement('li'), a = doc.createElement('a');
          a.setAttribute('href', it.href || '#'); a.textContent = it.label || 'Untitled';
          li.appendChild(a);
          if (it.depth === 1 && lastTop) {
            var sub = lastTop.querySelector(':scope > ul');
            if (!sub) { sub = doc.createElement('ul'); lastTop.appendChild(sub); }
            sub.appendChild(li);
          } else { ul.appendChild(li); lastTop = li; }
        });
        var old = det.querySelector(':scope > ul');
        if (old) { det.replaceChild(ul, old); } else { det.appendChild(ul); }
        nav.__timMode = null;
        window.__timNavAssets();
        layout();
        notifySel(true);
      };

      // The floating text bar: while text is being edited and a real
      // range is selected, the app hears where it is and what it's like.
      var textSelTimer = null;
      function postTextSel() {
        if (!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.timText)) { return; }
        var payload = '';
        try {
          var s = window.getSelection();
          if (active && editingEl && s && s.rangeCount && !s.isCollapsed
              && editingEl.contains(s.anchorNode) && editingEl.contains(s.focusNode)) {
            var r = s.getRangeAt(0).getBoundingClientRect();
            if (r.width || r.height) {
              var an = s.anchorNode.nodeType === 1 ? s.anchorNode : s.anchorNode.parentElement;
              var link = an && an.closest ? an.closest('a[href]') : null;
              payload = JSON.stringify({
                x: r.left, y: r.top, w: r.width, h: r.height,
                bold: doc.queryCommandState('bold') ? 1 : 0,
                italic: doc.queryCommandState('italic') ? 1 : 0,
                underline: doc.queryCommandState('underline') ? 1 : 0,
                strike: doc.queryCommandState('strikeThrough') ? 1 : 0,
                link: link ? (link.getAttribute('href') || '') : ''
              });
            }
          }
        } catch (e) {}
        window.webkit.messageHandlers.timText.postMessage(payload);
      }
      function scheduleTextSel() { clearTimeout(textSelTimer); textSelTimer = setTimeout(postTextSel, 160); }
      // Capture phase: the click is stopped before the page, a script, or
      // WebKit's own link handling can do anything with it.
      doc.addEventListener('click', function (e) {
        if (!active) { return; }
        if (e.target && e.target.closest && e.target.closest('a[href]')) { e.preventDefault(); }
      }, true);
      doc.addEventListener('dragstart', function (e) {
        if (!active) { return; }
        if (e.target && e.target.closest && e.target.closest('a[href]')) { e.preventDefault(); }
      }, true);
      doc.addEventListener('selectionchange', scheduleTextSel);
      window.addEventListener('scroll', scheduleTextSel, true);
      window.addEventListener('resize', scheduleTextSel);
      window.__timTextSelRefresh = postTextSel;

      // Only objects it actually overlaps matter; the rest keep their
      // implicit zero, the way the arrange commands leave them.
      function bringToFront(el, canvas) {
        if (!el || !canvas) { return; }
        // A component wrapper is display:contents and has no box of its
        // own — the object inside it is what occupies space and stacks.
        var box = (el.matches && el.matches('[data-tim-component]')) ? el.firstElementChild : el;
        if (!box) { return; }
        var a = box.getBoundingClientRect();
        var covered = Array.prototype.slice.call(canvas.querySelectorAll('.tim-object')).filter(function (other) {
          if (other === box || box.contains(other) || canvasFor(other) !== canvas) { return false; }
          var b = other.getBoundingClientRect();
          return !(b.right <= a.left || b.left >= a.right || b.bottom <= a.top || b.top >= a.bottom);
        });
        if (!covered.length) { return; }
        var top = 0;
        covered.forEach(function (other) { top = Math.max(top, parseInt(other.style.zIndex, 10) || 0); });
        box.style.zIndex = String(top + 1);
      }

      // Shared objects, page by page: what is here, what this page keeps
      // its own copy of, and what it has sent away.
      function omitList() {
        return (doc.body.getAttribute('data-tim-omit') || '').split(/\\s+/).filter(function (n) { return n; });
      }
      function setOmitList(names) {
        if (names.length) { doc.body.setAttribute('data-tim-omit', names.join(' ')); }
        else { doc.body.removeAttribute('data-tim-omit'); }
      }
      window.__timComponentState = function () {
        var present = [];
        var wraps = doc.querySelectorAll('[data-tim-component]');
        for (var i = 0; i < wraps.length; i++) {
          present.push({
            name: wraps[i].getAttribute('data-tim-component'),
            own: wraps[i].hasAttribute('data-tim-own') ? 1 : 0
          });
        }
        return JSON.stringify({ present: present, omitted: omitList() });
      };
      window.__timSetComponentOwn = function (name, own) {
        var wrap = doc.querySelector('[data-tim-component="' + name + '"]');
        if (!wrap) { return; }
        checkpoint('component');
        if (own) { wrap.setAttribute('data-tim-own', ''); } else { wrap.removeAttribute('data-tim-own'); }
        notifySel(true);
      };
      // An imported page is somebody else's HTML: their markup, their
      // stylesheets, no Tim layout anywhere in it. Rather than wrap their
      // page in a canvas and wreck it, this puts a narrow one ABOVE it —
      // a strip your own objects can live in, with their page flowing on
      // underneath exactly as its author built it. Every measurement is
      // inline, so whatever stylesheet the page carries cannot reach it.
      window.__timAddCanvasBand = function () {
        if (doc.querySelector('[data-tim-canvas]')) { return false; }
        checkpoint('band');
        var band = doc.createElement('div');
        band.className = 'tim-canvas tim-band';
        band.setAttribute('data-tim-canvas', '');
        band.setAttribute('style', [
          'display:grid',
          'grid-template-columns:repeat(24, 1fr)',
          'grid-auto-rows:32px',
          'gap:16px',
          'align-items:start',
          'box-sizing:border-box',
          'width:100%',
          'margin:0',
          'padding:0 max(16px, calc(50vw - 660px))',
          'min-height:0',
          'position:relative',
          'z-index:9999'
        ].join(';'));
        doc.body.insertBefore(band, doc.body.firstChild);
        layout();
        notifySel(true);
        return true;
      };

      // Gone from this page with no opt-out recorded — the site-wide
      // delete has already removed it everywhere else.
      window.__timDeleteComponent = function (name) {
        checkpoint('component');
        var wrap = doc.querySelector('[data-tim-component="' + name + '"]');
        if (wrap) {
          if (sel && wrap.contains(sel)) { sel = null; }
          wrap.remove();
        }
        setOmitList(omitList().filter(function (n) { return n !== name; }));
        layout();
        notifySel(true);
      };
      window.__timRemoveComponent = function (name) {
        checkpoint('component');
        var wrap = doc.querySelector('[data-tim-component="' + name + '"]');
        if (wrap) {
          if (sel && wrap.contains(sel)) { sel = null; }
          wrap.remove();
        }
        var names = omitList();
        if (names.indexOf(name) < 0) { names.push(name); }
        setOmitList(names);
        layout();
        notifySel(true);
      };
      window.__timAddComponent = function (name, html) {
        var canvas = doc.querySelector('[data-tim-canvas]:not(.tim-container)') || doc.querySelector('[data-tim-canvas]');
        if (!canvas) { return; }
        checkpoint('component');
        setOmitList(omitList().filter(function (n) { return n !== name; }));
        var existing = doc.querySelector('[data-tim-component="' + name + '"]');
        if (existing) { existing.remove(); }
        var tmp = doc.createElement('div');
        tmp.innerHTML = html;
        var wrap = tmp.firstElementChild;
        if (!wrap) { return; }
        canvas.insertBefore(wrap, canvas.firstChild);
        bringToFront(wrap, canvas);
        layout();
        notifySel(true);
      };
      window.__timResetComponent = function (name, html) {
        var wrap = doc.querySelector('[data-tim-component="' + name + '"]');
        if (!wrap) { return; }
        checkpoint('component');
        wrap.removeAttribute('data-tim-own');
        wrap.innerHTML = html;
        var canvas = canvasFor(wrap.firstElementChild) || doc.querySelector('[data-tim-canvas]');
        bringToFront(wrap, canvas);
        layout();
        notifySel(true);
      };

      var insertPoint = null;
      window.__timInsertAt = function (html, colSpan, rowSpan, x, y) {
        insertPoint = { x: x, y: y };
        try { window.__timInsert(html, colSpan, rowSpan); } finally { insertPoint = null; }
      };
      window.__timInsert = function (html, colSpan, rowSpan) {
        colSpan = Math.max(1, Math.min(COLS, colSpan || 12));
        rowSpan = Math.max(1, rowSpan || 3);
        var canvas = doc.querySelector('[data-tim-canvas]');
        if (!canvas) {
          canvas = doc.createElement('div');
          canvas.setAttribute('data-tim-canvas', '');
          canvas.className = 'tim-canvas';
          doc.body.appendChild(canvas);
        }
        var tmp = doc.createElement('div');
        tmp.innerHTML = html;
        var el = tmp.firstElementChild;
        if (!el) { return; }
        // Component wrappers are display:contents — the grid placement
        // belongs on the element inside, not the wrapper. Inserting a
        // component also clears this page's opt-out for it.
        var placed = el;
        if (el.getAttribute && el.getAttribute('data-tim-component')) {
          var cn = el.getAttribute('data-tim-component');
          var om = (doc.body.getAttribute('data-tim-omit') || '').split(' ').filter(function (n) { return n && n !== cn; });
          if (om.length) { doc.body.setAttribute('data-tim-omit', om.join(' ')); }
          else { doc.body.removeAttribute('data-tim-omit'); }
          if (el.firstElementChild) { placed = el.firstElementChild; }
        }
        // New objects always get a desktop position (end of the page);
        // in mobile editing they also join the bottom of the mobile stack.
        var maxRe = 1;
        Array.prototype.forEach.call(canvas.children, function (c) {
          var p = desktopPlacement(c);
          if (p && p.re > maxRe) { maxRe = p.re; }
        });
        checkpoint('insert');
        // Dropped at a point: that cell is where it goes, on whichever
        // layout is being edited. Otherwise the end of the page.
        var at = insertPoint ? cellAt(canvas, insertPoint.x, insertPoint.y) : null;
        if (at && !mobileActive()) {
          var atCs = Math.max(1, Math.min(colCount() - colSpan + 1, at.cs));
          setDesktopArea(placed, at.rs, atCs, at.rs + rowSpan, atCs + colSpan);
        } else {
          setDesktopArea(placed, maxRe, 1, maxRe + rowSpan, 1 + colSpan);
        }
        // Into the document BEFORE any mobile bookkeeping — the layout
        // writer prunes entries whose elements aren't in the page yet,
        // which silently erased a new object's mobile placement.
        canvas.appendChild(el);
        if (placed.classList && placed.classList.contains('tim-nav')) { window.__timNavAssets(); }
        // Reading order is DOM order, and DOM order is what the phone
        // follows — so an object dropped near the top of the page has to
        // take its place in the document there, not at the end of it.
        resort(canvas);
        if (mobileActive()) {
          var mMax = 1;
          for (var mid in mobileLayout) { mMax = Math.max(mMax, mobileLayout[mid][2]); }
          var span = Math.min(MOBILE_COLS, colSpan);
          if (at) {
            mobileLayoutMode = 'custom';
            var mcs = Math.max(1, Math.min(MOBILE_COLS - Math.max(2, span) + 1, at.cs));
            mobileLayout[ensureObjectId(placed)] = [at.rs, mcs, at.rs + rowSpan, mcs + Math.max(2, span)];
          } else {
            mobileLayout[ensureObjectId(placed)] = [mMax, 1, mMax + rowSpan, 1 + Math.max(2, span)];
          }
          writeMobileLayout();
          // The desktop position was a guess (end of page) — worth a look.
          flagReview('desktop', placed);
        } else if (Object.keys(mobileLayout).length) {
          // The phone layout is explicit, so give this object a real place
          // in it now — full width, its own height, in reading order —
          // rather than leaving it to inherit a desktop grid-area that
          // means nothing at 390.
          writeMobileLayout();
          flagReview('mobile', placed);
        }
        el = placed;
        var media = (el.matches && el.matches('img,video,audio'))
          ? el
          : (el.querySelector ? el.querySelector('img,video,audio') : null);
        if (media) {
          el.classList.add('tim-loading');
          var settle = function () {
            el.classList.remove('tim-loading');
            // Now that the file's real proportions are known, the phone
            // layout can size its row properly.
            if (Object.keys(mobileLayout).length) { writeMobileLayout(); }
            layout();
          };
          media.addEventListener('load', settle);
          media.addEventListener('loadeddata', settle);
          media.addEventListener('canplay', settle);
          media.addEventListener('error', settle);
          if ((media.tagName === 'IMG' && media.complete) || media.readyState >= 2) { settle(); }
        }
        stopTextEditing();
        sel = el;
        fitSpan(el);
        layout();
        // You put it there, so it goes on top of whatever it landed on.
        bringToFront(el, canvas);
        notifySel();
        el.scrollIntoView({ block: 'nearest' });
      };

      // Undo/redo: canvas states as snapshots, checkpointed before every
      // mutation. Rapid same-tag changes (a slider drag) coalesce into one
      // step. Text editing keeps the browser's native undo; leaving text
      // editing folds the whole session into one canvas step.
      var undoStack = [], redoStack = [], lastCkptTag = '', lastCkptTime = 0;
      function canvasEl() { return doc.querySelector('[data-tim-canvas]'); }
      // Snapshots carry the canvas AND the visible page options (the
      // template rules), so undo covers background/color/layout changes
      // the Keynote way. Invisible metadata stays out — text fields give
      // it field-level undo while editing, and that's where it ends.
      function takeSnapshot() {
        var c = canvasEl();
        if (!c) { return null; }
        var stylesEl = doc.querySelector('style[data-tim-styles]');
        // The look rides along too — a theme or a named-style edit undoes
        // like anything else.
        return { c: c.innerHTML, p: JSON.stringify(templateProps), m: JSON.stringify(mobileLayout), mm: mobileLayoutMode, t: JSON.stringify(mobileType),
                 s: stylesEl ? stylesEl.outerHTML : '', o: JSON.stringify(styleRules), tn: doc.body.getAttribute('data-tim-template') || 'default' };
      }
      function sameSnapshot(a, b) { return !!a && !!b && a.c === b.c && a.p === b.p && a.m === b.m && a.mm === b.mm && a.t === b.t && a.s === b.s && a.o === b.o && a.tn === b.tn; }
      function checkpoint(tag) {
        var snap = takeSnapshot();
        if (!snap) { return; }
        var now = Date.now();
        if (tag && tag === lastCkptTag && now - lastCkptTime < 900) { lastCkptTime = now; return; }
        lastCkptTag = tag || '';
        lastCkptTime = now;
        if (undoStack.length && sameSnapshot(undoStack[undoStack.length - 1], snap)) { return; }
        undoStack.push(snap);
        if (undoStack.length > 60) { undoStack.shift(); }
        redoStack.length = 0;
      }
      function restoreSnapshot(snap) {
        var c = canvasEl();
        if (!c || !snap) { return; }
        stopTextEditing();
        clearGroup();
        sel = null;
        cropping = null;
        hide();
        lastCkptTag = '';
        c.innerHTML = snap.c;
        // A snapshot may have been taken mid-flight. Restoring one must
        // not bring back a picture marked as being replaced: no upload is
        // coming for it, so it would pulse for ever.
        Array.prototype.forEach.call(c.querySelectorAll('[data-tim-replace], .tim-media-replacing'), function (stale) {
          stale.removeAttribute('data-tim-replace');
          stale.classList.remove('tim-media-replacing');
        });
        try { templateProps = JSON.parse(snap.p) || {}; } catch (e) { templateProps = {}; }
        if (snap.s) {
          var curStyles = doc.querySelector('style[data-tim-styles]');
          if (!curStyles || curStyles.outerHTML !== snap.s) {
            var holder = doc.createElement('div');
            holder.innerHTML = snap.s;
            if (holder.firstElementChild) {
              if (curStyles) { curStyles.replaceWith(holder.firstElementChild); } else { doc.head.appendChild(holder.firstElementChild); }
            }
          }
        }
        if (snap.o) { try { styleRules = JSON.parse(snap.o) || {}; writeOverrides(); } catch (e4) {} }
        if (snap.tn) { doc.body.setAttribute('data-tim-template', snap.tn); }
        try { mobileLayout = JSON.parse(snap.m || '{}') || {}; } catch (e2) { mobileLayout = {}; }
        mobileLayoutMode = snap.mm === 'stack' ? 'stack' : 'custom';
        try { mobileType = JSON.parse(snap.t || '{}') || {}; } catch (e3) { mobileType = {}; }
        writeTemplates();
        if (Object.keys(mobileLayout).length) {
          writeMobileLayout();
        } else {
          var oldMobile = doc.querySelector('style[data-tim-mobile-layout]');
          if (oldMobile) { oldMobile.remove(); }
          syncMobileModeClass();
        }
        writeMobileType();
        layout();
        notifySel(true);
      }
      window.__timUndo = function () {
        if (editingEl) { doc.execCommand('undo'); return; }
        if (!undoStack.length) { return; }
        var now = takeSnapshot();
        if (!now) { return; }
        redoStack.push(now);
        restoreSnapshot(undoStack.pop());
      };
      window.__timRedo = function () {
        if (editingEl) { doc.execCommand('redo'); return; }
        if (!redoStack.length) { return; }
        var now = takeSnapshot();
        if (!now) { return; }
        undoStack.push(now);
        restoreSnapshot(redoStack.pop());
      };

      // Typed placement from the inspector's cell fields — mode-aware,
      // clamped onto the page (which makes them the rescue lane for
      // anything stranded off it).
      window.__timSetArea = function (rs, cs, re, ce) {
        if (!sel || !isObject(sel) || !placement(sel)) { return; }
        checkpoint('area');
        if (mobileActive()) { mobileLayoutMode = 'custom'; }
        setArea(sel, rs, cs, re, ce);
        fitSpan(sel);
        layout();
      };

      // Groups: a composition becomes one object. The container is itself
      // a small canvas — same column rhythm as the cells it occupies, so
      // children keep their exact size and position — and as an object it
      // moves, resizes (children scale with it), fills, and ROTATES as a
      // unit. The bounded way to tilt a whole composition.
      window.__timGroupSel = function () {
        // Template components (the nav) live on every page — they can't
        // be captured into a page-local group, so they sit grouping out.
        var members = groupAll().filter(function (el) {
          return isObject(el) && desktopPlacement(el)
            && !(el.closest && el.closest('[data-tim-component]'));
        });
        if (members.length < 2) { return; }
        var canvas = canvasFor(members[0]);
        if (!canvas) { return; }
        for (var gi = 0; gi < members.length; gi++) {
          if (canvasFor(members[gi]) !== canvas) { return; }
        }
        checkpoint('group');
        var rs = 1e9, cs = 1e9, re = 0, ce = 0;
        members.forEach(function (el) {
          var p = desktopPlacement(el);
          rs = Math.min(rs, p.rs); cs = Math.min(cs, p.cs);
          re = Math.max(re, p.re); ce = Math.max(ce, p.ce);
        });
        var container = doc.createElement('div');
        container.className = 'tim-object tim-container';
        container.setAttribute('data-tim-canvas', '');
        container.style.cssText = 'display:grid;grid-template-columns:repeat(' + (ce - cs) + ', 1fr);grid-auto-rows:32px;gap:16px;min-width:0;';
        setDesktopArea(container, rs, cs, re, ce);
        // Insert at the first member's top-level position (a member may
        // sit inside a display:contents wrapper).
        var ref = members[0];
        while (ref.parentElement && ref.parentElement !== canvas) { ref = ref.parentElement; }
        canvas.insertBefore(container, ref);
        // The group takes over its members' place in the mobile stack.
        var mobileUnion = null;
        members.forEach(function (el) {
          var p = desktopPlacement(el);
          setDesktopArea(el, p.rs - rs + 1, p.cs - cs + 1, p.re - rs + 1, p.ce - cs + 1);
          container.appendChild(el);
          var mid = el.getAttribute('data-tim-id');
          if (mid && mobileLayout[mid]) {
            var area = mobileLayout[mid];
            mobileUnion = mobileUnion
              ? [Math.min(mobileUnion[0], area[0]), 1, Math.max(mobileUnion[2], area[2]), MOBILE_COLS + 1]
              : [area[0], 1, area[2], MOBILE_COLS + 1];
            delete mobileLayout[mid];
          }
        });
        if (Object.keys(mobileLayout).length || mobileUnion) {
          if (mobileUnion) { mobileLayout[ensureObjectId(container)] = mobileUnion; }
          writeMobileLayout();
        }
        clearGroup();
        sel = container;
        layout();
        notifySel(true);
      };
      window.__timUngroupSel = function () {
        if (!sel || !sel.classList || !sel.classList.contains('tim-container')) { return; }
        checkpoint('ungroup');
        var p0 = desktopPlacement(sel);
        var parentCanvas = canvasFor(sel);
        if (!p0 || !parentCanvas) { return; }
        var hadMobile = Object.keys(mobileLayout).length > 0;
        var selId = sel.getAttribute('data-tim-id');
        var groupEntry = hadMobile && selId ? mobileLayout[selId] : null;
        // Ungrouping must not move anything the eye can see. The group's
        // rotation can't survive (children return to the page grid), so
        // shed it first — then measure each child exactly as rendered and
        // write those pixels back as cells of the layout being edited.
        // The old arithmetic restore drifted off the page whenever the
        // group had been moved or resized since it was made.
        sel.style.transform = '';
        var kids = Array.prototype.slice.call(sel.children);
        var g = gridInfo(parentCanvas);
        var cols = colCount();
        var measured = kids.map(function (el) {
          var r = el.getBoundingClientRect();
          var ang = angleOf(el);
          if (ang) {
            // A rotated child keeps its own tilt — place its unrotated
            // frame, not the swollen bounding box.
            var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
            r = { left: cx - el.offsetWidth / 2, right: cx + el.offsetWidth / 2,
                  top: cy - el.offsetHeight / 2, bottom: cy + el.offsetHeight / 2 };
          }
          var mcs = Math.round((r.left - g.originX) / (g.colW + g.gap)) + 1;
          var mce = Math.round((r.right - g.originX + g.gap) / (g.colW + g.gap)) + 1;
          var mrs = Math.round((r.top - g.originY) / (g.rowH + g.rowGap)) + 1;
          var mre = Math.round((r.bottom - g.originY + g.rowGap) / (g.rowH + g.rowGap)) + 1;
          var w = Math.max(1, Math.min(cols, mce - mcs));
          mcs = Math.max(1, Math.min(cols + 1 - w, mcs));
          mrs = Math.max(1, mrs);
          return { rs: mrs, cs: mcs, re: Math.max(mrs + 1, mre), ce: mcs + w };
        });
        var mobileRow = 1;
        if (hadMobile) {
          // Children take over the group's old slot in the stack — never
          // the bottom of the page; overlap resolution nudges what sat below.
          if (groupEntry) { mobileRow = groupEntry[0]; }
          else { for (var mk in mobileLayout) { mobileRow = Math.max(mobileRow, mobileLayout[mk][2]); } }
          if (selId) { delete mobileLayout[selId]; }
        }
        kids.forEach(function (el, i) {
          var isObj = el.classList && el.classList.contains('tim-object');
          var m = measured[i];
          var p = desktopPlacement(el);
          if (isObj) {
            if (mobileActive()) {
              // Mobile is on screen: measurements are the mobile cells;
              // desktop restores arithmetically, clamped onto the page.
              if (p) {
                var dw = Math.max(1, Math.min(COLS, p.ce - p.cs));
                var dcs = Math.max(1, Math.min(COLS + 1 - dw, p.cs + p0.cs - 1));
                setDesktopArea(el, p.rs + p0.rs - 1, dcs, p.re + p0.rs - 1, dcs + dw);
              }
            } else {
              setDesktopArea(el, m.rs, m.cs, m.re, m.ce);
            }
          }
          parentCanvas.insertBefore(el, sel);
          if (hadMobile && isObj) {
            if (mobileActive()) {
              mobileLayout[ensureObjectId(el)] = [m.rs, m.cs, m.re, m.ce];
            } else {
              var rows = p ? (p.re - p.rs) : 2;
              mobileLayout[ensureObjectId(el)] = [mobileRow, 1, mobileRow + rows, MOBILE_COLS + 1];
              mobileRow += rows;
            }
          }
        });
        sel.remove();
        if (hadMobile) { writeMobileLayout(); }
        sel = null;
        hide();
        notifySel(true);
      };

      // Standard alignment: several objects align to each other's extent;
      // a single object aligns to its page (or its container). Works in
      // both layouts — mobile alignment writes mobile placements.
      window.__timAlign = function (edge) {
        var members = groupAll().filter(function (el) { return isObject(el) && placement(el); });
        if (!members.length) { return; }
        checkpoint('align');
        if (mobileActive()) { mobileLayoutMode = 'custom'; }
        var cols = colCount();
        var reference;
        if (members.length === 1) {
          var host = canvasFor(members[0]);
          var contentRe = 1;
          if (host) {
            Array.prototype.forEach.call(host.querySelectorAll('.tim-object'), function (el) {
              if (canvasFor(el) !== host) { return; }
              var p = placement(el);
              if (p && p.re > contentRe) { contentRe = p.re; }
            });
          }
          reference = { cs: 1, ce: cols + 1, rs: 1, re: contentRe };
        } else {
          reference = { cs: 1e9, ce: 0, rs: 1e9, re: 0 };
          members.forEach(function (el) {
            var p = placement(el);
            reference.cs = Math.min(reference.cs, p.cs);
            reference.ce = Math.max(reference.ce, p.ce);
            reference.rs = Math.min(reference.rs, p.rs);
            reference.re = Math.max(reference.re, p.re);
          });
        }
        members.forEach(function (el) {
          var p = placement(el);
          var w = p.ce - p.cs, hgt = p.re - p.rs;
          var rs = p.rs, cs = p.cs;
          if (edge === 'left') { cs = reference.cs; }
          if (edge === 'right') { cs = reference.ce - w; }
          if (edge === 'centerX') { cs = Math.max(1, Math.round(reference.cs + (reference.ce - reference.cs - w) / 2)); }
          if (edge === 'top') { rs = reference.rs; }
          if (edge === 'bottom') { rs = Math.max(1, reference.re - hgt); }
          if (edge === 'centerY') { rs = Math.max(1, Math.round(reference.rs + (reference.re - reference.rs - hgt) / 2)); }
          setArea(el, rs, cs, rs + hgt, cs + w);
        });
        if (!mobileActive()) { resort(canvasFor(members[0])); }
        layout();
        notifySel();
      };

      // Keynote-style arrange: reorder the selection among the objects it
      // actually overlaps, then write compact z-indexes for just that
      // group (0 stays implicit). Non-overlapping objects never matter
      // visually, so their z values are left alone.
      window.__timZ = function (action) {
        if (!sel || !isObject(sel)) { return; }
        var canvas = canvasFor(sel);
        if (!canvas) { return; }
        var all = Array.prototype.slice.call(canvas.querySelectorAll('.tim-object'));
        var r0 = sel.getBoundingClientRect();
        var scope = all.filter(function (el) {
          if (el === sel) { return true; }
          var r = el.getBoundingClientRect();
          return !(r.right <= r0.left || r.left >= r0.right || r.bottom <= r0.top || r.top >= r0.bottom);
        });
        if (scope.length < 2) { return; }
        checkpoint('arrange');
        scope.sort(function (a, b) {
          var za = parseInt(a.style.zIndex, 10) || 0;
          var zb = parseInt(b.style.zIndex, 10) || 0;
          return (za - zb) || (all.indexOf(a) - all.indexOf(b));
        });
        var i = scope.indexOf(sel);
        scope.splice(i, 1);
        if (action === 'front') { scope.push(sel); }
        else if (action === 'back') { scope.unshift(sel); }
        else if (action === 'forward') { scope.splice(Math.min(i + 1, scope.length), 0, sel); }
        else { scope.splice(Math.max(i - 1, 0), 0, sel); }
        scope.forEach(function (el, idx) { el.style.zIndex = idx === 0 ? '' : String(idx); });
        layout();
        notifySel();
      };

      // Media arrives in two beats: a shimmer placeholder right away, the
      // real element when the upload lands (keeping any move/resize the
      // user did to the placeholder meanwhile).
      window.__timResolvePlaceholder = function (id, html) {
        var ph = doc.querySelector('[data-tim-placeholder=' + JSON.stringify(id) + ']');
        if (!ph) { return; }
        var tmp = doc.createElement('div');
        tmp.innerHTML = html;
        var el = tmp.firstElementChild;
        if (!el) { ph.remove(); layout(); return; }
        checkpoint('media');
        if (ph.style && ph.style.gridArea) { el.style.gridArea = ph.style.gridArea; }
        // The identity travels with the swap — the mobile layout entry
        // written at insert is keyed by it, and a fresh id would strand
        // that placement as stale.
        var pid = ph.getAttribute('data-tim-id');
        if (pid && !el.getAttribute('data-tim-id')) { el.setAttribute('data-tim-id', pid); }
        ph.parentNode.replaceChild(el, ph);
        if (sel === ph) { sel = el; }
        // Once the media renders, snug its mobile box to the real aspect
        // (height:auto already draws it right — this closes the leftover
        // track gap under the image).
        var rm = (el.matches && el.matches('img,video')) ? el : (el.querySelector ? el.querySelector('img,video') : null);
        if (rm) {
          var refit = function () {
            var mid = el.getAttribute('data-tim-id');
            if (!mid || !mobileLayout[mid] || !collapsed()) { return; }
            var rect = el.getBoundingClientRect();
            if (rect.height < 8) { return; }
            var a = mobileLayout[mid];
            a[2] = a[0] + Math.max(2, Math.round((rect.height + 16) / 48));
            writeMobileLayout();
            layout();
          };
          rm.addEventListener('load', refit);
          rm.addEventListener('loadeddata', refit);
          if ((rm.tagName === 'IMG' && rm.complete) || rm.readyState >= 2) { setTimeout(refit, 0); }
        }
        layout();
        notifySel(true);
      };
      window.__timFailPlaceholder = function (id, message) {
        var ph = doc.querySelector('[data-tim-placeholder=' + JSON.stringify(id) + ']');
        if (!ph) { return; }
        ph.classList.add('tim-media-failed');
        var lbl = ph.querySelector('.tim-media-loading-label');
        if (lbl) { lbl.textContent = message; }
      };
      // Replace flow: tag the selected media now, swap it by tag when the
      // new file's upload lands — placement, styling, and classes survive.
      window.__timMarkSelMedia = function (id) {
        if (!sel) { return false; }
        var target = (sel.matches && sel.matches('img,video,audio'))
          ? sel : (sel.querySelector ? sel.querySelector('img,video,audio') : null);
        if (!target) { return false; }
        checkpoint('media');
        target.setAttribute('data-tim-replace', id);
        target.classList.add('tim-media-replacing');
        return true;
      };
      window.__timUnmarkMedia = function (id) {
        var target = doc.querySelector('[data-tim-replace=' + JSON.stringify(id) + ']');
        if (!target) { return; }
        target.removeAttribute('data-tim-replace');
        target.classList.remove('tim-media-replacing');
      };
      window.__timReplaceMedia = function (id, html) {
        var target = doc.querySelector('[data-tim-replace=' + JSON.stringify(id) + ']');
        if (!target) { return; }
        var tmp = doc.createElement('div');
        tmp.innerHTML = html;
        var el = tmp.firstElementChild;
        if (!el) { target.removeAttribute('data-tim-replace'); target.classList.remove('tim-media-replacing'); return; }
        target.classList.remove('tim-media-replacing');
        if (target.className) { el.className = target.className; }
        if (target.style && target.style.cssText) { el.style.cssText = target.style.cssText; }
        target.parentNode.replaceChild(el, target);
        if (sel === target) { sel = el; }
        // A new picture in a cropped frame: its own proportions, covering.
        var frame = el.parentNode && cropWrap(el.parentNode);
        if (frame) {
          var refit = function () {
            var c = readCrop(frame);
            if (el.naturalWidth > 0) { c.r = el.naturalHeight / el.naturalWidth; }
            c.s = Math.max(c.s, coverScale(frame));
            writeCrop(frame, c);
            layout();
          };
          if (el.complete && el.naturalWidth) { refit(); } else { el.addEventListener('load', refit); }
        }
        layout();
        notifySel(true);
      };

      var selSeq = 0;
      var lastNotified = null;
      var selPath = [];
      // Objects speak the product's language, never the web's: a text box
      // is named by its style (Title, Body, a custom name), media by what
      // it is, components by their name — and nothing is ever a "div".
      function labelFor(el) {
        if (el.classList && el.classList.contains('tim-crop')) { return 'Image'; }
        if (el.classList && el.classList.contains('tim-container')) { return 'Group'; }
        if (el.hasAttribute && el.hasAttribute('data-tim-canvas')) { return 'Canvas'; }
        function titleCase(text) {
          return text.replace(/-/g, ' ').replace(/(^|\\s)\\w/g, function (c) { return c.toUpperCase(); });
        }
        var comp = el.getAttribute && el.getAttribute('data-tim-component');
        if (comp) { return comp === 'tpl-nav' ? 'Navigation' : titleCase(comp.replace(/^tpl-/, '')); }
        var t = el.tagName ? el.tagName.toLowerCase() : '';
        if (t === 'img') { return 'Image'; }
        if (t === 'video') { return 'Video'; }
        if (t === 'audio') { return 'Audio'; }
        if (t === 'nav') { return 'Navigation'; }
        if (t === 'a') { return 'Link'; }
        if (el.classList) {
          if (el.classList.contains('tim-nav')) { return 'Navigation'; }
          var style = '';
          String(el.className || '').split(/\\s+/).forEach(function (c) {
            if (c.indexOf('tim-style-') === 0) { style = c.slice(10); }
          });
          if (style) { return titleCase(style); }
          if (el.classList.contains('tim-text')) { return 'Text'; }
          if (el.classList.contains('tim-object')) { return 'Object'; }
        }
        if (/^h[1-6]$/.test(t)) { return 'Heading'; }
        if (t === 'p' || t === 'blockquote' || t === 'li' || t === 'span' || t === 'em' || t === 'strong') { return 'Text'; }
        if (t === 'ul' || t === 'ol') { return 'List'; }
        if (t === 'table') { return 'Table'; }
        if (t === 'button') { return 'Button'; }
        if (t === 'form') { return 'Form'; }
        return 'Block';
      }
      // forceReseed bumps the sequence so the Inspector re-seeds its
      // controls; live edits keep the sequence stable (values update
      // without interrupting a slider drag).
      function notifySel(forceReseed) {
        try {
          var payload = '';
          if (sel !== lastNotified || forceReseed) { selSeq += 1; }
          lastNotified = sel;
          if (sel) {
            selPath = [];
            var node = sel;
            while (node && node !== doc.body && selPath.length < 6) {
              selPath.unshift(node);
              node = node.parentElement;
            }
            var cs = getComputedStyle(sel);
            var timStyle = '';
            String(sel.className || '').split(/\\s+/).forEach(function (c) {
              if (c.indexOf('tim-style-') === 0) { timStyle = c; }
            });
            payload = JSON.stringify({
              seq: selSeq,
              path: selPath.map(labelFor),
              label: labelFor(sel),
              tag: sel.tagName.toLowerCase(),
              timStyle: timStyle,
              isText: (sel.classList && (sel.classList.contains('tim-text') || sel.classList.contains('tim-nav'))) ? 1 : 0,
              wrap: wrapMode(sel),
              fontSize: parseFloat(cs.fontSize) || 16,
              fontWeight: parseInt(cs.fontWeight, 10) || 400,
              align: cs.textAlign,
              color: cs.color,
              radius: parseFloat(sel.style.borderRadius) || 0,
              opacity: parseFloat(cs.opacity) || 1,
              padding: parseFloat(sel.style.padding) || 0,
              margin: parseFloat(sel.style.margin) || 0,
              media: (function () {
                var m = (sel.tagName === 'IMG' || sel.tagName === 'VIDEO') ? sel : (cropWrap(sel) ? mediaOf(sel) : null);
                return m ? {
                  natW: m.naturalWidth || m.videoWidth || 0,
                  natH: m.naturalHeight || m.videoHeight || 0,
                  shownW: Math.round(sel.getBoundingClientRect().width),
                  src: m.currentSrc || m.getAttribute('src') || ''
                } : 0;
              })(),
              crop: (function () {
                var w = cropWrap(sel);
                if (!w) { return sel.tagName === 'IMG' ? { s: 100, min: 100, active: 0, wrapped: 0 } : 0; }
                var c = readCrop(w);
                return { s: Math.round(c.s * 100), min: Math.round(Math.min(380, coverScale(w) * 100)), active: cropping === w ? 1 : 0, wrapped: 1 };
              })(),
              area: (function () { var pp = placement(sel); return pp ? [pp.rs, pp.cs, pp.re, pp.ce] : null; })(),
              maxCols: colCount(),
              hasShadow: sel.style.boxShadow ? 1 : 0,
              hasTextShadow: sel.style.textShadow ? 1 : 0,
              selCount: groupAll().length,
              customStyles: Object.keys(styleRules),
              fill: sel.style.background || '',
              overrides: TYPO_PROPS.some(function (p) { return !!sel.style[p]; }) ? 1 : 0,
              templateComponent: (function () {
                var wrap = sel.closest ? sel.closest('[data-tim-component]') : null;
                return wrap ? (wrap.getAttribute('data-tim-component') || '') : '';
              })(),
              templateOwn: (function () {
                var wrap = sel.closest ? sel.closest('[data-tim-component]') : null;
                return wrap && wrap.hasAttribute('data-tim-own') ? 1 : 0;
              })(),
              fontFamily: String(cs.fontFamily || '').split(',')[0].replace(/["']/g, '').trim(),
              italic: cs.fontStyle === 'italic' ? 1 : 0,
              underline: (cs.textDecorationLine || '').indexOf('underline') >= 0 ? 1 : 0,
              strike: (cs.textDecorationLine || '').indexOf('line-through') >= 0 ? 1 : 0,
              caps: (cs.fontVariantCaps === 'small-caps' || cs.fontVariant === 'small-caps')
                ? 'small' : (cs.textTransform === 'uppercase' ? 'upper'
                : (cs.textTransform === 'capitalize' ? 'title' : 'none')),
              video: (sel.tagName === 'VIDEO') ? {
                autoplay: sel.hasAttribute('autoplay') ? 1 : 0,
                loop: sel.hasAttribute('loop') ? 1 : 0,
                muted: sel.hasAttribute('muted') ? 1 : 0,
                controls: sel.hasAttribute('controls') ? 1 : 0,
                bounce: sel.hasAttribute('data-tim-plain-src') ? 1 : 0,
                src: sel.getAttribute('src') || ''
              } : 0,
              mobileHidden: (sel.hasAttribute && sel.hasAttribute('data-tim-mobile-hidden')) ? 1 : 0,
              nav: (sel.classList && sel.classList.contains('tim-nav')) ? navRead(sel) : 0,
              rotation: (function () {
                var m = /rotate\\((-?[0-9.]+)deg\\)/.exec(sel.style.transform || '');
                return m ? parseFloat(m[1]) : 0;
              })(),
              columns: parseInt(cs.columnCount, 10) || 1,
              lineHeight: (parseFloat(cs.lineHeight) || 1.4 * (parseFloat(cs.fontSize) || 16)) / (parseFloat(cs.fontSize) || 16),
              letterSpacing: cs.letterSpacing === 'normal' ? 0 : (parseFloat(cs.letterSpacing) || 0)
            });
          }
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.timSel) {
            window.webkit.messageHandlers.timSel.postMessage(payload);
          }
        } catch (e) {}
      }
      window.__timSetStyle = function (prop, value) {
        if (!sel) { return; }
        // The PAGE canvas is the scroll root — rotating it tilts the page
        // into unreachable space. Never. Group containers rotate freely.
        if (prop === 'transform' && sel.hasAttribute && sel.hasAttribute('data-tim-canvas')
            && !(sel.classList && sel.classList.contains('tim-container'))) { return; }
        checkpoint('style:' + prop);
        // A size chosen while looking at the phone belongs to the phone.
        if (prop === 'fontSize' && mobileActive()) {
          groupAll().forEach(function (member) {
            var px = parseFloat(value);
            if (px > 0) { mobileType[ensureObjectId(member)] = px; }
          });
          writeMobileType();
          layout();
          notifySel();
          return;
        }
        groupAll().forEach(function (member) { member.style[prop] = value; });
        layout();
        notifySel();
      };

      // Page-scoped named styles, the Pages/Keynote way: "Update Style"
      // rewrites the style's rule in a persistent <style> element (saved
      // with the page), so every block carrying the class follows.
      var TYPO_PROPS = ['fontFamily', 'fontSize', 'fontWeight', 'color', 'lineHeight', 'letterSpacing', 'textAlign',
                        'fontStyle', 'textDecoration', 'textTransform', 'fontVariant', 'columnCount', 'columnGap'];
      var styleRules = {};
      (function parseExistingOverrides() {
        var el = doc.querySelector('style[data-tim-style-overrides]');
        if (!el) { return; }
        var re = /\\.(tim-style-[a-z]+)\\s*\\{([^}]*)\\}/g;
        var m;
        while ((m = re.exec(el.textContent))) { styleRules[m[1]] = m[2]; }
      })();
      function writeOverrides() {
        var el = doc.querySelector('style[data-tim-style-overrides]');
        if (!el) {
          el = doc.createElement('style');
          el.setAttribute('data-tim-style-overrides', '');
          doc.head.appendChild(el);
        }
        var out = '';
        for (var key in styleRules) { out += '.' + key + '{' + styleRules[key] + '}\\n'; }
        el.textContent = out;
      }
      function selStyleClass() {
        var cls = '';
        if (sel) {
          String(sel.className || '').split(/\\s+/).forEach(function (c) {
            if (c.indexOf('tim-style-') === 0) { cls = c; }
          });
        }
        return cls;
      }
      function typographyCSS(el) {
        var cs = getComputedStyle(el);
        var ratio = (parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.4) / (parseFloat(cs.fontSize) || 16);
        return 'font-family:' + cs.fontFamily +
          ';font-size:' + cs.fontSize +
          ';font-weight:' + cs.fontWeight +
          ';color:' + cs.color +
          ';line-height:' + ratio.toFixed(2) +
          ';letter-spacing:' + (cs.letterSpacing === 'normal' ? 'normal' : cs.letterSpacing) +
          ';text-align:' + cs.textAlign + ';';
      }
      window.__timUpdateStyleFromSel = function () {
        if (!sel) { return ''; }
        var cls = selStyleClass();
        if (!cls) { cls = 'tim-style-body'; sel.classList.add(cls); }
        styleRules[cls] = typographyCSS(sel);
        writeOverrides();
        TYPO_PROPS.forEach(function (p) { sel.style[p] = ''; });
        layout();
        notifySel(true);
        return cls;
      };
      window.__timCreateStyleFromSel = function (cls) {
        if (!sel) { return; }
        styleRules[cls] = typographyCSS(sel);
        writeOverrides();
        groupAll().forEach(function (member) {
          String(member.className || '').split(/\\s+/).forEach(function (c) {
            if (c.indexOf('tim-style-') === 0) { member.classList.remove(c); }
          });
          member.classList.add(cls);
          TYPO_PROPS.forEach(function (p) { member.style[p] = ''; });
        });
        layout();
        notifySel(true);
      };
      window.__timRenameStyle = function (oldCls, newCls) {
        if (styleRules[oldCls]) {
          styleRules[newCls] = styleRules[oldCls];
          delete styleRules[oldCls];
          writeOverrides();
        }
        var renamed = doc.querySelectorAll('.' + oldCls);
        for (var ri = 0; ri < renamed.length; ri++) {
          renamed[ri].classList.remove(oldCls);
          renamed[ri].classList.add(newCls);
        }
        notifySel(true);
      };
      window.__timDeleteStyle = function (cls) {
        delete styleRules[cls];
        writeOverrides();
        var orphans = doc.querySelectorAll('.' + cls);
        for (var oi = 0; oi < orphans.length; oi++) {
          orphans[oi].classList.remove(cls);
          orphans[oi].classList.add('tim-style-body');
        }
        notifySel(true);
      };
      window.__timRevertSel = function () {
        if (!sel) { return; }
        TYPO_PROPS.forEach(function (p) { sel.style[p] = ''; });
        layout();
        notifySel();
      };

      // Templates: named page-option sets, contained by the theme. Each
      // page's body carries data-tim-template; page options edit the
      // template's rule, so every page on that template follows. v1 ships
      // one template, "default" — deliberately blank until edited.
      var templateProps = {};
      (function parseTemplates() {
        var el = doc.querySelector('style[data-tim-templates]');
        if (!el) { return; }
        try { templateProps = JSON.parse(el.getAttribute('data-props') || '{}'); } catch (e) {}
      })();
      function writeTemplates() {
        var el = doc.querySelector('style[data-tim-templates]');
        if (!el) {
          el = doc.createElement('style');
          el.setAttribute('data-tim-templates', '');
          doc.head.appendChild(el);
        }
        el.setAttribute('data-props', JSON.stringify(templateProps));
        var out = '';
        for (var name in templateProps) {
          var p = templateProps[name];
          var scope = 'body[data-tim-template="' + name + '"]';
          // Each option is also a custom property, so a theme's own
          // pieces — a button, an eyebrow's bar — can follow the page's
          // colors and type without knowing anything about the page.
          var bodyRule = '';
          if (p.bg) { bodyRule += 'background:' + p.bg + ';'; }
          if (p.fg) { bodyRule += 'color:' + p.fg + ';--tim-ink:' + p.fg + ';'; }
          if (p.link) { bodyRule += '--tim-link:' + p.link + ';'; }
          if (p.accent) { bodyRule += '--tim-accent:' + p.accent + ';'; }
          if (p.headingFont) { bodyRule += '--tim-font-heading:' + p.headingFont + ';'; }
          if (p.bodyFont) { bodyRule += '--tim-font-body:' + p.bodyFont + ';font-family:' + p.bodyFont + ';'; }
          if (bodyRule) { out += scope + '{' + bodyRule + '}\\n'; }
          if (p.link) { out += scope + ' a{color:' + p.link + ';}\\n'; }
          // Title and Heading take the heading font directly: a page whose
          // styles name a face outright (most older pages) follows too.
          if (p.headingFont) { out += scope + ' .tim-style-title,' + scope + ' .tim-style-heading{font-family:' + p.headingFont + ';}\\n'; }
          if (p.baseSize != null) { out += 'html:has(' + scope + '){font-size:' + p.baseSize + 'px;}\\n'; }
          if (p.padY != null || p.marginX != null || p.contentW != null) {
            var pad = p.padY != null ? p.padY : 48;
            var mx = p.marginX != null ? p.marginX : 32;
            var cw = p.contentW != null ? p.contentW : 1320;
            out += scope + ' .tim-canvas{padding:' + pad + 'px max(' + mx + 'px, calc(50vw - ' + (cw / 2) + 'px));}\\n';
          }
        }
        el.textContent = out;
      }
      function upsertMeta(attr, key, content) {
        var el = doc.querySelector('meta[' + attr + '="' + key + '"]');
        if (!content) { if (el) { el.remove(); } return; }
        if (!el) {
          el = doc.createElement('meta');
          el.setAttribute(attr, key);
          doc.head.appendChild(el);
        }
        el.setAttribute('content', content);
      }
      // Sharing & search metadata — what the modern web reads before
      // anyone reads the page: description, social card image, favicon.
      window.__timSetMeta = function (kind, value) {
        if (kind === 'description') {
          upsertMeta('name', 'description', value);
          upsertMeta('property', 'og:description', value);
        } else if (kind === 'ogImage') {
          upsertMeta('property', 'og:image', value);
          upsertMeta('name', 'twitter:image', value);
          upsertMeta('name', 'twitter:card', value ? 'summary_large_image' : '');
        } else if (kind === 'robots') {
          upsertMeta('name', 'robots', value);
        } else if (kind === 'ownTheme') {
          // This page keeps its own look — Done's site-wide pass for
          // colors, type and templates passes it by, both ways.
          if (value) { doc.body.setAttribute('data-tim-own-theme', ''); }
          else { doc.body.removeAttribute('data-tim-own-theme'); }
        } else if (kind === 'ownIcons') {
          // This page keeps its own icons — Done's site-icon stamping
          // passes it by.
          if (value) { doc.body.setAttribute('data-tim-own-icons', ''); }
          else { doc.body.removeAttribute('data-tim-own-icons'); }
        } else if (kind === 'touchIcon') {
          var touch = doc.querySelector('link[rel="apple-touch-icon"]');
          if (!value) { if (touch) { touch.remove(); } return; }
          if (!touch) {
            touch = doc.createElement('link');
            touch.setAttribute('rel', 'apple-touch-icon');
            doc.head.appendChild(touch);
          }
          touch.setAttribute('href', value);
        } else if (kind === 'favicon') {
          var link = doc.querySelector('link[rel="icon"]');
          if (!value) { if (link) { link.remove(); } return; }
          if (!link) {
            link = doc.createElement('link');
            link.rel = 'icon';
            doc.head.appendChild(link);
          }
          link.setAttribute('href', value);
        }
      };
      var NUMERIC_PAGE_PROPS = ['contentW', 'marginX', 'padY', 'baseSize'];
      window.__timSetPageOption = function (prop, value) {
        if (prop === 'title') {
          doc.title = value;
          upsertMeta('property', 'og:title', value);
          return;
        }
        if (prop === 'template' || prop === 'newTemplate') {
          var to = String(value || '').toLowerCase().replace(/[^a-z0-9-]/g, '');
          if (!to) { return; }
          checkpoint('page:template');
          if (prop === 'newTemplate') {
            // A new template starts as a copy of this page's — so what you
            // see doesn't change; only what follows it does.
            if (templateProps[to]) { return; }
            var from = doc.body.getAttribute('data-tim-template') || 'default';
            templateProps[to] = JSON.parse(JSON.stringify(templateProps[from] || {}));
          } else if (!templateProps[to]) {
            templateProps[to] = {};
          }
          doc.body.setAttribute('data-tim-template', to);
          writeTemplates();
          return;
        }
        checkpoint('page:' + prop);
        if (!doc.body.getAttribute('data-tim-template')) {
          doc.body.setAttribute('data-tim-template', 'default');
        }
        var name = doc.body.getAttribute('data-tim-template');
        if (!templateProps[name]) { templateProps[name] = {}; }
        if (value === '' || value === null) {
          delete templateProps[name][prop];
        } else {
          templateProps[name][prop] = NUMERIC_PAGE_PROPS.indexOf(prop) >= 0 ? parseFloat(value) : value;
        }
        writeTemplates();
      };
      // A full-bleed silent video behind everything on the page. Fixed,
      // inert to clicks, and part of the saved page like any element.
      window.__timSetPageBackgroundVideo = function (src) {
        var bgv = doc.querySelector('video.tim-page-background');
        if (!src) { if (bgv) { bgv.remove(); } return; }
        if (!bgv) {
          bgv = doc.createElement('video');
          bgv.className = 'tim-page-background';
          bgv.setAttribute('autoplay', '');
          bgv.setAttribute('muted', '');
          bgv.setAttribute('loop', '');
          bgv.setAttribute('playsinline', '');
          bgv.style.cssText = 'position:fixed;inset:0;width:100vw;height:100vh;object-fit:cover;z-index:-1;pointer-events:none;';
          doc.body.insertBefore(bgv, doc.body.firstChild);
        }
        bgv.setAttribute('src', src);
        bgv.muted = true;
        var p = bgv.play();
        if (p && p.catch) { p.catch(function () {}); }
      };

      // A theme is a head: canvas styles, named styles, templates, fonts.
      // Applying one swaps them in — the page's objects don't move.
      // The head it replaced is kept for the session, so "this site's
      // own" can come back; undo covers it too.
      window.__timApplyTheme = function (stylesHTML, overridesJSON, templatesJSON, fontsHTML, defaultTemplate) {
        checkpoint('theme');
        var old = doc.querySelector('style[data-tim-styles]');
        if (!window.__timPreviousTheme) {
          window.__timPreviousTheme = { s: old ? old.outerHTML : '', o: JSON.stringify(styleRules),
                                        p: JSON.stringify(templateProps), tn: doc.body.getAttribute('data-tim-template') || 'default' };
        }
        var holder = doc.createElement('div');
        holder.innerHTML = stylesHTML;
        var fresh = holder.firstElementChild;
        if (fresh) { if (old) { old.replaceWith(fresh); } else { doc.head.appendChild(fresh); } }
        holder.innerHTML = fontsHTML || '';
        Array.prototype.slice.call(holder.children).forEach(function (link) {
          var fam = link.getAttribute('data-tim-font');
          if (fam && !doc.querySelector('link[data-tim-font="' + fam + '"]')) {
            var anchor = doc.querySelector('style[data-tim-styles]');
            if (anchor) { doc.head.insertBefore(link, anchor); } else { doc.head.appendChild(link); }
          }
        });
        // Edits to the five built-in styles belonged to the look that's
        // leaving; the theme's own take them over. Styles the author
        // named stay. (Undo brings the edits back.)
        ['tim-style-title', 'tim-style-heading', 'tim-style-subheading', 'tim-style-body', 'tim-style-caption']
          .forEach(function (k) { delete styleRules[k]; });
        try { var o = JSON.parse(overridesJSON || '{}'); for (var k in o) { styleRules[k] = o[k]; } } catch (e1) {}
        writeOverrides();
        try { var t = JSON.parse(templatesJSON || '{}'); for (var n in t) { templateProps[n] = t[n]; } } catch (e2) {}
        // A page on "default", or on a template the theme doesn't know,
        // moves to the theme's everyday template; a page already on one
        // of the theme's own keeps it.
        var cur = doc.body.getAttribute('data-tim-template') || 'default';
        var known = {};
        try { known = JSON.parse(templatesJSON || '{}'); } catch (e3) {}
        if (defaultTemplate && (cur === 'default' || !known[cur])) {
          doc.body.setAttribute('data-tim-template', defaultTemplate);
        }
        writeTemplates();
        layout();
        notifySel(true);
      };
      window.__timRestoreTheme = function () {
        var prev = window.__timPreviousTheme;
        if (!prev) { return; }
        checkpoint('theme');
        var cur = doc.querySelector('style[data-tim-styles]');
        if (prev.s) {
          var holder = doc.createElement('div');
          holder.innerHTML = prev.s;
          if (holder.firstElementChild) { if (cur) { cur.replaceWith(holder.firstElementChild); } else { doc.head.appendChild(holder.firstElementChild); } }
        }
        try { styleRules = JSON.parse(prev.o) || {}; } catch (e1) { styleRules = {}; }
        writeOverrides();
        try { templateProps = JSON.parse(prev.p) || {}; } catch (e2) { templateProps = {}; }
        doc.body.setAttribute('data-tim-template', prev.tn || 'default');
        writeTemplates();
        window.__timPreviousTheme = null;
        layout();
        notifySel(true);
      };
      // A layout is a starting arrangement of objects. Choosing one
      // replaces the page's own objects; shared objects stay put; the
      // phone goes back to stacking in reading order. One undo step.
      window.__timReplaceObjects = function (html) {
        var canvas = canvasEl();
        if (!canvas) { return; }
        checkpoint('layout');
        stopTextEditing();
        sel = null;
        hide();
        Array.prototype.slice.call(canvas.children).forEach(function (child) {
          if (!(child.getAttribute && child.getAttribute('data-tim-component'))) { child.remove(); }
        });
        var holder = doc.createElement('div');
        holder.innerHTML = html;
        while (holder.firstElementChild) { canvas.appendChild(holder.firstElementChild); }
        mobileLayout = {};
        mobileLayoutMode = 'stack';
        var oldMobile = doc.querySelector('style[data-tim-mobile-layout]');
        if (oldMobile) { oldMobile.remove(); }
        syncMobileModeClass();
        resort(canvas);
        layout();
        notifySel();
      };

      window.__timPageInfo = function () {
        var name = doc.body.getAttribute('data-tim-template') || 'default';
        var p = templateProps[name] || {};
        var cs = getComputedStyle(doc.body);
        return JSON.stringify({
          template: name,
          motion: doc.body.getAttribute('data-tim-motion') || '',
          title: doc.title || '',
          // A gradient lives in background-IMAGE; backgroundColor reads
          // transparent for it, which used to make Page Options open on
          // the Color tab for a page that plainly has a gradient.
          bg: p.bg || (String(cs.backgroundImage || '').indexOf('gradient') >= 0
                        ? cs.backgroundImage : cs.backgroundColor),
          bgVideo: (function () {
            var v = doc.querySelector('video.tim-page-background');
            return v ? (v.getAttribute('src') || '') : '';
          })(),
          fg: p.fg || cs.color,
          link: p.link || '',
          accent: p.accent || '',
          headingFont: p.headingFont || '',
          bodyFont: p.bodyFont || '',
          templates: Object.keys(templateProps),
          ownTheme: doc.body.hasAttribute('data-tim-own-theme') ? 1 : 0,
          theme: (function () { var st = doc.querySelector('style[data-tim-styles]'); return st ? (st.getAttribute('data-tim-theme') || '') : ''; })(),
          canRestoreTheme: window.__timPreviousTheme ? 1 : 0,
          contentW: p.contentW != null ? p.contentW : 1320,
          marginX: p.marginX != null ? p.marginX : 32,
          padY: p.padY != null ? p.padY : 48,
          baseSize: p.baseSize != null ? p.baseSize : (parseFloat(getComputedStyle(doc.documentElement).fontSize) || 16),
          description: (function () {
            var m = doc.querySelector('meta[name="description"]');
            return m ? (m.getAttribute('content') || '') : '';
          })(),
          ogImage: (function () {
            var m = doc.querySelector('meta[property="og:image"]');
            return m ? (m.getAttribute('content') || '') : '';
          })(),
          favicon: (function () {
            var l = doc.querySelector('link[rel="icon"]');
            return l ? (l.getAttribute('href') || '') : '';
          })(),
          touchIcon: (function () {
            var l = doc.querySelector('link[rel="apple-touch-icon"]');
            return l ? (l.getAttribute('href') || '') : '';
          })(),
          robotsMeta: (function () {
            var m = doc.querySelector('meta[name="robots"]');
            return m ? (m.getAttribute('content') || '') : '';
          })(),
          ownIcons: doc.body.hasAttribute('data-tim-own-icons') ? 1 : 0
        });
      };

      window.__timEnsureFont = function (family, url) {
        if (!doc.querySelector('link[data-tim-font="' + family + '"]')) {
          var link = doc.createElement('link');
          link.rel = 'stylesheet';
          link.href = url;
          link.setAttribute('data-tim-font', family);
          doc.head.appendChild(link);
        }
      };

      window.__timDeselect = function () {
        stopTextEditing();
        sel = null;
        hide();
        notifySel();
      };
      window.__timSelectAncestor = function (index) {
        var el = selPath[index];
        if (!el || !doc.contains(el) || el === doc.body) { return; }
        stopTextEditing();
        sel = el;
        layout();
        notifySel(true);
      };

      window.__timWrapSelTemplate = function (name) {
        if (!sel || !canvasFor(sel)) { return; }
        if (sel.closest('[data-tim-component]')) { return; }
        checkpoint('template');
        var wrap = doc.createElement('div');
        wrap.setAttribute('data-tim-component', name);
        wrap.style.display = 'contents';
        sel.parentNode.insertBefore(wrap, sel);
        wrap.appendChild(sel);
        notifySel(true);
      };
      window.__timUnwrapSelTemplate = function () {
        if (!sel) { return; }
        var wrap = sel.closest ? sel.closest('[data-tim-component]') : null;
        if (!wrap || !wrap.parentNode) { return; }
        while (wrap.firstChild) { wrap.parentNode.insertBefore(wrap.firstChild, wrap); }
        wrap.remove();
        notifySel(true);
      };

      // Video behavior, applied as one coherent state: the saved page gets
      // the attributes, and the live element previews the result.
      window.__timSetVideo = function (json) {
        if (!sel || sel.tagName !== 'VIDEO') { return; }
        checkpoint('video');
        var opts = {};
        try { opts = JSON.parse(json) || {}; } catch (e) {}
        function setBool(name, on) {
          if (on) { sel.setAttribute(name, ''); } else { sel.removeAttribute(name); }
        }
        setBool('autoplay', !!opts.autoplay);
        setBool('loop', !!opts.loop);
        setBool('muted', !!opts.muted);
        setBool('controls', !!opts.controls);
        // Autoplay must play inline on phones or iOS goes fullscreen.
        setBool('playsinline', !!opts.autoplay || sel.hasAttribute('playsinline'));
        sel.muted = !!opts.muted;
        sel.loop = !!opts.loop;
        if (opts.autoplay) {
          var p = sel.play();
          if (p && p.catch) { p.catch(function () {}); }
        } else {
          sel.pause();
          sel.currentTime = 0;
        }
        notifySel();
      };

      // Bounce swaps the video's file for its baked forward+reverse
      // sibling, remembering the plain one so it can swap back.
      window.__timBounceVideoSrc = function (src) {
        if (!sel || sel.tagName !== 'VIDEO') { return; }
        checkpoint('video');
        if (!sel.hasAttribute('data-tim-plain-src')) {
          sel.setAttribute('data-tim-plain-src', sel.getAttribute('src') || '');
        }
        sel.setAttribute('src', src);
        sel.load();
        if (sel.hasAttribute('autoplay')) {
          var p = sel.play();
          if (p && p.catch) { p.catch(function () {}); }
        }
        notifySel(true);
      };
      window.__timRestorePlainVideo = function () {
        if (!sel || sel.tagName !== 'VIDEO') { return; }
        var plain = sel.getAttribute('data-tim-plain-src');
        if (!plain) { return; }
        checkpoint('video');
        sel.setAttribute('src', plain);
        sel.removeAttribute('data-tim-plain-src');
        sel.load();
        if (sel.hasAttribute('autoplay')) {
          var p2 = sel.play();
          if (p2 && p2.catch) { p2.catch(function () {}); }
        }
        notifySel(true);
      };

      // Desktop-only objects: hidden on phones by the generated mobile
      // stylesheet; while editing at phone width they show dimmed so
      // they stay reachable.
      window.__timSetMobileHidden = function (hidden) {
        if (!sel) { return; }
        checkpoint('mobile');
        groupAll().forEach(function (member) {
          if (hidden) { member.setAttribute('data-tim-mobile-hidden', ''); }
          else { member.removeAttribute('data-tim-mobile-hidden'); }
        });
        if (mobileActive()) { writeMobileLayout(); }
        layout();
        notifySel();
      };

      window.__timSelHTML = function () { return sel ? sel.outerHTML : ''; };
      window.__timReplaceSel = function (html) {
        if (!sel) { return; }
        var tmp = doc.createElement('div');
        tmp.innerHTML = html;
        var el = tmp.firstElementChild;
        if (!el) { return; }
        sel.replaceWith(el);
        sel = (el.classList && el.classList.contains('tim-object'))
          ? el : (el.querySelector('.tim-object') || el);
        layout();
      };

      var anchorSelector = 'h1,h2,h3,h4,h5,h6,.tim-style-title,.tim-style-heading,.tim-style-subheading';
      window.__timAnchorList = function () {
        var els = doc.querySelectorAll(anchorSelector);
        var out = [];
        for (var i = 0; i < els.length; i++) {
          var t = (els[i].textContent || '').trim();
          out.push(t.slice(0, 80) || '(untitled)');
        }
        return JSON.stringify(out);
      };
      window.__timAnchorHref = function (index) {
        var els = doc.querySelectorAll(anchorSelector);
        var el = els[index];
        if (!el) { return ''; }
        if (!el.id) {
          var slug = (el.textContent || 'section').trim().toLowerCase()
            .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'section';
          var id = slug, n = 2;
          while (doc.getElementById(id)) { id = slug + '-' + n; n++; }
          el.id = id;
        }
        return '#' + el.id;
      };

      window.__timApplyStyle = function (cls) {
        checkpoint('applystyle');
        var target = sel;
        if (!target || (editingEl && editingEl === target)) {
          var s = window.getSelection();
          var n = s && s.anchorNode;
          if (n) {
            target = n.nodeType === 1 ? n : n.parentElement;
            while (target && target !== doc.body && !isObject(target) && getComputedStyle(target).display === 'inline') {
              target = target.parentElement;
            }
          }
        }
        if (!target || target === doc.body) { return; }
        var applyTargets = (target === sel) ? groupAll() : [target];
        applyTargets.forEach(function (member) {
          String(member.className || '').split(/\\s+/).forEach(function (c) {
            if (c.indexOf('tim-style-') === 0) { member.classList.remove(c); }
          });
          if (cls) { member.classList.add(cls); }
          TYPO_PROPS.forEach(function (p) { member.style[p] = ''; });
        });
        layout();
        notifySel(true);
      };

      window.__timCanvasLayer = true;
      window.__timCanvasOn = function () {
        active = true;
        updateWraps();
        overlay.style.display = 'block';
        doc.documentElement.classList.add('tim-editing');
        doc.documentElement.classList.remove('tim-reveal', 'tim-fade');
        doc.documentElement.classList.add('tim-ready');
        pinPageColumns();
        // Editing at phone width edits the mobile layout.
        if (collapsed()) { window.__timEnsureMobileLayout(); }
      };
      window.__timCanvasOff = function () {
        active = false;
        cropping = null;
        stopTextEditing();
        sel = null; drag = null;
        hide();
        hoverBox.style.display = 'none';
        overlay.style.display = 'none';
        notifySel();
        doc.documentElement.classList.remove('tim-editing');
        pinPageColumns();
      };
    })();
    """
}

extension Tab: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "timText" {
            if let json = message.body as? String, !json.isEmpty, let data = json.data(using: .utf8),
               let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                textSelection = info
            } else if textSelection != nil {
                textSelection = nil
            }
            return
        }
        guard message.name == "timSel" else { return }
        if let json = message.body as? String, !json.isEmpty,
           let data = json.data(using: .utf8),
           let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            selectionInfo = info
        } else {
            selectionInfo = nil
        }
    }
}

extension Tab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        note("start")
        // Navigating away always leaves edit mode.
        if isEditing { isEditing = false }
        textSelection = nil
        isTimPage = false
        lastHTTPStatus = 200
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        note("commit")
        deliberateNavigation = false
        #if os(iOS)
        if addressEditing { webView.evaluateJavaScript("window.__timAddressEditing = true;", completionHandler: nil) }
        #endif
    }

    /// WebKit ends a tab's web process whenever it likes — memory pressure,
    /// too many tabs, a long time in the background — and leaves the view
    /// blank white, with no error and nothing in our log. Safari reloads;
    /// so do we. An edit in progress is already in the draft, which the
    /// address bar offers back once the page returns.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        note("web-process-terminated")
        if isEditing { isEditing = false }
        deliberateNavigation = true
        // A full load, not reload(): with the process gone, reload can be
        // a silent no-op — which is how a tab stayed white through Reload
        // and came back only when the address was entered again.
        if let url = webView.url ?? URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
    }

    /// A load that never started or gave up partway: say so in the page,
    /// with a way to try again — a white pane says nothing.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }
    private func showLoadFailure(_ error: Error) {
        let e = error as NSError
        note("fail \(e.domain) \(e.code)")
        // Cancellations are ours (a newer navigation, an edit-mode guard,
        // a download) — not failures.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        let failed = (e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? urlString
        let message = e.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let shown = failed.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Can’t Open the Page</title>
        <style>:root{color-scheme:light dark}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,ui-sans-serif,system-ui,sans-serif;background:#fbfbfd;color:#1d1d1f}
        @media (prefers-color-scheme:dark){body{background:#161617;color:#f5f5f7}}main{max-width:30rem;padding:2rem;text-align:center}
        h1{font-size:1.4rem;font-weight:600;margin:0 0 .5rem}p{color:#6e6e73;line-height:1.5;margin:0 0 1.4rem;overflow-wrap:anywhere}
        a{display:inline-block;background:#ffd60a;color:#111;font-weight:600;padding:.6rem 1.15rem;border-radius:999px;text-decoration:none}</style></head>
        <body><main><h1>Tim can’t open the page.</h1><p>\(message)<br><small>\(shown)</small></p>
        <a href="tim:retry">Try Again</a></main></body></html>
        """
        pendingRetryURL = failed
        webView.loadHTMLString(html, baseURL: URL(string: failed))
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        note("finish")
        #if os(iOS)
        if addressEditing { webView.evaluateJavaScript("window.__timAddressEditing = true;", completionHandler: nil) }
        #endif
        webView.evaluateJavaScript(
            "!!(document.querySelector('[data-tim-canvas]') || document.querySelector('meta[name=\"generator\"][content^=\"Tim\"]'))"
        ) { [weak self] result, _ in
            self?.isTimPage = (result as? Bool) ?? false
        }
        applyPreviewViewport()
        // A draft is offered, never imposed: the page loads as published,
        // and the draft shows in the address bar and History. Only an
        // explicit resumeDraft() brings it back into edit mode.
        if restoringDraft {
            restoringDraft = false
            setEditing(true)
        } else {
            suppressDraftResume = false
        }
        refreshDraftState()
    }

    public func refreshReviewCounts() {
        webView.evaluateJavaScript("window.__timReviewCounts ? window.__timReviewCounts() : ''") { [weak self] result, _ in
            guard let json = result as? String, !json.isEmpty,
                  let data = json.data(using: .utf8),
                  let counts = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
            else { return }
            self?.reviewDesktop = counts["desktop"] ?? 0
            self?.reviewMobile = counts["mobile"] ?? 0
        }
    }

    /// Stashes the current edit session (called before navigating away,
    /// and every few seconds while editing).
    public func refreshDraftState() {
        let value = webView.url.map { !$0.isFileURL && DraftStore.has($0.absoluteString) } ?? false
        if value != hasDraft { hasDraft = value }
    }

    /// Continue the draft: its DOM replaces the page and editing begins.
    public func resumeDraft() {
        guard let url = webView.url, let draft = DraftStore.html(for: url.absoluteString) else { return }
        restoringDraft = true
        webView.loadHTMLString(draft, baseURL: url)
    }

    /// Throw the draft away; the published page stays as it is.
    public func discardDraft() {
        guard let url = webView.url else { return }
        DraftStore.clear(for: url.absoluteString)
        hasDraft = false
    }

    public var draftDate: Date? {
        webView.url.flatMap { DraftStore.date(for: $0.absoluteString) }
    }

    public func stashDraft(_ completion: (() -> Void)? = nil) {
        guard isEditing, let url = webView.url, !url.isFileURL else { completion?(); return }
        currentHTML { html in
            if let html { DraftStore.save(html, for: url.absoluteString); self.hasDraft = true }
            completion?()
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // The home page asks the app for things a web page cannot do —
        // make a local page, connect a site — through tim: links.
        if let url = navigationAction.request.url, url.scheme == "tim" {
            decisionHandler(.cancel)
            let action = String(url.absoluteString.dropFirst("tim:".count))
            NotificationCenter.default.post(name: .timHomeAction, object: nil, userInfo: ["action": action])
            return
        }
        if isEditing, navigationAction.targetFrame?.isMainFrame != false {
            // A stray click on a link (a nav object, say) stays inert while
            // editing — links go live again the moment editing ends.
            if navigationAction.navigationType == .linkActivated
                || navigationAction.navigationType == .formSubmitted {
                note("policy-cancel link-while-editing")
                decisionHandler(.cancel)
                return
            }
            // A synthetic or script-driven follow of a link arrives as
            // .other, which used to read as a deliberate move and threw
            // the editor away. If Tim didn't ask, nothing happens.
            if !deliberateNavigation {
                note("policy-cancel not-deliberate")
                decisionHandler(.cancel)
                return
            }
            deliberateNavigation = false
            // A deliberate navigation (URL bar, sidebar, back/forward):
            // stash the session as a draft first, then let it through.
            // Opening the page again resumes editing right where it was.
            if let target = navigationAction.request.url, !target.isFileURL {
                decisionHandler(.cancel)
                let request = navigationAction.request
                stashDraft { [weak self] in
                    guard let self else { return }
                    self.setEditing(false)
                    self.webView.load(request)
                }
                return
            }
        }
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.cachePolicy == .useProtocolCachePolicy,
           cacheBypass?(url) == true {
            decisionHandler(.cancel)
            var request = navigationAction.request
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(request)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            let status = http.statusCode
            DispatchQueue.main.async { self.lastHTTPStatus = status }
        }
        decisionHandler(.allow)
    }
}

extension Tab: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target=_blank links open in the same tab for now — unless we're
        // editing, where no click may steal the page.
        if navigationAction.targetFrame == nil, !isEditing {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// All open tabs and the selection.
public final class BrowserStore: ObservableObject {
    @Published public var tabs: [Tab] = []
    @Published public var selectedTabID: UUID? {
        didSet { selectedTab?.loadIfPending() }
    }

    public var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    private static let sessionKey = "tim.session.tabs"
    private static let sessionSelectedKey = "tim.session.selected"
    private static let sessionPinnedKey = "tim.session.pinned"

    public init() {
        // Pick up where you left off: reopen last session's tabs.
        let saved = UserDefaults.standard.array(forKey: Self.sessionKey) as? [String] ?? []
        let pinned = UserDefaults.standard.array(forKey: Self.sessionPinnedKey) as? [Bool] ?? []
        if saved.isEmpty {
            newTab()
        } else {
            let selected = max(0, min(UserDefaults.standard.integer(forKey: Self.sessionSelectedKey), saved.count - 1))
            for (index, url) in saved.enumerated() {
                let tab = Tab()
                tab.isPinned = index < pinned.count && pinned[index]
                if url.isEmpty { tab.loadStartPage() }
                else if index == selected { tab.navigate(to: url) }
                else { tab.deferLoad(of: url) }
                tabs.append(tab)
            }
            selectedTabID = tabs[selected].id
        }
        // URLs change constantly while browsing; a light heartbeat keeps
        // the saved session current without wiring every navigation.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.persistSession()
        }
    }

    public func persistSession() {
        UserDefaults.standard.set(tabs.map { $0.urlString }, forKey: Self.sessionKey)
        UserDefaults.standard.set(tabs.map { $0.isPinned }, forKey: Self.sessionPinnedKey)
        let index = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        UserDefaults.standard.set(index, forKey: Self.sessionSelectedKey)
    }

    /// Reorder a tab to a new position (drag-to-reorder in the tab list).
    public func move(_ tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let to = max(0, min(index, tabs.count - 1))
        guard to != from else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        persistSession()
    }

    /// Pinning floats the tab up to the pinned block; unpinning drops it
    /// to the top of the regular tabs — the list order always keeps
    /// pinned tabs contiguous at the top.
    public func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.isPinned = pinned
        let moved = tabs.remove(at: from)
        let boundary = tabs.firstIndex(where: { !$0.isPinned }) ?? tabs.count
        tabs.insert(moved, at: boundary)
        persistSession()
    }

    public func newTab() {
        let tab = Tab()
        tab.loadStartPage()
        tabs.append(tab)
        selectedTabID = tab.id
        persistSession()
    }

    /// What was closed, most recent last — so ⇧⌘T can bring it back.
    @Published public var recentlyClosed: [String] = []

    /// ⌘1…⌘9: the ninth selects the LAST tab, as Safari does.
    public func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1)
        selectedTabID = tabs[index].id
    }

    public func selectTab(offset: Int) {
        guard !tabs.isEmpty, let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = ((current + offset) % tabs.count + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    public func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let address = tab.urlString
        if !address.isEmpty {
            recentlyClosed.append(address)
            if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        if tabs.isEmpty { newTab() }
        persistSession()
    }
}


/// A web view that won't steal the keyboard from the address bar. Pages
/// call focus() as they load — news sites keep doing it for seconds while
/// trackers settle — and a plain WKWebView becomes first responder every
/// time, swallowing the URL you're typing. Safari's rule: while the
/// address field is editing, only a real click into the page moves focus.
public final class TimWebView: WKWebView {
    public var addressEditing: () -> Bool = { false }
    /// What landed on the page. Not everything arrives as a path: Photos,
    /// Mail, Messages and Safari hand over a *promise* of files, or raw
    /// image bytes with nothing behind them on disk.
    public struct DropPayload {
        public var files: [URL] = []
        public var urls: [URL] = []
        public var text: String?
        /// The pasteboard carries image bytes with no file behind them.
        public var imageData = false
        /// Files the source will only write once the drop is accepted.
        public var promised = 0
        /// What those promised files will be, when the source says so.
        public var promisedExtension = ""
        public var asLink = false
        public var isEmpty: Bool {
            files.isEmpty && urls.isEmpty && (text ?? "").isEmpty && !imageData && promised == 0
        }
    }
    /// Drops while editing: (payload, point in page CSS pixels) → true when
    /// handled. Hover reports the point and the Option state; nil on exit.
    /// Promised files arrive after the drop, so the closure can be called
    /// once the source has written them.
    public var drop: ((_ payload: DropPayload, _ point: CGPoint) -> Bool)? {
        didSet {
            #if os(macOS)
            if drop != nil { acceptRichDrops() }
            #endif
        }
    }
    public var dropHover: ((_ point: CGPoint?, _ payload: DropPayload) -> Void)?

    #if os(macOS)
    /// WKWebView registers the drag types a web *page* needs; these are the
    /// ones an editor needs on top. Added, never replaced, so ordinary
    /// dragging into a page keeps working exactly as before.
    private func acceptRichDrops() {
        var types = registeredDraggedTypes
        var extra = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        extra += [.fileURL, .tiff, .png, .string, .URL]
        for type in extra where !types.contains(type) { types.append(type) }
        registerForDraggedTypes(types)
    }

    private func payload(_ sender: NSDraggingInfo) -> DropPayload {
        var p = DropPayload()
        let pb = sender.draggingPasteboard
        let all = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        p.files = all.filter(\.isFileURL)
        p.urls = all.filter { !$0.isFileURL && $0.scheme != nil }
        if p.files.isEmpty {
            // Detection only. Promises are received, and bytes written, once
            // on the drop itself — never on every hover.
            let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]
            p.promised = receivers?.count ?? 0
            if let type = receivers?.first?.fileTypes.first, let ut = UTType(type) {
                p.promisedExtension = ut.preferredFilenameExtension ?? ""
            }
            if p.promised == 0, pb.availableType(from: [.png, .tiff]) != nil { p.imageData = true }
        }
        if p.isEmpty, let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme, ["http", "https", "mailto"].contains(scheme) { p.urls = [u] } else { p.text = s }
        }
        p.asLink = NSEvent.modifierFlags.contains(.option)
        return p
    }

    /// Image bytes with no file behind them, written once so the rest of
    /// Tim can treat the drop like any other file.
    private func writeDroppedImage(from pb: NSPasteboard) -> URL? {
        var png = pb.data(forType: .png)
        if png == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-\(UUID().uuidString.prefix(6).lowercased()).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }
    private func pagePoint(_ sender: NSDraggingInfo) -> CGPoint {
        let p = convert(sender.draggingLocation, from: nil)
        let m = max(0.05, magnification)
        return CGPoint(x: p.x / m, y: p.y / m)
    }
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if drop != nil { let p = payload(sender); if !p.isEmpty { dropHover?(pagePoint(sender), p); return .copy } }
        return super.draggingEntered(sender)
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if drop != nil { let p = payload(sender); if !p.isEmpty { dropHover?(pagePoint(sender), p); return .copy } }
        return super.draggingUpdated(sender)
    }
    public override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHover?(nil, DropPayload())
        super.draggingExited(sender)
    }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHover?(nil, DropPayload())
        guard let drop else { return super.performDragOperation(sender) }
        var p = payload(sender)
        guard !p.isEmpty else { return super.performDragOperation(sender) }
        let point = pagePoint(sender)
        let pb = sender.draggingPasteboard

        // A promise is only kept once the drop is accepted: say yes now,
        // and place the files when the source has finished writing them.
        if p.files.isEmpty, p.promised > 0,
           let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tim-drop-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let queue = OperationQueue()
            let group = DispatchGroup()
            let lock = NSLock()
            var landed: [URL] = []
            for receiver in receivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                    if error == nil { lock.lock(); landed.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard !landed.isEmpty else { return }
                var settled = p
                settled.files = landed.sorted { $0.lastPathComponent < $1.lastPathComponent }
                _ = drop(settled, point)
            }
            return true
        }

        if p.files.isEmpty, p.imageData, let written = writeDroppedImage(from: pb) {
            p.files = [written]
        }
        return drop(p, point) ? true : super.performDragOperation(sender)
    }

    public override func becomeFirstResponder() -> Bool {
        if addressEditing() {
            let type = NSApp.currentEvent?.type
            if type != .leftMouseDown && type != .rightMouseDown && type != .otherMouseDown { return false }
        }
        return super.becomeFirstResponder()
    }
    #endif
}
