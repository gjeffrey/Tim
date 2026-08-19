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

    /// The Keynote layer: free-positioned objects (.tim-object) on a canvas
    /// ([data-tim-canvas]) — drag to move with alignment guides against
    /// other objects and the canvas center/edges, resize with snapping,
    /// double-click a text box to edit it, ⌫ deletes. Positions are stored
    /// as % of canvas width so layouts stay proportional on any screen;
    /// the canvas grows vertically to fit its objects.
    private static let arrangeJS = """
    (function () {
      if (window.__timArrange) { return; }
      var doc = document;

      if (!doc.querySelector('style[data-tim-styles]')) {
        var st = doc.createElement('style');
        st.setAttribute('data-tim-styles', '');
        st.textContent = '.tim-canvas{position:relative}' +
          '.tim-object{position:absolute;box-sizing:border-box;margin:0}' +
          '.tim-text{min-height:1em;outline:none}' +
          '.tim-style-title{font-family:var(--tim-font-heading,inherit);font-size:2.5rem;font-weight:700;line-height:1.15}' +
          '.tim-style-heading{font-family:var(--tim-font-heading,inherit);font-size:1.6rem;font-weight:700;line-height:1.25}' +
          '.tim-style-subheading{font-family:var(--tim-font-heading,inherit);font-size:1.25rem;font-weight:600;line-height:1.3}' +
          '.tim-style-body{font-family:var(--tim-font-body,inherit);font-size:1rem;line-height:1.6}' +
          '.tim-style-caption{font-size:0.85rem;opacity:0.7;line-height:1.4}';
        doc.head.appendChild(st);
      }

      var overlay = doc.createElement('div');
      overlay.style.cssText = 'position:absolute;left:0;top:0;z-index:2147483000;pointer-events:none;';
      overlay.id = '__tim-overlay';
      var box = doc.createElement('div');
      box.style.cssText = 'position:absolute;border:1.5px solid #0a84ff;pointer-events:none;display:none;box-sizing:border-box;';
      var badge = doc.createElement('div');
      badge.style.cssText = 'position:absolute;background:#0a84ff;color:#fff;font:11px -apple-system,sans-serif;padding:2px 6px;border-radius:4px;display:none;white-space:nowrap;';
      var guide = doc.createElement('div');
      guide.style.cssText = 'position:absolute;width:1px;background:#ff9f0a;display:none;';
      var guideH = doc.createElement('div');
      guideH.style.cssText = 'position:absolute;height:1px;background:#ff9f0a;display:none;';
      overlay.appendChild(box); overlay.appendChild(badge); overlay.appendChild(guide); overlay.appendChild(guideH);
      var handles = {};
      ['e','s','se'].forEach(function (k) {
        var h = doc.createElement('div');
        h.style.cssText = 'position:absolute;width:9px;height:9px;background:#fff;border:1.5px solid #0a84ff;border-radius:50%;pointer-events:auto;display:none;';
        h.style.cursor = k === 'e' ? 'ew-resize' : (k === 's' ? 'ns-resize' : 'nwse-resize');
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
      function growCanvas(canvas) {
        if (!canvas) { return; }
        var max = 0;
        Array.prototype.forEach.call(canvas.children, function (c) {
          if (isObject(c)) { max = Math.max(max, c.offsetTop + c.offsetHeight); }
        });
        if (max > 0) { canvas.style.minHeight = (max + 48) + 'px'; }
      }
      function stopTextEditing() {
        if (editingEl) { editingEl.removeAttribute('contenteditable'); editingEl = null; }
      }
      function hide() {
        box.style.display = badge.style.display = guide.style.display = guideH.style.display = 'none';
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

      // Keynote-style move snapping: align to other objects' edges and
      // centers, and to the canvas edges and center.
      function moveTargets(el, canvas) {
        var xs = [], ys = [];
        var w = el.offsetWidth, h = el.offsetHeight;
        var cw = canvas.clientWidth;
        xs.push({ left: 0, guide: 0 });
        xs.push({ left: cw - w, guide: cw });
        xs.push({ left: (cw - w) / 2, guide: cw / 2 });
        Array.prototype.forEach.call(canvas.children, function (o) {
          if (o === el || !isObject(o)) { return; }
          var ol = o.offsetLeft, ot = o.offsetTop, ow = o.offsetWidth, oh = o.offsetHeight;
          xs.push({ left: ol, guide: ol });
          xs.push({ left: ol + ow - w, guide: ol + ow });
          xs.push({ left: ol + (ow - w) / 2, guide: ol + ow / 2 });
          ys.push({ top: ot, guide: ot });
          ys.push({ top: ot + oh - h, guide: ot + oh });
          ys.push({ top: ot + (oh - h) / 2, guide: ot + oh / 2 });
        });
        return { xs: xs, ys: ys };
      }

      function onDown(e) {
        var k = e.target && e.target.getAttribute ? e.target.getAttribute('data-tim-handle') : null;
        if (k && sel) {
          var r = rectOf(sel);
          drag = { k: k, sx: e.pageX, sy: e.pageY, w: r.w, h: r.h, targets: snapTargets() };
          e.preventDefault(); e.stopPropagation();
          return;
        }
        if (!active) { return; }
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
        if (obj && obj !== editingEl && !(editingEl && editingEl.contains(e.target))) {
          var canvas = canvasFor(obj);
          if (canvas) {
            stopTextEditing();
            sel = obj;
            drag = {
              k: 'move', el: obj, canvas: canvas,
              sx: e.pageX, sy: e.pageY,
              left: obj.offsetLeft, top: obj.offsetTop,
              targets: moveTargets(obj, canvas), moved: false
            };
            layout();
            e.preventDefault(); e.stopPropagation();
          }
        }
      }

      function onMove(e) {
        if (!drag || !sel) { return; }
        e.preventDefault();
        guide.style.display = guideH.style.display = 'none';

        if (drag.k === 'move') {
          var canvas = drag.canvas;
          var cr = rectOf(canvas);
          var nl = drag.left + (e.pageX - drag.sx);
          var nt = drag.top + (e.pageY - drag.sy);
          var snapX = null, snapY = null;
          drag.targets.xs.forEach(function (t) { if (Math.abs(nl - t.left) < 6) { nl = t.left; snapX = t; } });
          drag.targets.ys.forEach(function (t) { if (Math.abs(nt - t.top) < 6) { nt = t.top; snapY = t; } });
          nt = Math.max(0, nt);
          drag.moved = true;
          sel.style.left = Math.round(nl) + 'px';
          sel.style.top = Math.round(nt) + 'px';
          if (snapX) {
            guide.style.display = 'block';
            guide.style.left = (cr.x + snapX.guide) + 'px';
            guide.style.top = cr.y + 'px';
            guide.style.height = Math.max(canvas.clientHeight, 120) + 'px';
          }
          if (snapY) {
            guideH.style.display = 'block';
            guideH.style.top = (cr.y + snapY.guide) + 'px';
            guideH.style.left = cr.x + 'px';
            guideH.style.width = canvas.clientWidth + 'px';
          }
          badge.textContent = Math.round(nl) + ', ' + Math.round(nt);
          layout();
          return;
        }

        var w = drag.w + (e.pageX - drag.sx);
        var h = drag.h + (e.pageY - drag.sy);
        var snapped = null;
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
        if (!drag) { return; }
        if (drag.k === 'move' && drag.moved && sel) {
          // Store horizontal position as % of canvas width so the layout
          // stays proportional on any screen. Top stays px — the canvas
          // grows vertically as needed.
          var cw = drag.canvas.clientWidth;
          if (cw > 0) {
            sel.style.left = (sel.offsetLeft / cw * 100).toFixed(2) + '%';
          }
          growCanvas(drag.canvas);
        } else if (sel && isObject(sel)) {
          growCanvas(canvasFor(sel));
        }
        drag = null;
        guide.style.display = guideH.style.display = 'none';
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
        if (obj && obj.classList.contains('tim-text')) {
          e.preventDefault(); e.stopPropagation();
          stopTextEditing();
          editingEl = obj;
          obj.setAttribute('contenteditable', 'true');
          obj.focus();
          sel = obj;
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
          var canvas = canvasFor(sel);
          sel.remove();
          sel = null;
          hide();
          growCanvas(canvas);
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
          canvas.style.minHeight = '40vh';
          doc.body.appendChild(canvas);
        }
        var tmp = doc.createElement('div');
        tmp.innerHTML = html;
        var el = tmp.firstElementChild;
        if (!el) { return; }
        var cr = rectOf(canvas);
        el.style.top = Math.max(24, Math.round(window.scrollY + 120 - cr.y)) + 'px';
        canvas.appendChild(el);
        stopTextEditing();
        sel = el;
        growCanvas(canvas);
        layout();
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

      window.__timArrange = true;
      window.__timArrangeOn = function () { active = true; overlay.style.display = 'block'; };
      window.__timArrangeOff = function () {
        active = false;
        stopTextEditing();
        sel = null; drag = null;
        hide();
        overlay.style.display = 'none';
      };
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
    /// object in Layout mode, or the current paragraph in Text mode.
    public func applyTextStyle(_ styleClass: String) {
        webView.evaluateJavaScript("window.__timApplyStyle && window.__timApplyStyle(\(Self.jsLiteral(styleClass)));", completionHandler: nil)
    }

    /// The page's canvas region, serialized for the source round trip.
    public func canvasHTML(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__timCanvasHTML ? window.__timCanvasHTML() : ''") { result, _ in
            completion(result as? String ?? "")
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
          // Canvas content round-trips wholesale via __timCanvasHTML —
          // don't double-report its text edits.
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
      if (!window.__timApplyStyle) {
        window.__timApplyStyle = function (cls) {
          var s = window.getSelection();
          var n = s && s.anchorNode;
          var target = n ? (n.nodeType === 1 ? n : n.parentElement) : null;
          while (target && target !== document.body && getComputedStyle(target).display === 'inline') {
            target = target.parentElement;
          }
          if (!target || target === document.body) { return; }
          String(target.className || '').split(/\\s+/).forEach(function (c) {
            if (c.indexOf('tim-style-') === 0) { target.classList.remove(c); }
          });
          if (cls) { target.classList.add(cls); }
        };
      }
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
