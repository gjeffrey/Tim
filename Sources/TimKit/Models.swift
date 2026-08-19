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
    @Published public var isLoading: Bool = false
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var isMobilePreview: Bool = false

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

    /// One edit mode: the canvas. Objects select, move, and resize on the
    /// grid; any text — box or flowing paragraph — edits on double-click.
    public func setEditing(_ editing: Bool) {
        isEditing = editing
        if editing {
            webView.evaluateJavaScript(Self.editTrackerJS, completionHandler: nil)
            webView.evaluateJavaScript(Self.canvasJS, completionHandler: nil)
            webView.evaluateJavaScript("window.__timCanvasOn && window.__timCanvasOn();", completionHandler: nil)
        } else {
            webView.evaluateJavaScript("window.__timCanvasOff && window.__timCanvasOff();", completionHandler: nil)
        }
    }

    /// Mobile preview: iPhone-width viewport + iPhone Safari user agent,
    /// so media queries and UA-sniffing sites both behave as on the phone.
    public func setMobilePreview(_ mobile: Bool) {
        isMobilePreview = mobile
        webView.customUserAgent = mobile
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
            : nil
        webView.reload()
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
          var overlay = clone.querySelector('#__tim-overlay');
          if (overlay) { overlay.remove(); }
          var editables = clone.querySelectorAll('[contenteditable]');
          for (var i = 0; i < editables.length; i++) { editables[i].removeAttribute('contenteditable'); }
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
    /// creating the canvas if the page doesn't have one yet.
    public func insertObject(html: String) {
        webView.evaluateJavaScript("window.__timInsert && window.__timInsert(\(Self.jsLiteral(html)));", completionHandler: nil)
    }

    /// Applies a global text style class (tim-style-*) to the selected
    /// object or the paragraph the caret is in.
    public func applyTextStyle(_ styleClass: String) {
        webView.evaluateJavaScript("window.__timApplyStyle && window.__timApplyStyle(\(Self.jsLiteral(styleClass)));", completionHandler: nil)
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
      window.__timCanvasHTML = function () {
        var canvas = document.querySelector('[data-tim-canvas]');
        if (!canvas) { return ''; }
        var clone = canvas.cloneNode(true);
        var editables = clone.querySelectorAll('[contenteditable]');
        for (var j = 0; j < editables.length; j++) { editables[j].removeAttribute('contenteditable'); }
        return clone.outerHTML;
      };
    })();
    """

    /// The canvas layer. Web-native Keynote: a 12-column grid, not a fixed
    /// slide. Objects snap to columns when moved and resized; dragging
    /// vertically reorders them (DOM order = reading order = mobile order);
    /// text boxes grow downward; the mobile breakpoint collapses the grid
    /// to a single column. Responsive by construction — never by tweaks.
    private static let canvasJS = """
    (function () {
      if (window.__timCanvasLayer) { return; }
      var doc = document;

      if (!doc.querySelector('style[data-tim-styles]')) {
        var st = doc.createElement('style');
        st.setAttribute('data-tim-styles', '');
        st.textContent = '.tim-canvas{display:grid;grid-template-columns:repeat(12,1fr);gap:1.5rem;grid-auto-flow:row dense;align-items:start}' +
          '.tim-object{min-width:0}' +
          '.tim-text{min-height:1em;outline:none}' +
          '.tim-canvas img.tim-object{width:100%;height:auto;display:block}' +
          '.tim-canvas video.tim-object{width:100%;height:auto;display:block}' +
          '@media (max-width:700px){.tim-canvas{grid-template-columns:1fr}.tim-canvas>.tim-object{grid-column:1 / -1 !important}}' +
          '.tim-style-title{font-family:var(--tim-font-heading,inherit);font-size:2.5rem;font-weight:700;line-height:1.15}' +
          '.tim-style-heading{font-family:var(--tim-font-heading,inherit);font-size:1.6rem;font-weight:700;line-height:1.25}' +
          '.tim-style-subheading{font-family:var(--tim-font-heading,inherit);font-size:1.25rem;font-weight:600;line-height:1.3}' +
          '.tim-style-body{font-family:var(--tim-font-body,inherit);font-size:1rem;line-height:1.6}' +
          '.tim-style-caption{font-size:0.85rem;opacity:0.7;line-height:1.4}';
        doc.head.appendChild(st);
      }

      var overlay = doc.createElement('div');
      overlay.id = '__tim-overlay';
      overlay.style.cssText = 'position:absolute;left:0;top:0;z-index:2147483000;pointer-events:none;';
      var box = doc.createElement('div');
      box.style.cssText = 'position:absolute;border:1.5px solid #0a84ff;pointer-events:none;display:none;box-sizing:border-box;';
      var badge = doc.createElement('div');
      badge.style.cssText = 'position:absolute;background:#0a84ff;color:#fff;font:11px -apple-system,sans-serif;padding:2px 6px;border-radius:4px;display:none;white-space:nowrap;';
      var gridBox = doc.createElement('div');
      gridBox.style.cssText = 'position:absolute;pointer-events:none;display:none;';
      overlay.appendChild(gridBox); overlay.appendChild(box); overlay.appendChild(badge);
      var handles = {};
      ['w', 'e'].forEach(function (k) {
        var h = doc.createElement('div');
        h.style.cssText = 'position:absolute;width:9px;height:9px;background:#fff;border:1.5px solid #0a84ff;border-radius:50%;pointer-events:auto;display:none;cursor:ew-resize;';
        h.setAttribute('data-tim-handle', k);
        overlay.appendChild(h); handles[k] = h;
      });
      doc.body.appendChild(overlay);

      var sel = null, drag = null, active = false, editingEl = null;

      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return { x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height };
      }
      function isObject(el) { return !!(el && el.classList && el.classList.contains('tim-object')); }
      function canvasFor(el) { return el && el.closest ? el.closest('[data-tim-canvas]') : null; }
      function stopTextEditing() {
        if (editingEl) { editingEl.removeAttribute('contenteditable'); editingEl = null; }
      }

      function gridInfo(canvas) {
        var cs = getComputedStyle(canvas);
        var gap = parseFloat(cs.columnGap) || 0;
        var padL = parseFloat(cs.paddingLeft) || 0;
        var padR = parseFloat(cs.paddingRight) || 0;
        var inner = canvas.clientWidth - padL - padR;
        var r = rectOf(canvas);
        return {
          gap: gap,
          colW: (inner - gap * 11) / 12,
          originX: r.x + padL,
          top: r.y,
          height: Math.max(canvas.clientHeight, 160)
        };
      }
      function placement(el) {
        var m = String(el.style.gridColumn || '').match(/(\\d+)\\s*\\/\\s*span\\s*(\\d+)/);
        return m ? { col: +m[1], span: +m[2] } : { col: 1, span: 12 };
      }
      function setPlacement(el, col, span) {
        span = Math.max(1, Math.min(12, span));
        col = Math.max(1, Math.min(13 - span, col));
        el.style.gridColumn = col + ' / span ' + span;
      }

      function showGrid(canvas) {
        var g = gridInfo(canvas);
        gridBox.innerHTML = '';
        for (var i = 0; i < 12; i++) {
          var strip = doc.createElement('div');
          strip.style.cssText = 'position:absolute;background:rgba(10,132,255,0.07);border-radius:3px;';
          strip.style.left = (g.originX + i * (g.colW + g.gap)) + 'px';
          strip.style.top = g.top + 'px';
          strip.style.width = g.colW + 'px';
          strip.style.height = g.height + 'px';
          gridBox.appendChild(strip);
        }
        gridBox.style.display = 'block';
      }
      function hideGrid() { gridBox.style.display = 'none'; gridBox.innerHTML = ''; }

      function hide() {
        box.style.display = badge.style.display = 'none';
        hideGrid();
        for (var k in handles) { handles[k].style.display = 'none'; }
      }
      function layout() {
        if (!sel || !doc.contains(sel)) { hide(); return; }
        var r = rectOf(sel);
        box.style.display = 'block';
        box.style.left = r.x + 'px'; box.style.top = r.y + 'px';
        box.style.width = r.w + 'px'; box.style.height = r.h + 'px';
        badge.style.display = 'block';
        badge.style.left = r.x + 'px';
        badge.style.top = Math.max(2, r.y - 24) + 'px';
        if (!drag) {
          var label = sel.tagName.toLowerCase();
          if (isObject(sel) && canvasFor(sel)) {
            var p = placement(sel);
            label += ' · cols ' + p.col + '–' + (p.col + p.span - 1);
          }
          badge.textContent = label;
        }
        var resizable = isObject(sel) && canvasFor(sel);
        handles.w.style.display = handles.e.style.display = resizable ? 'block' : 'none';
        if (resizable) {
          handles.w.style.left = (r.x - 5) + 'px';
          handles.w.style.top = (r.y + r.h / 2 - 5) + 'px';
          handles.e.style.left = (r.x + r.w - 5) + 'px';
          handles.e.style.top = (r.y + r.h / 2 - 5) + 'px';
        }
      }

      function onDown(e) {
        var k = e.target && e.target.getAttribute ? e.target.getAttribute('data-tim-handle') : null;
        if (k && sel && isObject(sel)) {
          var canvas = canvasFor(sel);
          if (!canvas) { return; }
          var p = placement(sel);
          drag = { mode: k, canvas: canvas, sx: e.pageX, col0: p.col, span0: p.span };
          showGrid(canvas);
          e.preventDefault(); e.stopPropagation();
          return;
        }
        if (!active) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        if (obj && obj !== editingEl && !(editingEl && editingEl.contains(e.target))) {
          var canvas2 = canvasFor(obj);
          if (canvas2) {
            stopTextEditing();
            sel = obj;
            var p2 = placement(obj);
            drag = { mode: 'move', canvas: canvas2, sx: e.pageX, sy: e.pageY, col0: p2.col, span: p2.span, moved: false };
            showGrid(canvas2);
            layout();
            e.preventDefault(); e.stopPropagation();
          }
        }
      }

      function onMove(e) {
        if (!drag || !sel) { return; }
        e.preventDefault();
        var g = gridInfo(drag.canvas);
        var deltaCols = Math.round((e.pageX - drag.sx) / (g.colW + g.gap));

        if (drag.mode === 'move') {
          drag.moved = true;
          setPlacement(sel, drag.col0 + deltaCols, drag.span);
          // Vertical drag reorders: DOM order is reading order is mobile order.
          var siblings = Array.prototype.slice.call(drag.canvas.children).filter(function (c) {
            return isObject(c) && c !== sel;
          });
          var ref = null;
          for (var i = 0; i < siblings.length; i++) {
            var sr = rectOf(siblings[i]);
            if (e.pageY < sr.y + sr.h / 2) { ref = siblings[i]; break; }
          }
          if (sel.nextElementSibling !== ref) { drag.canvas.insertBefore(sel, ref); }
          var p = placement(sel);
          badge.textContent = 'cols ' + p.col + '–' + (p.col + p.span - 1);
        } else if (drag.mode === 'e') {
          setPlacement(sel, drag.col0, drag.span0 + deltaCols);
          badge.textContent = 'span ' + placement(sel).span + ' of 12';
        } else if (drag.mode === 'w') {
          var col = drag.col0 + deltaCols;
          var span = drag.span0 - deltaCols;
          if (span >= 1 && col >= 1) { setPlacement(sel, col, span); }
          badge.textContent = 'span ' + placement(sel).span + ' of 12';
        }
        layout();
      }

      function onUp() {
        if (!drag) { return; }
        drag = null;
        hideGrid();
        layout();
      }

      function onClick(e) {
        if (!active || drag) { return; }
        if (e.target && e.target.getAttribute && e.target.getAttribute('data-tim-handle')) { return; }
        if (editingEl && editingEl.contains(e.target)) { return; }
        e.preventDefault(); e.stopPropagation();
        stopTextEditing();
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        var el = obj || e.target;
        if (!obj) {
          while (el && el !== doc.body) {
            if (el.tagName === 'IMG' || getComputedStyle(el).display !== 'inline') { break; }
            el = el.parentElement;
          }
        }
        sel = (!el || el === doc.body) ? null : el;
        if (sel) { layout(); } else { hide(); }
      }

      function onDblClick(e) {
        if (!active) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
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
          editingEl = target;
          target.setAttribute('contenteditable', 'true');
          target.focus();
          sel = target;
          layout();
        }
      }

      function onKey(e) {
        if (e.key === 'Escape') {
          stopTextEditing();
          sel = null;
          hide();
          return;
        }
        if ((e.key === 'Backspace' || e.key === 'Delete') && sel && isObject(sel) && !editingEl) {
          sel.remove();
          sel = null;
          hide();
          e.preventDefault();
        }
      }

      doc.addEventListener('click', onClick, true);
      doc.addEventListener('dblclick', onDblClick, true);
      doc.addEventListener('mousedown', onDown, true);
      doc.addEventListener('mousemove', onMove, true);
      doc.addEventListener('mouseup', onUp, true);
      doc.addEventListener('keydown', onKey, true);
      window.addEventListener('scroll', layout, true);
      window.addEventListener('resize', layout);

      window.__timInsert = function (html) {
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
        if (sel && isObject(sel) && canvasFor(sel) === canvas) {
          canvas.insertBefore(el, sel.nextElementSibling);
        } else {
          canvas.appendChild(el);
        }
        stopTextEditing();
        sel = el;
        layout();
        el.scrollIntoView({ block: 'nearest' });
      };

      window.__timApplyStyle = function (cls) {
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
        String(target.className || '').split(/\\s+/).forEach(function (c) {
          if (c.indexOf('tim-style-') === 0) { target.classList.remove(c); }
        });
        if (cls) { target.classList.add(cls); }
      };

      window.__timCanvasLayer = true;
      window.__timCanvasOn = function () { active = true; overlay.style.display = 'block'; };
      window.__timCanvasOff = function () {
        active = false;
        stopTextEditing();
        sel = null; drag = null;
        hide();
        overlay.style.display = 'none';
      };
    })();
    """
}

extension Tab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Navigating away always leaves edit mode.
        if isEditing { isEditing = false }
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
