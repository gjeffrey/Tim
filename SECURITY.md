# Security

Tim publishes to your own hosting with your own credentials, so a
security problem in Tim can be a problem on your site. Please report
anything you find privately.

Use GitHub's private vulnerability reporting: open the **Security** tab
of this repository and choose **Report a vulnerability**. You'll get a
reply there. Please don't open a public issue for a security report.

What's worth reporting:

- Any way for a page Tim is browsing to reach the editor, the mirror on
  disk, or a publish target.
- Credentials, tokens or keys appearing anywhere they shouldn't — in a
  published page, a log, a URL.
- The media pipeline leaving location data in a published file. Tim
  strips it; if it doesn't, that's a bug of this kind.
- The Showcase worker (`Showcase/worker`) accepting or exposing anything
  it shouldn't.

Tim's publishing never stores passwords: SFTP is keys-only, GitHub Pages
uses your git credentials, and Cloudflare uses a token you give it. If
you find that isn't true somewhere, report that too.
