// Tim Showcase — submissions, review, and the public gallery.
//
// GET  /tim/showcase              the gallery (approved entries)
// GET  /tim/showcase/feed.json    approved entries as JSON
// POST /tim/showcase/submit       {url, name, note, agree} — from Tim's Submit to Showcase…
// GET  /tim/showcase/admin?token= review pending entries
// POST /tim/showcase/review       token, id, action (approve | reject | remove)
// GET  /tim/showcase/sw.js        service worker, for review-page notifications
// GET  /tim/showcase/pending.json token= — what is waiting (read by the worker)
// POST /tim/showcase/subscribe    token, subscription — turn notifications on
// POST /tim/showcase/unsubscribe  token, subscription — turn them off
//
// Storage (KV): pending:<id> → entry (90-day TTL); approved → JSON array;
// sub:<urlhash> → "1" (one submission per URL); rl:<ip> → count (daily);
// push:<id> → a browser subscribed to notifications.

import { pushReady, saveSubscription, dropSubscription, notifyAll, serviceWorker } from "./push.js";

const BASE = "/tim/showcase";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    let path = url.pathname;
    if (path.startsWith(BASE)) path = path.slice(BASE.length) || "/";
    if (path.endsWith("/") && path.length > 1) path = path.slice(0, -1);
    try {
      if (request.method === "GET" && path === "/") return gallery(env);
      if (request.method === "GET" && path === "/feed.json") return feed(env);
      if (request.method === "POST" && path === "/submit") return submit(request, env, ctx);
      if (request.method === "OPTIONS" && path === "/submit") return new Response(null, { headers: cors() });
      if (request.method === "GET" && path === "/admin") return admin(url, env);
      if (request.method === "POST" && path === "/review") return review(request, env);
      if (request.method === "GET" && path === "/sw.js") return serviceWorker(BASE);
      if (request.method === "GET" && path === "/pending.json") return pendingJSON(url, env);
      if (request.method === "POST" && path === "/subscribe") return subscribe(request, env, true);
      if (request.method === "POST" && path === "/unsubscribe") return subscribe(request, env, false);
    } catch (e) {
      return json({ error: "Something went wrong on our side." }, 500);
    }
    return new Response("Not found", { status: 404 });
  },
};

// ---------- submit ----------

async function submit(request, env, ctx) {
  let body;
  try { body = await request.json(); } catch { return json({ error: "Send JSON." }, 400, cors()); }
  const name = clean(body.name, 60);
  const note = clean(body.note, 160);
  const agree = body.agree === true;
  let target;
  try { target = new URL(String(body.url || "")); } catch { return json({ error: "That isn't a web address." }, 400, cors()); }
  if (target.protocol !== "https:" && target.protocol !== "http:") return json({ error: "The address must start with http or https." }, 400, cors());
  if (name.length < 2) return json({ error: "Tell us your name." }, 400, cors());
  if (note.length < 20) return json({ error: "Say a little more about the site — at least a sentence." }, 400, cors());
  if (!agree) return json({ error: "Please confirm the site is yours and may be shown publicly." }, 400, cors());

  // Rate limit: three submissions a day per address.
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const rlKey = "rl:" + ip;
  const count = parseInt((await env.SHOWCASE.get(rlKey)) || "0", 10);
  if (count >= 3) return json({ error: "That's enough for today — try again tomorrow." }, 429, cors());

  // One submission per page.
  target.hash = "";
  const urlHash = await sha(target.href);
  if (await env.SHOWCASE.get("sub:" + urlHash)) return json({ error: "This page has already been submitted. We review everything by hand — thanks for your patience." }, 409, cors());

  // The page must be live, and made with Tim.
  const page = await inspect(target.href);
  if (!page.ok) return json({ error: page.error }, 422, cors());

  const id = crypto.randomUUID();
  const entry = {
    id, url: target.href, name, note,
    title: page.title || target.hostname,
    image: page.image || "",
    description: page.description || "",
    submitted: new Date().toISOString(),
  };
  await env.SHOWCASE.put("pending:" + id, JSON.stringify(entry), { expirationTtl: 90 * 86400 });
  await env.SHOWCASE.put("sub:" + urlHash, id, { expirationTtl: 365 * 86400 });
  await env.SHOWCASE.put(rlKey, String(count + 1), { expirationTtl: 86400 });
  // Don't make the submitter wait on our notifications.
  const tell = async () => {
    await notifyAll(env);
  };
  if (ctx && ctx.waitUntil) ctx.waitUntil(tell()); else await tell();
  if (env.NOTIFY_URL) {
    try {
      await fetch(env.NOTIFY_URL, { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: `Tim Showcase: ${name} submitted ${target.href}\n${note}` }) });
    } catch {}
  }
  return json({ ok: true, id, message: "Thanks. A person reads every submission; most hear back within a week." }, 202, cors());
}

