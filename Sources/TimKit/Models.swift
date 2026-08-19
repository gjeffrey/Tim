import Foundation
import WebKit

/// One browser tab. Owns its WKWebView and mirrors its state for SwiftUI.
/// WKWebView is the same engine on macOS, iOS, and iPadOS, so Tab is
/// fully cross-platform.
public final class Tab: NSObject, ObservableObject, Identifiable {
    public let id = UUID()

    @Published public var title: String = "New Tab"
    @Published public var urlString: String = ""
    @Published public var isEditing: Bool = false
    @Published public var isArranging: Bool = false
    @Published public var isLoading: Bool = false
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false

    public let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    public override init() {
        let configuration = WKWebViewConfiguration()
        // Render exactly like Safari. The engine already is Safari's WebKit,
        // but WKWebView's default user agent stops at "(KHTML, like Gecko)" —
        // without the trailing "Version/… Safari/…" token, sites (apple.com
        // included) don't recognize Safari and serve different markup.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        #if os(macOS)
        webView.allowsMagnification = true
        #endif
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self

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
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.isLoading = view.isLoading }
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
        webView.loadHTMLString(StartPage.html, baseURL: nil)
    }

    /// Interprets the address bar text as a URL, a bare domain, or a search.
    public func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

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

    public func setEditing(_ editing: Bool) {
        isEditing = editing
        if editing {
            // Track text mutations so edits can be mapped back to source
            // files (the Astro round trip) instead of publishing raw DOM.
            webView.evaluateJavaScript(Self.editTrackerJS, completionHandler: nil)
        } else if isArranging {
            setArranging(false)
        }
        webView.evaluateJavaScript("document.designMode = '\(editing && !isArranging ? "on" : "off")';", completionHandler: nil)
    }

    /// Arrange mode: Keynote's object-selection half. Text caret off,
    /// selection handles and snap guides on.
    public func setArranging(_ arranging: Bool) {
        isArranging = arranging
        if arranging {
            webView.evaluateJavaScript("document.designMode = 'off';", completionHandler: nil)
            webView.evaluateJavaScript(Self.arrangeJS, completionHandler: nil)
            webView.evaluateJavaScript("window.__timArrangeOn && window.__timArrangeOn();", completionHandler: nil)
        } else {
            let restoreDesignMode = isEditing ? "document.designMode = 'on';" : ""
            webView.evaluateJavaScript(
                "window.__timArrangeOff && window.__timArrangeOff(); \(restoreDesignMode)",
                completionHandler: nil
            )
        }
    }

    /// Selection handles, live size badge, and snap-to guides: element
    /// widths snap to sibling widths and to container fractions (¼ ⅓ ½ ⅔ ¾
    /// full), with a guide line when a snap engages.
    private static let arrangeJS = """
    (function () {
      if (window.__timArrange) { return; }
      var doc = document;
      var overlay = doc.createElement('div');
      overlay.style.cssText = 'position:absolute;left:0;top:0;z-index:2147483000;pointer-events:none;';
      overlay.id = '__tim-overlay';
      var box = doc.createElement('div');
      box.style.cssText = 'position:absolute;border:1.5px solid #0a84ff;pointer-events:none;display:none;box-sizing:border-box;';
      var badge = doc.createElement('div');
      badge.style.cssText = 'position:absolute;background:#0a84ff;color:#fff;font:11px -apple-system,sans-serif;padding:2px 6px;border-radius:4px;display:none;white-space:nowrap;';
      var guide = doc.createElement('div');
      guide.style.cssText = 'position:absolute;width:1px;background:#ff9f0a;display:none;';
      overlay.appendChild(box); overlay.appendChild(badge); overlay.appendChild(guide);
      var handles = {};
      ['e','s','se'].forEach(function (k) {
        var h = doc.createElement('div');
        h.style.cssText = 'position:absolute;width:9px;height:9px;background:#fff;border:1.5px solid #0a84ff;border-radius:50%;pointer-events:auto;display:none;';
        h.style.cursor = k === 'e' ? 'ew-resize' : (k === 's' ? 'ns-resize' : 'nwse-resize');
        h.setAttribute('data-tim-handle', k);
        overlay.appendChild(h); handles[k] = h;
      });
      doc.body.appendChild(overlay);

      var sel = null, drag = null, active = false;

      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return { x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height };
      }
      function hide() {
        box.style.display = badge.style.display = guide.style.display = 'none';
        for (var k in handles) { handles[k].style.display = 'none'; }
      }
      function layout() {
        if (!sel || !doc.contains(sel)) { hide(); return; }
        var r = rectOf(sel);
        box.style.display = 'block';
        box.style.left = r.x + 'px'; box.style.top = r.y + 'px';
        box.style.width = r.w + 'px'; box.style.height = r.h + 'px';
        badge.style.display = 'block';
        badge.style.left = r.x + 'px'; badge.style.top = Math.max(2, r.y - 24) + 'px';
        if (!drag) {
          badge.textContent = sel.tagName.toLowerCase() + ' · ' + Math.round(r.w) + '×' + Math.round(r.h);
        }
        handles.e.style.display = handles.s.style.display = handles.se.style.display = 'block';
        handles.e.style.left = (r.x + r.w - 5) + 'px'; handles.e.style.top = (r.y + r.h / 2 - 5) + 'px';
        handles.s.style.left = (r.x + r.w / 2 - 5) + 'px'; handles.s.style.top = (r.y + r.h - 5) + 'px';
        handles.se.style.left = (r.x + r.w - 5) + 'px'; handles.se.style.top = (r.y + r.h - 5) + 'px';
      }

      function snapTargets() {
        var targets = [], p = sel && sel.parentElement;
        if (!p) { return targets; }
        var cs = getComputedStyle(p);
        var inner = p.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
        [[0.25,'25%'],[1/3,'33.33%'],[0.5,'50%'],[2/3,'66.67%'],[0.75,'75%'],[1,'100%']].forEach(function (f) {
          targets.push({ w: inner * f[0], pct: f[1] });
        });
        Array.prototype.forEach.call(p.children, function (c) {
          if (c !== sel && c.id !== '__tim-overlay') { targets.push({ w: c.getBoundingClientRect().width }); }
        });
        return targets;
      }

      function onDown(e) {
        var k = e.target && e.target.getAttribute ? e.target.getAttribute('data-tim-handle') : null;
        if (k && sel) {
          var r = rectOf(sel);
          drag = { k: k, sx: e.pageX, sy: e.pageY, w: r.w, h: r.h, targets: snapTargets() };
          e.preventDefault(); e.stopPropagation();
        }
      }
      function onMove(e) {
        if (!drag || !sel) { return; }
        e.preventDefault();
        var w = drag.w + (e.pageX - drag.sx);
        var h = drag.h + (e.pageY - drag.sy);
        var snapped = null;
        guide.style.display = 'none';
        if (drag.k === 'e' || drag.k === 'se') {
          drag.targets.forEach(function (t) {
            if (Math.abs(w - t.w) < 7) { w = t.w; snapped = t; }
          });
          sel.style.width = snapped && snapped.pct ? snapped.pct : Math.max(24, Math.round(w)) + 'px';
          if (snapped) {
            var gr = rectOf(sel);
            guide.style.display = 'block';
            guide.style.left = (gr.x + gr.w) + 'px';
            guide.style.top = (gr.y - 20) + 'px';
            guide.style.height = (gr.h + 40) + 'px';
          }
        }
        if (drag.k === 's' || drag.k === 'se') {
          sel.style.height = Math.max(16, Math.round(h)) + 'px';
        }
        var r2 = rectOf(sel);
        badge.textContent = Math.round(r2.w) + '×' + Math.round(r2.h) + (snapped && snapped.pct ? ' · ' + snapped.pct : '');
        layout();
      }
      function onUp() {
        if (drag) { drag = null; guide.style.display = 'none'; layout(); }
      }
      function onClick(e) {
        if (!active || drag) { return; }
        if (e.target && e.target.getAttribute && e.target.getAttribute('data-tim-handle')) { return; }
        e.preventDefault(); e.stopPropagation();
        var el = e.target;
        while (el && el !== doc.body) {
          if (el.tagName === 'IMG' || getComputedStyle(el).display !== 'inline') { break; }
          el = el.parentElement;
        }
        sel = (!el || el === doc.body) ? null : el;
        drag = null;
        if (sel) { layout(); } else { hide(); }
      }
      function onKey(e) {
        if (e.key === 'Escape') { sel = null; hide(); }
      }

      doc.addEventListener('click', onClick, true);
      doc.addEventListener('mousedown', onDown, true);
      doc.addEventListener('mousemove', onMove, true);
      doc.addEventListener('mouseup', onUp, true);
      doc.addEventListener('keydown', onKey, true);
      window.addEventListener('scroll', layout, true);
      window.addEventListener('resize', layout);

      window.__timArrange = true;
      window.__timArrangeOn = function () { active = true; overlay.style.display = 'block'; };
      window.__timArrangeOff = function () { active = false; sel = null; drag = null; hide(); overlay.style.display = 'none'; };
    })();
    """

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
        let js = "(document.doctype ? '<!DOCTYPE html>\\n' : '') + document.documentElement.outerHTML"
        webView.evaluateJavaScript(js) { result, _ in
            completion(result as? String)
        }
    }

    /// Records the first-seen old value and current value of every text
    /// node changed during this edit session.
    private static let editTrackerJS = """
    (function () {
      if (window.__timTracker) { return; }
      var edits = new Map();
      var observer = new MutationObserver(function (list) {
        for (var i = 0; i < list.length; i++) {
          var m = list[i];
          if (m.type !== 'characterData') { continue; }
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
    })();
    """

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
}

extension Tab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Navigating away always leaves edit mode.
        if isEditing { isEditing = false }
        if isArranging { isArranging = false }
    }
}

extension Tab: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target=_blank links open in the same tab for now.
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// All open tabs and the selection.
public final class BrowserStore: ObservableObject {
    @Published public var tabs: [Tab] = []
    @Published public var selectedTabID: UUID?

    public var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    public init() {
        newTab()
    }

    public func newTab() {
        let tab = Tab()
        tab.loadStartPage()
        tabs.append(tab)
        selectedTabID = tab.id
    }

    public func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        if tabs.isEmpty { newTab() }
    }
}
