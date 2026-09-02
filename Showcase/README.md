# Tim Showcase

A hand-picked gallery of sites made with Tim, at https://gabrieljeffrey.com/tim/showcase.
Submissions come from the app (Page › Submit to Showcase…), are checked to be live
Tim-made pages, and wait for a person to approve them.

## One-time setup

```bash
cd Showcase/worker
wrangler kv namespace create SHOWCASE        # paste the id into wrangler.toml
openssl rand -hex 24 | wrangler secret put ADMIN_TOKEN   # keep the value: it unlocks /admin
wrangler deploy
```

Review at `https://gabrieljeffrey.com/tim/showcase/admin?token=…`.
Optional: `wrangler secret put NOTIFY_URL` with a webhook to be pinged on each submission.
