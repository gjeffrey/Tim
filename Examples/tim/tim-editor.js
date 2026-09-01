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
      (function parseMobileLayout() {
        var el = doc.querySelector('style[data-tim-mobile-layout]');
        if (!el) { return; }
        try { mobileLayout = JSON.parse(el.getAttribute('data-props') || '{}') || {}; } catch (e) {}
      })();
      function mobileActive() { return collapsed() && Object.keys(mobileLayout).length > 0; }
      function colCount() { return mobileActive() ? MOBILE_COLS : COLS; }
      function ensureObjectId(el) {
        var id = el.getAttribute('data-tim-id');
        if (!id) {
          id = 't' + Math.random().toString(16).slice(2, 8);
          el.setAttribute('data-tim-id', id);
        }
        return id;
      }
      // Every top-level object must hold a place in an explicit mobile
      // layout — anything that slipped through (a group made after the
      // freeze, an object added by other means) joins at the bottom,
      // full width. Heals existing pages on entry.
      function ensureMobileCoverage() {
        var canvas = doc.querySelector('[data-tim-canvas]');
        if (!canvas || !Object.keys(mobileLayout).length) { return; }
        var bottom = 1;
        for (var k in mobileLayout) { bottom = Math.max(bottom, mobileLayout[k][2]); }
        var objs = canvas.querySelectorAll('.tim-object');
        for (var i = 0; i < objs.length; i++) {
          var el = objs[i];
          if (canvasFor(el) !== canvas) { continue; }
          var id = el.getAttribute('data-tim-id');
          if (id && mobileLayout[id]) { continue; }
          var p = desktopPlacement(el);
          var rows = p ? Math.max(2, p.re - p.rs) : 3;
          mobileLayout[ensureObjectId(el)] = [bottom, 1, bottom + rows, MOBILE_COLS + 1];
          bottom += rows;
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
        var css = '@media (max-width: 700px){\n'
          + '.tim-canvas{grid-template-columns:repeat(8, 1fr) !important;grid-auto-rows:32px !important}\n';
        for (var id2 in mobileLayout) {
          var a = mobileLayout[id2];
          css += '.tim-canvas .tim-object[data-tim-id="' + id2 + '"]{grid-area:'
            + a[0] + ' / ' + a[1] + ' / ' + a[2] + ' / ' + a[3] + ' !important;margin-top:0 !important}\n';
        }
        css += '}';
        styleEl.textContent = css;
        styleEl.setAttribute('data-props', JSON.stringify(mobileLayout));
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

      // First entry into phone-width editing: freeze the automatic stack,
      // as rendered right now, into explicit placements — bands of
      // side-by-side objects stay side by side, gaps stay gaps.
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
        var padL = parseFloat(cs2.paddingLeft) || 0;
        var padR = parseFloat(cs2.paddingRight) || 0;
        var cr = canvas.getBoundingClientRect();
        var innerLeft = cr.left + padL;
        var innerWidth = canvas.clientWidth - padL - padR;
        var unit = 48; // 32px rows + 16px gap
        var measured = objs.map(function (el) {
          return { el: el, r: el.getBoundingClientRect() };
        }).sort(function (a, b) { return (a.r.top - b.r.top) || (a.r.left - b.r.left); });
        var row = 1;
        var i = 0;
        var prevBottom = null;
        while (i < measured.length) {
          // A band: everything starting within 10px vertically.
          var band = [measured[i]];
          while (i + 1 < measured.length && Math.abs(measured[i + 1].r.top - band[0].r.top) < 10) {
            i += 1;
            band.push(measured[i]);
          }
          i += 1;
          if (prevBottom !== null) {
            var gapRows = Math.round((band[0].r.top - prevBottom - 16) / unit);
            if (gapRows > 0) { row += Math.min(gapRows, 4); }
          }
          var bandRows = 1;
          band.forEach(function (item) {
            var colStart = Math.max(1, Math.min(MOBILE_COLS, Math.round((item.r.left - innerLeft) / innerWidth * MOBILE_COLS) + 1));
            var colEnd = Math.max(colStart + 1, Math.min(MOBILE_COLS + 1, Math.round((item.r.right - innerLeft) / innerWidth * MOBILE_COLS) + 1));
            var rows = Math.max(1, Math.round((item.r.height + 16) / unit));
            bandRows = Math.max(bandRows, rows);
            mobileLayout[ensureObjectId(item.el)] = [row, colStart, row + rows, colEnd];
          });
          prevBottom = band.reduce(function (m, item) { return Math.max(m, item.r.bottom); }, 0);
          row += bandRows;
        }
        writeMobileLayout();
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
      overlay.appendChild(gridBox); overlay.appendChild(hoverBox); overlay.appendChild(extentBox); overlay.appendChild(box); overlay.appendChild(badge); overlay.appendChild(groupBox);
      var handles = {};
      ['w', 'e', 'n', 's', 'nw', 'ne', 'sw', 'se'].forEach(function (k) {
        var h = doc.createElement('div');
        h.style.cssText = 'position:absolute;width:9px;height:9px;background:#fff;border:1.5px solid #0a84ff;border-radius:50%;pointer-events:auto;display:none;';
        h.style.cursor = (k === 'w' || k === 'e') ? 'ew-resize'
          : (k === 'n' || k === 's') ? 'ns-resize'
          : (k === 'ne' || k === 'sw') ? 'nesw-resize' : 'nwse-resize';
        h.setAttribute('data-tim-handle', k);
        overlay.appendChild(h); handles[k] = h;
      });
      doc.body.appendChild(overlay);

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
        var rowM = String(cs.gridAutoRows || '').match(/(\d+(?:\.\d+)?)px/);
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
        var m = String(el.style.gridArea || '').match(/(\d+)\s*\/\s*(\d+)\s*\/\s*(\d+)\s*\/\s*(\d+)/);
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
      function setDesktopArea(el, rs, cs, re, ce) {
        var rh = Math.max(1, re - rs), cw = Math.max(1, ce - cs);
        cs = Math.max(1, Math.min(COLS + 1 - cw, cs));
        rs = Math.max(1, rs);
        el.style.gridArea = rs + ' / ' + cs + ' / ' + (rs + rh) + ' / ' + (cs + cw);
      }
      function setArea(el, rs, cs, re, ce) {
        if (mobileActive()) {
          var cols = colCount();
          var rh = Math.max(1, re - rs), cw = Math.max(1, Math.min(cols, ce - cs));
          var ncs = Math.max(1, Math.min(cols + 1 - cw, cs));
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
        extentBox.style.display = 'none';
        groupBox.innerHTML = '';
        hideGrid();
        for (var k in handles) { handles[k].style.display = 'none'; }
      }
      function angleOf(el) {
        var m = /rotate\((-?[0-9.]+)deg\)/.exec((el && el.style && el.style.transform) || '');
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
      function layout() {
        if (!sel || !doc.contains(sel)) { hide(); return; }
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
            h.style.left = (cx + dx * cos - dy * sin - 5) + 'px';
            h.style.top = (cy + dx * sin + dy * cos - 5) + 'px';
          }
          place(handles.w, -w0 / 2, 0);
          place(handles.e, w0 / 2, 0);
          place(handles.n, 0, -h0 / 2);
          place(handles.s, 0, h0 / 2);
          place(handles.nw, -w0 / 2, -h0 / 2);
          place(handles.ne, w0 / 2, -h0 / 2);
          place(handles.sw, -w0 / 2, h0 / 2);
          place(handles.se, w0 / 2, h0 / 2);
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
        var k = e.target && e.target.getAttribute ? e.target.getAttribute('data-tim-handle') : null;
        if (k && sel && isObject(sel)) {
          // Option-drag a handle rotates instead of resizing.
          if (e.altKey) {
            var rr = rectOf(sel);
            checkpoint('rotate');
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
          drag = { mode: k, canvas: canvas, sx: e.pageX, sy: e.pageY, p0: p0, angle: effectiveAngle(sel), moved: false };
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
        if (dc !== 0 || dr !== 0) { drag.moved = true; }

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
        var np = placement(sel);
        badge.textContent = drag.mode === 'move'
          ? 'row ' + np.rs + ' · col ' + np.cs
          : (np.ce - np.cs) + '×' + (np.re - np.rs) + ' cells';
        layout();
      }

      var lastDragMoved = false;
      function onUp() {
        if (!drag) { return; }
        var canvas = drag.canvas;
        var moved = drag.moved;
        lastDragMoved = !!moved;
        var wasRotate = drag.mode === 'rotate';
        drag = null;
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
        var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
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
        setDesktopArea(placed, maxRe, 1, maxRe + rowSpan, 1 + colSpan);
        if (mobileActive()) {
          var mMax = 1;
          for (var mid in mobileLayout) { mMax = Math.max(mMax, mobileLayout[mid][2]); }
          var span = Math.min(MOBILE_COLS, colSpan);
          mobileLayout[ensureObjectId(placed)] = [mMax, 1, mMax + rowSpan, 1 + Math.max(2, span)];
          writeMobileLayout();
          // The desktop position was a guess (end of page) — worth a look.
          flagReview('desktop', placed);
        } else if (Object.keys(mobileLayout).length) {
          // A hand-tuned mobile layout exists; this object will join its
          // bottom by default — worth a look over there.
          flagReview('mobile', placed);
        }
        canvas.appendChild(el);
        el = placed;
        var media = (el.matches && el.matches('img,video,audio'))
          ? el
          : (el.querySelector ? el.querySelector('img,video,audio') : null);
        if (media) {
          el.classList.add('tim-loading');
          var settle = function () { el.classList.remove('tim-loading'); layout(); };
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
        return { c: c.innerHTML, p: JSON.stringify(templateProps), m: JSON.stringify(mobileLayout) };
      }
      function sameSnapshot(a, b) { return !!a && !!b && a.c === b.c && a.p === b.p && a.m === b.m; }
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
        hide();
        lastCkptTag = '';
        c.innerHTML = snap.c;
        try { templateProps = JSON.parse(snap.p) || {}; } catch (e) { templateProps = {}; }
        try { mobileLayout = JSON.parse(snap.m || '{}') || {}; } catch (e2) { mobileLayout = {}; }
        writeTemplates();
        if (Object.keys(mobileLayout).length) { writeMobileLayout(); }
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
        var mobileRow = 1;
        if (hadMobile) {
          for (var mk in mobileLayout) { mobileRow = Math.max(mobileRow, mobileLayout[mk][2]); }
          delete mobileLayout[sel.getAttribute('data-tim-id')];
        }
        var kids = Array.prototype.slice.call(sel.children);
        kids.forEach(function (el) {
          var p = desktopPlacement(el);
          if (p) {
            setDesktopArea(el, p.rs + p0.rs - 1, p.cs + p0.cs - 1, p.re + p0.rs - 1, p.ce + p0.cs - 1);
          }
          parentCanvas.insertBefore(el, sel);
          if (hadMobile && el.classList && el.classList.contains('tim-object')) {
            var rows = p ? (p.re - p.rs) : 2;
            mobileLayout[ensureObjectId(el)] = [mobileRow, 1, mobileRow + rows, MOBILE_COLS + 1];
            mobileRow += rows;
          }
        });
        sel.remove();
        if (hadMobile) { writeMobileLayout(); }
        sel = null;
        hide();
        notifySel(true);
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
        ph.parentNode.replaceChild(el, ph);
        if (sel === ph) { sel = el; }
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
        checkpoint('media');
        target.classList.remove('tim-media-replacing');
        if (target.className) { el.className = target.className; }
        if (target.style && target.style.cssText) { el.style.cssText = target.style.cssText; }
        target.parentNode.replaceChild(el, target);
        if (sel === target) { sel = el; }
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
        if (el.classList && el.classList.contains('tim-container')) { return 'Group'; }
        if (el.hasAttribute && el.hasAttribute('data-tim-canvas')) { return 'Canvas'; }
        function titleCase(text) {
          return text.replace(/-/g, ' ').replace(/(^|\s)\w/g, function (c) { return c.toUpperCase(); });
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
          String(el.className || '').split(/\s+/).forEach(function (c) {
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
            String(sel.className || '').split(/\s+/).forEach(function (c) {
              if (c.indexOf('tim-style-') === 0) { timStyle = c; }
            });
            payload = JSON.stringify({
              seq: selSeq,
              path: selPath.map(labelFor),
              label: labelFor(sel),
              tag: sel.tagName.toLowerCase(),
              timStyle: timStyle,
              isText: (sel.classList && (sel.classList.contains('tim-text') || sel.classList.contains('tim-nav'))) ? 1 : 0,
              fontSize: parseFloat(cs.fontSize) || 16,
              fontWeight: parseInt(cs.fontWeight, 10) || 400,
              align: cs.textAlign,
              color: cs.color,
              radius: parseFloat(sel.style.borderRadius) || 0,
              opacity: parseFloat(cs.opacity) || 1,
              padding: parseFloat(sel.style.padding) || 0,
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
              rotation: (function () {
                var m = /rotate\((-?[0-9.]+)deg\)/.exec(sel.style.transform || '');
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
        var re = /\.(tim-style-[a-z]+)\s*\{([^}]*)\}/g;
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
        for (var key in styleRules) { out += '.' + key + '{' + styleRules[key] + '}\n'; }
        el.textContent = out;
      }
      function selStyleClass() {
        var cls = '';
        if (sel) {
          String(sel.className || '').split(/\s+/).forEach(function (c) {
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
          String(member.className || '').split(/\s+/).forEach(function (c) {
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
          var bodyRule = '';
          if (p.bg) { bodyRule += 'background:' + p.bg + ';'; }
          if (p.fg) { bodyRule += 'color:' + p.fg + ';'; }
          if (bodyRule) { out += scope + '{' + bodyRule + '}\n'; }
          if (p.link) { out += scope + ' a{color:' + p.link + ';}\n'; }
          if (p.baseSize != null) { out += 'html:has(' + scope + '){font-size:' + p.baseSize + 'px;}\n'; }
          if (p.padY != null || p.marginX != null || p.contentW != null) {
            var pad = p.padY != null ? p.padY : 48;
            var mx = p.marginX != null ? p.marginX : 32;
            var cw = p.contentW != null ? p.contentW : 1320;
            out += scope + ' .tim-canvas{padding:' + pad + 'px max(' + mx + 'px, calc(50vw - ' + (cw / 2) + 'px));}\n';
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

      window.__timPageInfo = function () {
        var name = doc.body.getAttribute('data-tim-template') || 'default';
        var p = templateProps[name] || {};
        var cs = getComputedStyle(doc.body);
        return JSON.stringify({
          template: name,
          title: doc.title || '',
          bg: p.bg || cs.backgroundColor,
          bgVideo: (function () {
            var v = doc.querySelector('video.tim-page-background');
            return v ? (v.getAttribute('src') || '') : '';
          })(),
          fg: p.fg || cs.color,
          link: p.link || '',
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
          String(member.className || '').split(/\s+/).forEach(function (c) {
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
        overlay.style.display = 'block';
        doc.documentElement.classList.add('tim-editing');
        // Editing at phone width edits the mobile layout.
        if (collapsed()) { window.__timEnsureMobileLayout(); }
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
// The easter egg: the page IS the editor, always. Links click like any
// page — but drag something, or double-click text, and it's alive.
// Nothing saves; every visitor edits their own copy.
(function () {
  if (window.innerWidth <= 700) { return; }
  window.__timDemoLinks = true;
  function begin() {
    if (window.__timCanvasOn) { window.__timCanvasOn(); }
  }
  if (document.readyState === 'complete') { begin(); }
  else { window.addEventListener('load', begin); }

  var bar = document.createElement('div');
  bar.id = '__tim-demo-bar';
  bar.setAttribute('data-tim-demo', '');
  bar.style.cssText = 'position:fixed;left:50%;bottom:22px;transform:translate(-50%, 80px);z-index:2147483200;' +
    'display:flex;gap:10px;align-items:center;background:#111;color:#ddd;' +
    'font:500 12.5px -apple-system,BlinkMacSystemFont,sans-serif;padding:10px 14px;' +
    'border-radius:999px;box-shadow:0 10px 30px rgba(0,0,0,0.45);' +
    'transition:transform 0.35s cubic-bezier(0.2, 0.9, 0.3, 1);';
  var hint = document.createElement('span');
  hint.textContent = 'You found it — this page is running Tim’s editor. Nothing saves.';
  hint.style.cssText = 'color:#bbb;';
  function demoButton(label, handler) {
    var b = document.createElement('button');
    b.textContent = label;
    b.style.cssText = 'background:rgba(255,255,255,0.12);color:#eee;border:none;' +
      'border-radius:999px;padding:6px 12px;font:600 12px -apple-system,sans-serif;cursor:pointer;';
    b.onclick = function (e) { e.stopPropagation(); handler(); };
    return b;
  }
  bar.appendChild(hint);
  bar.appendChild(demoButton('Undo', function () { window.__timUndo && window.__timUndo(); }));
  bar.appendChild(demoButton('Reset', function () { location.reload(); }));
  document.body.appendChild(bar);

  // The bar stays hidden until the visitor actually touches the canvas.
  var revealed = false;
  document.addEventListener('pointerdown', function (e) {
    if (revealed) { return; }
    var obj = e.target && e.target.closest ? e.target.closest('.tim-object') : null;
    if (!obj) { return; }
    if (e.target.closest && e.target.closest('a[href]')) { return; }
    revealed = true;
    bar.style.transform = 'translate(-50%, 0)';
  }, true);
})();
