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

## Notifications

The review page can notify you when something arrives, so you don't have to
remember to look. Open it and press **Notify me of new submissions**.

Works in Safari and Chrome on the Mac with no install. On iPhone, add the
review page to the Home Screen first — Apple only allows web notifications
from there.

Setup is a VAPID key pair, generated once:

```bash
node -e 'const{webcrypto:c}=require("crypto");(async()=>{
  const k=await c.subtle.generateKey({name:"ECDSA",namedCurve:"P-256"},true,["sign","verify"]);
  const p=await c.subtle.exportKey("jwk",k.privateKey);
  const r=Buffer.from(await c.subtle.exportKey("raw",k.publicKey));
  const u=b=>Buffer.from(b).toString("base64").replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
  console.log("PUBLIC="+u(r));
  console.log(JSON.stringify({kty:p.kty,crv:p.crv,d:p.d,x:p.x,y:p.y}));})()'
```

Put `PUBLIC` in `wrangler.toml` as `VAPID_PUBLIC`; pipe the JSON into
`wrangler secret put VAPID_PRIVATE_JWK`. Rotating the pair unsubscribes
every browser — they'll each need to press the button again.

The push itself carries no payload. It's a bare wake-up; the service worker
then asks `/pending.json` what's waiting and writes the notification. That
keeps submission details out of Apple's and Google's push servers, and the
text stays accurate even if the push was delayed.

`wrangler secret put NOTIFY_URL` still works too, if you'd rather have a
webhook (ntfy, Slack, Shortcuts) alongside or instead.