// Fetch the page and read what we need from it. Tim-made pages carry
// <meta name="generator" content="Tim…">.
async function inspect(href) {
  let res;
  try {
    res = await fetch(href, { redirect: "follow", headers: { "user-agent": "Tim Showcase (+https://gabrieljeffrey.com/tim)" },
      signal: AbortSignal.timeout(10000) });
  } catch { return { ok: false, error: "We couldn't reach that page." }; }
  if (!res.ok) return { ok: false, error: `The page answered ${res.status}. It has to be live first.` };
  const type = res.headers.get("content-type") || "";
  if (!type.includes("html")) return { ok: false, error: "That address isn't a web page." };
  const html = (await res.text()).slice(0, 200000);
  if (!/<meta\s+name=["']generator["']\s+content=["']Tim/i.test(html) && !/<meta\s+content=["']Tim[^"']*["']\s+name=["']generator["']/i.test(html)) {
    return { ok: false, error: "The Showcase is for pages made with Tim — this one doesn't look like it was." };
  }
  return {
    ok: true,
    title: meta(html, "og:title") || (html.match(/<title[^>]*>([^<]*)<\/title>/i) || [])[1]?.trim() || "",
    image: abs(meta(html, "og:image"), href),
    description: meta(html, "og:description") || meta(html, "description", "name") || "",
  };
}

function meta(html, key, attr = "property") {
  const re1 = new RegExp(`<meta\\s+${attr}=["']${key.replace(":", "\\:")}["']\\s+content=["']([^"']*)["']`, "i");
  const re2 = new RegExp(`<meta\\s+content=["']([^"']*)["']\\s+${attr}=["']${key.replace(":", "\\:")}["']`, "i");
  const m = html.match(re1) || html.match(re2);
  return m ? decode(m[1]) : "";
}
function abs(u, base) { if (!u) return ""; try { return new URL(u, base).href; } catch { return ""; } }
function decode(s) { return s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">"); }
function clean(v, max) { return String(v || "").replace(/\s+/g, " ").trim().slice(0, max); }
async function sha(s) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s.toLowerCase()));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

// ---------- gallery ----------

async function approved(env) {
  return JSON.parse((await env.SHOWCASE.get("approved")) || "[]");
}

async function feed(env) {
  return json({ entries: await approved(env) }, 200, { "cache-control": "public, max-age=60" });
}

