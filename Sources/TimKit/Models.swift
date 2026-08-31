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
    @Published public var lastHTTPStatus: Int = 200
    /// Current Layout selection, as reported by the canvas layer — the
    /// Inspector's data source. Nil when nothing is selected.
    @Published public var selectionInfo: [String: Any]?

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
        webView.configuration.userContentController.add(self, name: "timSel")

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
        // While editing, only the viewport changes — media queries respond
        // instantly and the edit session survives. The UA swap and reload
        // happen only while browsing.
        guard !isEditing else { return }
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
    /// creating the canvas if the page doesn't have one yet. Spans are in
    /// grid cells (24 columns wide; rows are fixed units).
    public func insertObject(html: String, colSpan: Int = 12, rowSpan: Int = 3) {
        webView.evaluateJavaScript(
            "window.__timInsert && window.__timInsert(\(Self.jsLiteral(html)), \(colSpan), \(rowSpan));",
            completionHandler: nil
        )
    }

    /// Applies a global text style class (tim-style-*) to the selected
    /// object or the paragraph the caret is in.
    public func applyTextStyle(_ styleClass: String) {
        webView.evaluateJavaScript("window.__timApplyStyle && window.__timApplyStyle(\(Self.jsLiteral(styleClass)));", completionHandler: nil)
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
    public func setSelectionStyle(_ property: String, _ value: String) {
        webView.evaluateJavaScript(
            "window.__timSetStyle && window.__timSetStyle(\(Self.jsLiteral(property)), \(Self.jsLiteral(value)));",
            completionHandler: nil
        )
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
          '@media (max-width:700px){.tim-canvas{grid-template-columns:1fr;grid-auto-rows:auto;padding:24px 16px;min-height:0}.tim-canvas>.tim-object{grid-area:auto !important}}' +
          '.tim-style-title{font-family:var(--tim-font-heading,inherit);font-size:2.5rem;font-weight:700;line-height:1.15}' +
          '.tim-style-heading{font-family:var(--tim-font-heading,inherit);font-size:1.6rem;font-weight:700;line-height:1.25}' +
          '.tim-style-subheading{font-family:var(--tim-font-heading,inherit);font-size:1.25rem;font-weight:600;line-height:1.3}' +
          '.tim-style-body{font-family:var(--tim-font-body,inherit);font-size:1rem;line-height:1.6}' +
          '.tim-style-caption{font-size:0.85rem;opacity:0.7;line-height:1.4}';
        doc.head.appendChild(st);
      }

      var COLS = 24;

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
      overlay.appendChild(gridBox); overlay.appendChild(hoverBox); overlay.appendChild(box); overlay.appendChild(badge);
      var handles = {};
      ['w', 'e', 's', 'se'].forEach(function (k) {
        var h = doc.createElement('div');
        h.style.cssText = 'position:absolute;width:9px;height:9px;background:#fff;border:1.5px solid #0a84ff;border-radius:50%;pointer-events:auto;display:none;';
        h.style.cursor = (k === 'w' || k === 'e') ? 'ew-resize' : (k === 's' ? 'ns-resize' : 'nwse-resize');
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
      // In the collapsed (mobile) layout, placement is automatic — objects
      // can be selected and their text edited, but not moved or resized.
      function collapsed() { return window.innerWidth <= 700; }
      function canvasFor(el) { return el && el.closest ? el.closest('[data-tim-canvas]') : null; }
      function stopTextEditing() {
        if (editingEl) { editingEl.removeAttribute('contenteditable'); editingEl = null; }
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
          colW: (inner - gap * (COLS - 1)) / COLS,
          originX: r.x + padL, originY: r.y + padT,
          inner: inner, height: Math.max(canvas.clientHeight, 240)
        };
      }
      function placement(el) {
        var m = String(el.style.gridArea || '').match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*\\/\\s*(\\d+)\\s*\\/\\s*(\\d+)/);
        if (m) { return { rs: +m[1], cs: +m[2], re: +m[3], ce: +m[4] }; }
        return null;
      }
      function setArea(el, rs, cs, re, ce) {
        var rh = Math.max(1, re - rs), cw = Math.max(1, ce - cs);
        cs = Math.max(1, Math.min(COLS + 1 - cw, cs));
        rs = Math.max(1, rs);
        el.style.gridArea = rs + ' / ' + cs + ' / ' + (rs + rh) + ' / ' + (cs + cw);
      }
      // Rows are fixed height, so text boxes grow by extending their row
      // span to fit content — geometry stays deterministic while dragging.
      function fitSpan(el) {
        if (!el || !el.classList || !el.classList.contains('tim-text')) { return; }
        var canvas = canvasFor(el);
        var p = placement(el);
        if (!canvas || !p || collapsed()) { return; }
        var g = gridInfo(canvas);
        var unit = g.rowH + g.rowGap;
        var needed = Math.max(1, Math.ceil((el.scrollHeight + g.rowGap) / unit));
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
          var p = placement(sel);
          badge.textContent = (p ? '✥ ' : '') + sel.tagName.toLowerCase() +
            (p ? ' · ' + (p.ce - p.cs) + '×' + (p.re - p.rs) + ' cells' : '');
        }
        var resizable = isObject(sel) && canvasFor(sel) && placement(sel) && !collapsed();
        for (var k in handles) { handles[k].style.display = resizable ? 'block' : 'none'; }
        if (resizable) {
          handles.w.style.left = (r.x - 5) + 'px';
          handles.w.style.top = (r.y + r.h / 2 - 5) + 'px';
          handles.e.style.left = (r.x + r.w - 5) + 'px';
          handles.e.style.top = (r.y + r.h / 2 - 5) + 'px';
          handles.s.style.left = (r.x + r.w / 2 - 5) + 'px';
          handles.s.style.top = (r.y + r.h - 5) + 'px';
          handles.se.style.left = (r.x + r.w - 5) + 'px';
          handles.se.style.top = (r.y + r.h - 5) + 'px';
        }
      }

      function onDown(e) {
        if (collapsed()) { return; }
        var k = e.target && e.target.getAttribute ? e.target.getAttribute('data-tim-handle') : null;
        if (k && sel && isObject(sel)) {
          var canvas = canvasFor(sel);
          var p0 = placement(sel);
          if (!canvas || !p0) { return; }
          drag = { mode: k, canvas: canvas, sx: e.pageX, sy: e.pageY, p0: p0, moved: false };
          showGrid(canvas);
          e.preventDefault(); e.stopPropagation();
          return;
        }
        if (!active) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        if (obj && obj !== editingEl && !(editingEl && editingEl.contains(e.target))) {
          var canvas2 = canvasFor(obj);
          var p1 = placement(obj);
          if (canvas2 && p1) {
            stopTextEditing();
            sel = obj;
            drag = { mode: 'move', canvas: canvas2, sx: e.pageX, sy: e.pageY, p0: p1, moved: false };
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
        var dc = Math.round((e.pageX - drag.sx) / (g.colW + g.gap));
        var dr = Math.round((e.pageY - drag.sy) / (g.rowH + g.rowGap));
        var p = drag.p0;
        if (dc !== 0 || dr !== 0) { drag.moved = true; }

        if (drag.mode === 'move') {
          setArea(sel, p.rs + dr, p.cs + dc, p.re + dr, p.ce + dc);
        } else if (drag.mode === 'e') {
          setArea(sel, p.rs, p.cs, p.re, Math.max(p.cs + 1, Math.min(COLS + 1, p.ce + dc)));
        } else if (drag.mode === 'w') {
          var ncs = Math.max(1, Math.min(p.ce - 1, p.cs + dc));
          setArea(sel, p.rs, ncs, p.re, p.ce);
        } else if (drag.mode === 's') {
          setArea(sel, p.rs, p.cs, Math.max(p.rs + 1, p.re + dr), p.ce);
        } else if (drag.mode === 'se') {
          setArea(sel, p.rs, p.cs, Math.max(p.rs + 1, p.re + dr), Math.max(p.cs + 1, Math.min(COLS + 1, p.ce + dc)));
        }
        var np = placement(sel);
        badge.textContent = drag.mode === 'move'
          ? 'row ' + np.rs + ' · col ' + np.cs
          : (np.ce - np.cs) + '×' + (np.re - np.rs) + ' cells';
        layout();
      }

      function onUp() {
        if (!drag) { return; }
        var canvas = drag.canvas;
        var moved = drag.moved;
        drag = null;
        hideGrid();
        if (sel) { fitSpan(sel); }
        if (moved) { resort(canvas); }
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
        notifySel();
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
          notifySel();
          return;
        }
        if ((e.key === 'Backspace' || e.key === 'Delete') && active && !editingEl) {
          var t = e.target;
          if (t && (t.isContentEditable || t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) { return; }
          // While editing, delete deletes — it never navigates back.
          e.preventDefault();
          if (sel) {
            sel.remove();
            sel = null;
            hide();
            notifySel();
          }
        }
      }

      function onOver(e) {
        if (!active || drag) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        if (obj && obj !== sel && obj !== editingEl) {
          var r = rectOf(obj);
          hoverBox.style.display = 'block';
          hoverBox.style.left = r.x + 'px'; hoverBox.style.top = r.y + 'px';
          hoverBox.style.width = r.w + 'px'; hoverBox.style.height = r.h + 'px';
        } else {
          hoverBox.style.display = 'none';
        }
      }

      // The badge is a move grip: dragging it moves the selected object.
      badge.addEventListener('mousedown', function (e) {
        if (!sel || !isObject(sel)) { return; }
        var canvas = canvasFor(sel);
        var p = placement(sel);
        if (!canvas || !p) { return; }
        drag = { mode: 'move', canvas: canvas, sx: e.pageX, sy: e.pageY, p0: p, moved: false };
        showGrid(canvas);
        e.preventDefault(); e.stopPropagation();
      });

      doc.addEventListener('click', onClick, true);
      doc.addEventListener('dblclick', onDblClick, true);
      doc.addEventListener('mousedown', onDown, true);
      doc.addEventListener('mousemove', onMove, true);
      doc.addEventListener('mouseup', onUp, true);
      doc.addEventListener('mouseover', onOver, true);
      doc.addEventListener('keydown', onKey, true);
      doc.addEventListener('input', function () {
        if (editingEl) { fitSpan(editingEl); }
      }, true);
      window.addEventListener('scroll', layout, true);
      window.addEventListener('resize', layout);

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
        var maxRe = 1;
        Array.prototype.forEach.call(canvas.children, function (c) {
          var p = placement(c);
          if (p && p.re > maxRe) { maxRe = p.re; }
        });
        setArea(el, maxRe, 1, maxRe + rowSpan, 1 + colSpan);
        canvas.appendChild(el);
        stopTextEditing();
        sel = el;
        fitSpan(el);
        layout();
        notifySel();
        el.scrollIntoView({ block: 'nearest' });
      };

      var selSeq = 0;
      function notifySel() {
        try {
          var payload = '';
          if (sel) {
            selSeq += 1;
            var cs = getComputedStyle(sel);
            var timStyle = '';
            String(sel.className || '').split(/\\s+/).forEach(function (c) {
              if (c.indexOf('tim-style-') === 0) { timStyle = c; }
            });
            payload = JSON.stringify({
              seq: selSeq,
              tag: sel.tagName.toLowerCase(),
              timStyle: timStyle,
              isText: (sel.classList && sel.classList.contains('tim-text')) ? 1 : 0,
              fontSize: parseFloat(cs.fontSize) || 16,
              fontWeight: parseInt(cs.fontWeight, 10) || 400,
              align: cs.textAlign,
              color: cs.color,
              radius: parseFloat(sel.style.borderRadius) || 0,
              opacity: parseFloat(cs.opacity) || 1,
              padding: parseFloat(sel.style.padding) || 0,
              hasShadow: sel.style.boxShadow ? 1 : 0,
              fill: sel.style.background || '',
              fontFamily: String(cs.fontFamily || '').split(',')[0].replace(/["']/g, '').trim(),
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
        sel.style[prop] = value;
        layout();
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
      window.__timCanvasOn = function () {
        active = true;
        overlay.style.display = 'block';
        doc.documentElement.classList.add('tim-editing');
      };
      window.__timCanvasOff = function () {
        active = false;
        stopTextEditing();
        sel = null; drag = null;
        hide();
        hoverBox.style.display = 'none';
        overlay.style.display = 'none';
        notifySel();
        doc.documentElement.classList.remove('tim-editing');
      };
    })();
    """
}

extension Tab: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
        // Navigating away always leaves edit mode.
        if isEditing { isEditing = false }
        lastHTTPStatus = 200
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

    private static let sessionKey = "tim.session.tabs"
    private static let sessionSelectedKey = "tim.session.selected"

    public init() {
        // Pick up where you left off: reopen last session's tabs.
        let saved = UserDefaults.standard.array(forKey: Self.sessionKey) as? [String] ?? []
        if saved.isEmpty {
            newTab()
        } else {
            for url in saved {
                let tab = Tab()
                if url.isEmpty { tab.loadStartPage() } else { tab.navigate(to: url) }
                tabs.append(tab)
            }
            let index = UserDefaults.standard.integer(forKey: Self.sessionSelectedKey)
            selectedTabID = tabs[max(0, min(index, tabs.count - 1))].id
        }
        // URLs change constantly while browsing; a light heartbeat keeps
        // the saved session current without wiring every navigation.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.persistSession()
        }
    }

    public func persistSession() {
        UserDefaults.standard.set(tabs.map { $0.urlString }, forKey: Self.sessionKey)
        let index = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        UserDefaults.standard.set(index, forKey: Self.sessionSelectedKey)
    }

    public func newTab() {
        let tab = Tab()
        tab.loadStartPage()
        tabs.append(tab)
        selectedTabID = tab.id
        persistSession()
    }

    public func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        if tabs.isEmpty { newTab() }
        persistSession()
    }
}
