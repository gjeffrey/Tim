# Contributing to Tim

Thanks for looking. Tim is small, opinionated, and built by one person
with a strong sense of what it should feel like — so the most useful
thing before writing code is to say what you're thinking of in an issue.
Bug reports with a page that reproduces the problem are gold.

## Building

Tim is a Swift package. It needs macOS 26 and the Xcode 26 toolchain
(the Command Line Tools are enough; no Xcode project required).

```bash
./Scripts/make-app.sh && open Tim.app   # a real bundle, with an icon
swift run Tim                            # quick, but sandbox-limited
open Package.swift                       # in Xcode
```

The iPad app lives in `TimPad/` and is its own package depending on
TimKit.

## Where things are

- `Sources/TimKit/` — everything that isn't Mac chrome: tabs, sites,
  publishing, the editor engine, the save-time passes (`MobileCSS`,
  `NavKit`, `PageMotion`, `SiteTheme`), the Paper theme.
- `Sources/Tim/` — the macOS app. `BrowserWindow.swift` is large and
  holds the window, inspector and sheets.
- `Showcase/` — the Cloudflare Worker behind the public gallery.
- `Examples/` — pages to try things on.

## The editor engine

The canvas editor is JavaScript, kept as one Swift multiline string
(`canvasJS` in `Models.swift`) so it's injected as one unit. Two things
to know:

- Backslashes in it are doubled (`\\s` for a regex `\s`). A single
  backslash is a Swift escape and won't compile — or worse, will.
- Before shipping a change, extract the string and run it through
  `node --check`. It catches what the Swift compiler can't.

## Working style

- **Verify in real rendering.** A change to the engine or a save-time
  pass should be seen in a real `WKWebView`, at desktop and phone width,
  before it's called done. Screenshots from a headless harness are fine;
  reasoning about CSS is not.
- **Polish over features.** Toolbar items may disable but never
  disappear. Nothing in the UI uses web vocabulary when a plainer word
  exists.
- **Saved pages are the contract.** Anything written into a page's HTML
  (`data-tim-*`, `tim-*` classes) is read by older and newer builds and
  by the iPad. Change those shapes with care, and never strip what you
  don't understand.
- Commit messages say why, in sentences.

## Licence

By contributing you agree your contribution is licensed under the MIT
licence in `LICENSE`.
