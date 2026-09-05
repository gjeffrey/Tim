// Web push for the review page — so a submission finds you instead of
// waiting for you to remember to look.
//
// Notifications carry no encrypted payload. The push is a bare wake-up;
// the service worker then asks /pending.json what's waiting and writes
// the notification itself. That skips the aes128gcm payload encryption
// the spec allows but doesn't require, and the text stays current even
// if the push sat in a queue for an hour.

const b64u = buf => {
  const b = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const b64uText = str => b64u(new TextEncoder().encode(str));

// A VAPID token proves to the push service that this is the same server
// the browser subscribed to. Valid twelve hours; we mint one per send.
async function vapidAuth(endpoint, env) {
  const header = b64uText(JSON.stringify({ typ: "JWT", alg: "ES256" }));
  const claims = b64uText(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: env.VAPID_SUBJECT || "https://gabrieljeffrey.com/tim",
  }));
  const signing = header + "." + claims;
  const key = await crypto.subtle.importKey(
    "jwk", JSON.parse(env.VAPID_PRIVATE_JWK),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signing));
  return `vapid t=${signing}.${b64u(sig)}, k=${env.VAPID_PUBLIC}`;
}

export function pushReady(env) {
  return !!(env.VAPID_PRIVATE_JWK && env.VAPID_PUBLIC);
}

export async function saveSubscription(sub, env) {
  if (!sub || typeof sub.endpoint !== "string") return false;
  const id = b64uText(sub.endpoint).slice(0, 40);
  await env.SHOWCASE.put("push:" + id, JSON.stringify({ endpoint: sub.endpoint }));
  return true;
}

export async function dropSubscription(sub, env) {
  if (!sub || typeof sub.endpoint !== "string") return false;
  await env.SHOWCASE.delete("push:" + b64uText(sub.endpoint).slice(0, 40));
  return true;
}

// Wake every subscribed browser. A push service answers 404 or 410 when a
// subscription is dead — that's the only reliable signal we get, so we
// take it and forget the endpoint rather than retrying it forever.
export async function notifyAll(env) {
  if (!pushReady(env)) return;
  const list = await env.SHOWCASE.list({ prefix: "push:" });
  await Promise.all(list.keys.map(async k => {
    const raw = await env.SHOWCASE.get(k.name);
    if (!raw) return;
    const sub = JSON.parse(raw);
    try {
      const res = await fetch(sub.endpoint, {
        method: "POST",
        headers: { Authorization: await vapidAuth(sub.endpoint, env), TTL: "86400" },
      });
      if (res.status === 404 || res.status === 410) await env.SHOWCASE.delete(k.name);
    } catch {}
  }));
}

// Served at /tim/showcase/sw.js, so its scope covers the review page.
export function serviceWorker(base) {
  const js = `
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

async function token() {
  const c = await caches.open("tim-showcase");
  const r = await c.match("/__token");
  return r ? await r.text() : "";
}

self.addEventListener("push", e => e.waitUntil((async () => {
  let title = "New Showcase submission", body = "Open the review page to see it.";
  try {
    const res = await fetch("${base}/pending.json?token=" + encodeURIComponent(await token()));
    if (res.ok) {
      const d = await res.json();
      if (d.count > 1) title = d.count + " submissions waiting";
      if (d.latest) body = d.latest.name + " — " + d.latest.title;
    }
  } catch {}
  await self.registration.showNotification(title, {
    body, tag: "tim-showcase", renotify: true,
  });
})()));

self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil((async () => {
    const url = "${base}/admin?token=" + encodeURIComponent(await token());
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) if (c.url.includes("${base}/admin")) return c.focus();
    return self.clients.openWindow(url);
  })());
});`;
  return new Response(js, {
    headers: { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-store" },
  });
}
