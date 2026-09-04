import Foundation

public extension Notification.Name {
    /// A link on the start page the app should act on rather than follow.
    static let timHomeAction = Notification.Name("tim.homeAction")
}

/// The new-tab page — Tim's home. The app fills in `contentProvider` at
/// launch so this shows your sites and your pages; on its own, before any
/// of that exists, it's the plain welcome below.
public enum StartPage {
    public static var contentProvider: (() -> String)?
    static var current: String { contentProvider?() ?? html }

    static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Start</title>
    <style>
      :root { color-scheme: light dark; }
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: -apple-system, ui-sans-serif, system-ui, sans-serif;
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        background: #fbfbfd;
        color: #1d1d1f;
      }
      main { max-width: 34rem; padding: 3rem 2rem; text-align: center; }
      h1 {
        font-size: 4.5rem;
        font-weight: 700;
        letter-spacing: -0.03em;
        background: linear-gradient(135deg, #0a84ff, #bf5af2);
        -webkit-background-clip: text;
        background-clip: text;
        color: transparent;
        margin-bottom: 0.4rem;
      }
      .tagline {
        font-size: 1.35rem;
        font-weight: 500;
        color: #6e6e73;
        margin-bottom: 2.2rem;
        letter-spacing: -0.01em;
      }
      p.body { font-size: 1rem; line-height: 1.6; color: #424245; margin-bottom: 1rem; }
      kbd {
        font-family: inherit;
        font-size: 0.9em;
        background: rgba(0,0,0,0.06);
        border-radius: 5px;
        padding: 0.12em 0.45em;
        border: 1px solid rgba(0,0,0,0.1);
      }
      .hint { font-size: 0.9rem; color: #86868b; margin-top: 2.4rem; }
      @media (prefers-color-scheme: dark) {
        body { background: #161617; color: #f5f5f7; }
        .tagline { color: #a1a1a6; }
        p.body { color: #d2d2d7; }
        kbd { background: rgba(255,255,255,0.1); border-color: rgba(255,255,255,0.16); }
        .hint { color: #86868b; }
      }
    </style>
    </head>
    <body>
    <main>
      <h1>Tim</h1>
      <p class="tagline">The web, editable again.</p>
      <p class="body">Type an address above to browse. Connect a site you own — the
      server icon in the toolbar — and when you land on one of its pages an
      <strong>Edit</strong> button appears: edit the page right where it lives,
      then publish it back.</p>
      <p class="hint">Your pages, editable where they live.</p>
    </main>
    </body>
    </html>
    """
}
