# Tim

**The web, editable again.**

Tim is a macOS web browser named for Tim Berners-Lee, whose original 1990
*WorldWideWeb* application was both a browser **and** an editor. That half of
the idea got lost. Tim brings it back: browse like Safari, and when you're on
a page you have the rights to change, press **⌘E** and edit it right where it
lives — then publish it back to the host.

- **Browsing** — deliberately, faithfully Safari. The browser half should
  feel completely familiar; the magic lives in the editor.
- **Editing** — Keynote-simple: select, type, style. No source view required
  (but never forbidden).
- **Publishing** — three targets, covering everyone: **Cloudflare** (the
  flagship — free, fast, and the platform we build on), **GitHub Pages**
  (free and git-native), and **SFTP** (table stakes; works with any web host
  ever). Cloudflare's EmDash is rebuilding the CMS server-side on Astro;
  Tim is the same read-write-web revival built client-side, on the same
  foundation.

## Status: v0.3

A native SwiftUI app (no Electron), built as a Swift Package — it compiles
with Command Line Tools alone, and opens directly in Xcode via
`open Package.swift`.

Working today:

- **Safari-style chrome** — native unified toolbar (back/forward, centered
  address field that searches DuckDuckGo when the input isn't a URL, reload),
  a Safari-style tab bar that appears with your second tab (⌘T/⌘W), and a
  My Sites toolbar menu.
- **Safari-identical rendering** — same WebKit engine, and Tim identifies
  as Safari (`applicationNameForUserAgent` adds the `Version/… Safari/…`
  token), so sites that sniff user agents serve Tim the same markup they
  serve Safari. Pinch-zoom and element fullscreen enabled; pages are
  inspectable with Safari's Web Inspector (Develop menu) for free.
- **Sites & ownership detection** — connect a site by mapping a URL origin
  (including `file://` folders, for previewing local builds) to a publish
  target. When a browsed page belongs to a connected site, an editable badge
  appears beside the address bar and the pencil lights up. Tim knows which
  pages are yours.
- **Three publish targets**, each with a Verify Connection check:
  - **Cloudflare** — deploys with Wrangler (`wrangler login` once; Tim never
    sees credentials).
  - **GitHub Pages** — publishing commits the edit and pushes to origin with
    your existing git credentials.
  - **SFTP** — any web host; SSH keys only (`BatchMode`), never passwords.
- **The Astro round trip (first slice)** — when a connected site points at a
  local Astro project, Publish doesn't upload DOM. Tim records your text
  edits while you type (a MutationObserver keeps old → new pairs), writes
  them into the project's `src/` files — only when the match is unambiguous;
  anything unclear is reported, never guessed — then runs `astro build` and
  deploys `dist/` to the site's target. Formatting edits don't round-trip
  yet; that's the AST work.
- **Edit mode (⌘E)** with two sub-modes, like Keynote's text-vs-object split:
  - **Text** — WebKit `designMode` with a formatting bar: text styles,
    bold/italic/underline/strikethrough, lists, links, undo/redo.
  - **Arrange** — click any element to select it (Keynote-style handles and
    a live size badge), drag to resize with **snapping**: widths snap to
    sibling widths and to container fractions (¼ ⅓ ½ ⅔ ¾ full) with guide
    lines, and fraction snaps are written as percentages so they stay
    responsive. Persists on plain-HTML pages via Save; preview-only on
    Astro pages until the v0.4 source mapping.
- **Components & templates** (Astro sites) — the Insert menu lists the
  site's own `src/components/`, with props parsed from `Astro.props`;
  inserting writes the import + instance into the page source with
  placeholder prop text you then edit inline (which round-trips as text).
  New Page… instantiates the site's layout — its master slide — builds, and
  opens the new page.
- **Theme & typography** (Astro sites) — a Theme panel with a curated font
  catalog (16 excellent Google Fonts + system), separate heading/body
  choices, an accent color, and **Import Font…** (ttf/otf/woff2 copied into
  `public/fonts/` with a generated `@font-face`; the real family name is
  read via CoreText). Applying writes `public/tim-theme.css` (CSS custom
  properties — Tim owns this one file and never touches the site's other
  CSS), links it from the layout, rebuilds, and reloads.
- **Save** for plain local `file://` pages.
- An editable start page. Try ⌘E on it.

### Try the round trip

```bash
cd Examples/astro-site && npm install && npm run build
```

Then in Tim: My Sites → Connect Site…, set the Site URL to the full path of
`Examples/astro-site/dist`, pick a target (any — uncheck "Deploy after
build" in the publish sheet to stay local), and set the site folder to
`Examples/astro-site`. Browse to `dist/index.html`, press ⌘E, fix some copy,
hit Publish: Tim patches the `.astro` source, rebuilds, and reloads.

## Run it

```bash
swift run Tim
```

Try the sample page: paste the full path to `Examples/hello/index.html` into
the address bar, press ⌘E, edit, Save.

## Platforms

Tim is built Mac-first but iPhone/iPad-native by design — the goal is
shipping all three, potentially simultaneously. The package is split
accordingly:

- **TimKit** (library, compiles for macOS + iOS/iPadOS — verified against
  the iOS SDK in CI-fashion on every restructure): tabs and web state
  (WKWebView is the same engine everywhere), sites and ownership matching,
  the edit tracker, and the Astro source round trip.
- **Tim** (executable): the macOS chrome and the macOS publish backends.

Per-platform publishing strategy, same function shapes throughout:

| Target | macOS (today) | iOS/iPadOS (planned) |
|---|---|---|
| Cloudflare | Wrangler CLI | Pages Direct Upload / Workers API |
| GitHub Pages | local git commit + push | GitHub REST API commits |
| SFTP | system `sftp`/`scp`, SSH keys | embedded SSH client (swift-nio-ssh) |
| Astro build | local `npm run build` | git-connected CI (Workers Builds / Actions) — publish pushes source, the cloud builds |

The iOS build-step answer is the elegant one: on iPhone you don't build,
you *push* — Cloudflare and GitHub both rebuild automatically from source,
which is exactly the workflow their git integrations were designed for.
Published sites themselves are responsive by default (the example site
included).

## Design principles

1. **Reading and writing are the same surface.** No separate "editor app",
   no admin panel, no deploy step you can see.
2. **Apple-grade restraint.** Every control earns its pixels. Editing chrome
   appears only in edit mode.
3. **The page you publish is the page you saw.** WYSIWYG honesty — Tim edits
   the live DOM, not a parallel source of truth.
4. **Own your keys, own your site.** Publishing uses your credentials to your
   host. Tim is not a walled garden.

## The framework decision: Astro

Tim does not aim to be a general-purpose HTML editor. Like Keynote, it gives
you a framework that structures free design: Tim's editor reads and writes
**[Astro](https://astro.build)** projects, with page content in **content
collections** (Markdown/Markdoc).

Tim speaks Astro natively: **components**, **layouts**, **pages**, **props**
are the product vocabulary, not just the implementation's — no proprietary
renaming layer. The Keynote mapping below is an orientation aid, not a
glossary Tim uses in its UI:

| Keynote | Astro | Tim edits it as |
|---|---|---|
| Slides | Pages (`src/pages/`) | The pages you browse |
| Masters/Themes | Layouts | Site-wide design |
| Objects | Components | Blocks you select, move, restyle |
| Slide text | Content collections (Markdown/Markdoc) | Inline text editing |

Why Astro (verified against the 2026 landscape):

- **Static-first, zero-JS by default** — `astro build` emits plain HTML/CSS
  that deploys to dumb shared hosting over SFTP. Our v1 target, natively.
- **Designer-legible source** — `.astro` files are HTML with props. Clean
  code out is a feature of the format, not a hope.
- **Machine-editable** — official compiler with a typed AST, official
  Prettier/ESLint tooling, and dev-mode `data-astro-source-file`/`-loc`
  annotations on every rendered element: the click-this-in-the-page →
  edit-that-in-the-source primitive an editor needs, built in.
- **Ecosystem convergence** — TinaCMS made Astro its default visual-editing
  target in 2026; Onlook supports it. The visual-editing world is converging
  here rather than inventing rival formats.
- **The growth path is first-party** — Cloudflare acquired Astro (Jan 2026),
  so the same project later deploys to Workers with a first-party adapter.
  Static shared hosting today, serverless tomorrow, one format.

Known risks we accept and design around: there is no official
AST→`.astro` serializer (we do span-based source edits + Prettier
normalization, with golden-file round-trip tests); the compiler is being
rewritten in Rust, so we isolate parsing behind an internal interface; and
frontmatter is arbitrary TypeScript, so Tim treats components with complex
logic as "locked" — visible, not editable — the way Keynote handles media it
can't edit. Day-to-day *content* edits round-trip through Markdown/Markdoc,
which has an official serializer (`Markdoc.format`), reserving `.astro`
rewriting for structural design edits.

Runners-up for the record: Eleventy (purest HTML output, but no single
canonical component format to parse) and SvelteKit (superb tooling, but its
grain points at apps, not documents — Svelte 5 runes put program logic in
component source).

## Roadmap

- **v0.4 — the full Astro round trip**: the text round trip shipped in v0.3
  via unambiguous source matching. Next: build with
  `data-astro-source-file`/`-loc` annotations for exact DOM→source mapping
  (no ambiguity, ever), span-based `.astro` AST edits so formatting and
  structure round-trip too, and `astro dev` live preview instead of static
  `dist/` browsing. Raw `designMode` editing remains the fallback for
  plain-HTML sites.
- **v0.5 — the Keynote half**: selection handles, drag-to-move blocks,
  image/figure insertion (asset upload), an inspector panel (typography,
  color, spacing), document-wide themes — all expressed as component props
  and layout edits, which is what keeps the emitted code clean.
- **v0.6 — browser polish**: history, autocomplete in the address field,
  downloads, favicons, pinned tabs — Safari familiarity, deepened.
- **v0.7 — deeper hosting**: Cloudflare Workers (beyond static), Git-backed
  publishing (edit → commit → push), Netlify/Vercel adapters.
- **Someday**: first-party hosting; multiplayer editing; an "edit this page"
  protocol so any site can declare itself Tim-editable.

## Architecture notes

- `Models.swift` — `Tab` (owns a `WKWebView`, mirrors its state via KVO for
  SwiftUI) and `BrowserStore` (tabs + selection).
- `BrowserWindow.swift` — all chrome: sidebar, toolbar, editing bar,
  publish sheet.
- `Publisher.swift` — SFTP upload via the system `sftp` binary; per-host
  config in `UserDefaults`.
- Editing is WebKit `document.designMode` + `execCommand` for v0.1. The v0.3
  editing engine will replace `execCommand` with a proper
  selection/serialization layer injected as a user script.
