# Tim

**The web, editable again.**

Tim is a Mac browser that lets you edit your own pages right where they
live. Browse like Safari. When you land on a page you own, press **Edit**
and change it in place — move things, write, drop in photos — then press
**Done** and it's published. No admin panel, no deploy step, no source
view required.

It's named for Tim Berners-Lee, whose first browser was also an editor.
That half of the idea got lost. Tim brings it back.

<p align="center"><img src="Design/tim garamond@2x.png" width="160" alt=""></p>

## What it does

- **Browses** like Safari — same WebKit engine, same key commands, tabs,
  sidebar, history. The browser half is deliberately familiar; the point
  is what happens on your own pages.
- **Edits** like Keynote. Every page is a canvas on a 24-column grid.
  Select an object and drag it anywhere; resize from any edge; double-
  click text to write. An inspector handles type, color, fill, shadow,
  rotation, arrangement. Text wraps around pictures. Pictures crop like
  Keynote masks. Undo covers everything.
- **Publishes** anywhere. Pressing Done writes the page to your host:
  **SFTP** (any web host, SSH keys only), **Cloudflare**, or **GitHub
  Pages**. A page you haven't connected to a site yet lives as a local
  file, so you can try the whole thing without a server.
- **Keeps a site consistent.** Objects can live on every page (a
  navigation bar, a footer); change one, every page follows. Page styles
  — colors, type, spacing — are shared the same way. A theme, **Paper**,
  comes built in, with Home, About, Work, Writing and Contact templates.
- **Does the mobile layout for you.** The phone version of every page is
  generated from the desktop composition and regenerated on every save.
  When you want more, there's an 8-column phone grid to arrange by hand.
- **Handles media properly.** Drop a photo from Finder, Photos, Mail or
  Messages — or pick straight from your Photos library. Tim makes a
  web-sized copy, strips location data, keeps the original in your
  site's local mirror, and shows the upload happening on the page.
- **Remembers.** Every save is a version. Pages can be hidden (parked at
  a secret address), moved, renamed, duplicated, or put online from a
  local file. Share-card images are generated automatically.

## Try it

Tim needs macOS 26. There's no build to download yet; it builds in about
a minute:

```bash
git clone https://github.com/gjeffrey/Tim.git
cd Tim
./Scripts/make-app.sh && open Tim.app
```

That makes a proper app bundle with its icon and its own permissions.
(`swift run Tim` also works, but an app launched from a sandboxed shell
inherits the sandbox, and file dialogs may quietly fail.) The package
opens in Xcode with `open Package.swift`.

On first launch you'll see the start page. **Start playing** opens an
offline page you can edit immediately; nothing goes online until you
connect a site.

### Connecting a site

Sites → Connect a Site… Give Tim the address your site lives at and how
to reach it. From then on, any page under that address shows a yellow
Edit button. Tim keeps a local mirror of the site, with history, in
`~/Tim/`.

## How it's built

A Swift package, no Electron, no web framework:

- **TimKit** — everything that isn't Mac chrome. Tabs and web state,
  sites and ownership, publishing, the editor engine, the save-time
  passes that generate the phone layout and the site-wide theme, and
  the Paper theme. It compiles for macOS and iOS.
- **Tim** — the macOS app: window, inspector, sheets.
- **TimPad** — the iPad app, early, in its own package.
- **Showcase** — a small Cloudflare Worker behind the public gallery of
  sites made with Tim.

The editor runs inside the page as injected JavaScript. What it saves is
plain HTML and CSS: the grid is CSS Grid, text styles are classes, the
phone layout is a media query. A published page needs nothing from Tim
to render, and nothing from anyone else to be edited again later.

Updates ship through Sparkle.

## Status

Early and actively developed. Tim is used daily for real sites, and it
is also still changing shape. Expect rough edges, and tell us about
them: issues with a page that reproduces the problem are the most useful
thing you can send.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go through
GitHub's private reporting; see [SECURITY.md](SECURITY.md).

## Licence

MIT — see [LICENSE](LICENSE). The Tim name and icon identify this
release and aren't part of the licence (see [TRADEMARK.md](TRADEMARK.md));
build on the code and ship under your own name.