async function gallery(env) {
  const entries = await approved(env);
  const cards = entries.map(e => `
    <a class="card" href="${esc(e.url)}" target="_blank" rel="noopener">
      ${e.image ? `<img src="${esc(e.image)}" alt="" loading="lazy">` : `<div class="blank"></div>`}
      <div class="text">
        <h2>${esc(e.title)}</h2>
        <p>${esc(e.note)}</p>
        <span class="by">${esc(e.name)}</span>
      </div>
    </a>`).join("");
  const empty = `<p class="empty">Nothing here yet. The first site is on its way.</p>`;
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Showcase — sites made with Tim</title>
<meta property="og:title" content="Showcase — sites made with Tim">
<meta property="og:description" content="A hand-picked gallery of sites made with Tim, the browser that edits.">
<link rel="icon" href="/tim/media/icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=EB+Garamond:ital,wght@0,400;0,500;0,600;1,400&display=swap" rel="stylesheet">
<style>
:root{--ink:#161616;--paper:#fbfaf6;--muted:#6b6a66;--yellow:#ffd60a}
*{box-sizing:border-box}html{background:var(--paper)}
body{margin:0;font:18px/1.5 "EB Garamond",Georgia,serif;color:var(--ink);background:var(--paper)}
header{max-width:1120px;margin:0 auto;padding:56px 32px 24px}
header a.home{display:inline-flex;align-items:center;gap:10px;color:var(--ink);text-decoration:none;font-weight:500}
header a.home span{display:inline-block;width:14px;height:14px;border-radius:50%;background:var(--yellow)}
h1{font-size:clamp(40px,6vw,72px);font-weight:400;letter-spacing:-.01em;margin:24px 0 8px;line-height:1.05}
.lede{font-size:22px;color:var(--muted);max-width:44ch;margin:0}
.lede b{color:var(--ink);font-weight:500}
main{max-width:1120px;margin:0 auto;padding:16px 32px 96px;display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:28px}
.card{display:block;color:inherit;text-decoration:none;background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 1px 2px rgba(0,0,0,.06),0 12px 32px -18px rgba(0,0,0,.25);transition:transform .25s cubic-bezier(.2,.7,.2,1),box-shadow .25s}
.card:hover{transform:translateY(-3px);box-shadow:0 1px 2px rgba(0,0,0,.06),0 24px 44px -20px rgba(0,0,0,.3)}
.card img,.card .blank{display:block;width:100%;aspect-ratio:1200/630;object-fit:cover;background:linear-gradient(135deg,#f3f1ea,#e8e5da)}
.text{padding:18px 20px 20px}
h2{font-size:24px;font-weight:500;margin:0 0 6px;line-height:1.2}
.text p{margin:0 0 10px;color:var(--ink)}
.by{font-size:15px;color:var(--muted)}
.by::before{content:"— "}
.empty{grid-column:1/-1;color:var(--muted);font-size:22px;text-align:center;padding:80px 0}
footer{max-width:1120px;margin:0 auto;padding:0 32px 64px;color:var(--muted);font-size:16px}
footer a{color:inherit}
@media (prefers-color-scheme:dark){:root{--ink:#f2f1ec;--paper:#151513;--muted:#a3a19a}.card{background:#1f1f1c}}
</style></head>
<body>
<header>
  <a class="home" href="/tim/"><span></span>Tim</a>
  <h1>Showcase</h1>
  <p class="lede">Sites made with <b>Tim</b>, by the people who own them. Each one was submitted from inside the app and picked by hand.</p>
</header>
<main>${cards || empty}</main>
<footer>Made something with Tim? Choose <b>Page › Submit to Showcase…</b> in the app. · <a href="/tim/">About Tim</a></footer>
</body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=60" } });
}

// ---------- review ----------

function authorized(token, env) {
  if (!env.ADMIN_TOKEN) return false;
  const a = new TextEncoder().encode(String(token || "")), b = new TextEncoder().encode(env.ADMIN_TOKEN);
  if (a.length !== b.length) return false;
  let diff = 0; for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function admin(url, env) {
  if (!env.ADMIN_TOKEN) return new Response("Set ADMIN_TOKEN first: wrangler secret put ADMIN_TOKEN", { status: 503 });
  const token = url.searchParams.get("token");
  if (!authorized(token, env)) return new Response("Nope.", { status: 403 });
  const list = await env.SHOWCASE.list({ prefix: "pending:" });
  const pending = [];
  for (const k of list.keys) { const v = await env.SHOWCASE.get(k.name); if (v) pending.push(JSON.parse(v)); }
  pending.sort((a, b) => a.submitted < b.submitted ? 1 : -1);
  const live = await approved(env);
  const row = (e, actions) => `
    <li><img src="${esc(e.image)}" alt=""><div>
      <b>${esc(e.title)}</b> <a href="${esc(e.url)}" target="_blank">${esc(e.url)}</a><br>
      <i>${esc(e.note)}</i><br><small>${esc(e.name)} · ${esc(e.submitted.slice(0, 10))}</small>
      <form method="post" action="${BASE}/review"><input type="hidden" name="token" value="${esc(token)}"><input type="hidden" name="id" value="${esc(e.id)}">${actions}</form>
    </div></li>`;
  const html = `<!doctype html><meta charset="utf-8"><title>Showcase review</title>
<style>body{font:15px -apple-system,system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;color:#111}ul{list-style:none;padding:0}li{display:flex;gap:16px;padding:16px 0;border-bottom:1px solid #eee}img{width:200px;aspect-ratio:1200/630;object-fit:cover;background:#eee;border-radius:6px;flex:none}button{margin:8px 8px 0 0;padding:5px 12px;border-radius:6px;border:1px solid #ccc;background:#fff}button.go{background:#ffd60a;border-color:#e6c000;font-weight:600}h2{margin-top:40px}.notify{background:#faf9f6;border:1px solid #eee;border-radius:8px;padding:12px 14px;margin:0 0 8px}.notify i{color:#a00;font-style:normal}</style>
<h1>Showcase review</h1>
<p class="notify" id="notify">…</p>
<h2>Pending (${pending.length})</h2>
<ul>${pending.map(e => row(e, `<button class="go" name="action" value="approve">Approve</button><button name="action" value="reject">Reject</button>`)).join("") || "<li>Nothing waiting.</li>"}</ul>
<h2>Live (${live.length})</h2>
<ul>${live.map(e => row(e, `<button name="action" value="remove">Remove</button>`)).join("") || "<li>Nothing live.</li>"}</ul>
<script>
(function(){
  var BASE=${JSON.stringify(BASE)}, TOKEN=${JSON.stringify(token)},
      PUB=${JSON.stringify(env.VAPID_PUBLIC || "")}, READY=${pushReady(env)};
  var el=document.getElementById("notify");
  function say(h){ el.innerHTML=h; }
  if(!READY){ say("Notifications aren't set up on this server yet."); return; }
  if(!("serviceWorker" in navigator)||!("PushManager" in window)||!("Notification" in window)){
    say("This browser can't show notifications."); return; }
  if(location.protocol!=="https:"){ say("Notifications need a secure connection."); return; }

  function key(b64){
    var pad="====".slice(0,(4-b64.length%4)%4);
    var raw=atob((b64+pad).replace(/-/g,"+").replace(/_/g,"/"));
    var out=new Uint8Array(raw.length);
    for(var i=0;i<raw.length;i++) out[i]=raw.charCodeAt(i);
    return out;
  }
  async function existing(){
    try{ var r=await navigator.serviceWorker.getRegistration(BASE+"/");
      return r ? await r.pushManager.getSubscription() : null; }catch(e){ return null; }
  }
  async function on(){
    say("Asking your browser…");
    try{
      if(await Notification.requestPermission()!=="granted"){
        render(null,"Your browser is blocking notifications for this site."); return; }
      await navigator.serviceWorker.register(BASE+"/sw.js",{scope:BASE+"/"});
      var r=await navigator.serviceWorker.ready;
      var sub=await r.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:key(PUB)});
      var res=await fetch(BASE+"/subscribe",{method:"POST",
        headers:{"content-type":"application/json"},
        body:JSON.stringify({token:TOKEN,subscription:sub})});
      if(!res.ok) throw 0;
      var c=await caches.open("tim-showcase");
      await c.put("/__token",new Response(TOKEN));
      render(sub);
    }catch(e){ render(null,"Couldn't turn them on."); }
  }
  async function off(){
    say("…");
    try{
      var sub=await existing();
      if(sub){
        await fetch(BASE+"/unsubscribe",{method:"POST",
          headers:{"content-type":"application/json"},
          body:JSON.stringify({token:TOKEN,subscription:sub})});
        await sub.unsubscribe();
      }
      render(null);
    }catch(e){ render(null,"Couldn't turn them off."); }
  }
  function render(sub,err){
    var msg = err ? " <i>"+err+"</i>" : "";
    if(sub){
      say("Notifications are on in this browser. <button id=nb>Turn off</button>"+msg);
      document.getElementById("nb").onclick=off;
    } else {
      say("<button id=nb class=go>Notify me of new submissions</button>"+msg);
      document.getElementById("nb").onclick=on;
    }
  }
  existing().then(function(s){ render(s); });
})();
<\/script>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

async function review(request, env) {
  const form = await request.formData();
  const token = form.get("token");
  if (!authorized(token, env)) return new Response("Nope.", { status: 403 });
  const id = String(form.get("id") || ""), action = String(form.get("action") || "");
  let live = await approved(env);
  if (action === "approve") {
    const raw = await env.SHOWCASE.get("pending:" + id);
    if (raw) {
      const entry = JSON.parse(raw); entry.approved = new Date().toISOString();
      live = [entry, ...live.filter(e => e.id !== id)];
      await env.SHOWCASE.put("approved", JSON.stringify(live));
      await env.SHOWCASE.delete("pending:" + id);
    }
  } else if (action === "reject") {
    const raw = await env.SHOWCASE.get("pending:" + id);
    if (raw) { const entry = JSON.parse(raw); await env.SHOWCASE.delete("sub:" + await sha(entry.url)); }
    await env.SHOWCASE.delete("pending:" + id);
  } else if (action === "remove") {
    const entry = live.find(e => e.id === id);
    live = live.filter(e => e.id !== id);
    await env.SHOWCASE.put("approved", JSON.stringify(live));
    if (entry) await env.SHOWCASE.delete("sub:" + await sha(entry.url));
  }
  return Response.redirect(new URL(`${BASE}/admin?token=${encodeURIComponent(token)}`, request.url).href, 303);
}

// ---------- notifications ----------

// What the service worker asks for when a push wakes it. Same token as the
// review page: a notification is a view of pending work, so it needs the
// same key that unlocks the work itself.
async function pendingJSON(url, env) {
  if (!authorized(url.searchParams.get("token"), env)) return json({ error: "Nope." }, 403);
  const list = await env.SHOWCASE.list({ prefix: "pending:" });
  const entries = [];
  for (const k of list.keys) {
    const v = await env.SHOWCASE.get(k.name);
    if (v) entries.push(JSON.parse(v));
  }
  entries.sort((a, b) => a.submitted < b.submitted ? 1 : -1);
  const latest = entries[0];
  return json({
    count: entries.length,
    latest: latest ? { name: latest.name, title: latest.title, url: latest.url } : null,
  }, 200, { "cache-control": "no-store" });
}

async function subscribe(request, env, on) {
  if (!pushReady(env)) return json({ error: "Notifications aren't set up on this server yet." }, 503);
  let body;
  try { body = await request.json(); } catch { return json({ error: "Send JSON." }, 400); }
  if (!authorized(body.token, env)) return json({ error: "Nope." }, 403);
  const ok = on ? await saveSubscription(body.subscription, env)
                : await dropSubscription(body.subscription, env);
  if (!ok) return json({ error: "That isn't a push subscription." }, 400);
  return json({ ok: true });
}

// ---------- utils ----------

function json(obj, status = 200, headers = {}) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8", ...headers } });
}
function cors() { return { "access-control-allow-origin": "*", "access-control-allow-methods": "POST, OPTIONS", "access-control-allow-headers": "content-type" }; }
function esc(s) { return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
