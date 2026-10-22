// Latino Built Playbook: offline support.
// The page itself stays encrypted; this only keeps a copy on the phone so it opens without signal.
const CACHE = "lb-playbook-v1";
const CORE = ["./", "./index.html", "./manifest.json", "./icon-192.png", "./icon-512.png", "./apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

function timeout(ms) { return new Promise((_, rej) => setTimeout(() => rej(new Error("slow")), ms)); }

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  // The playbook page: try the network first (so updates show up), fall back to the saved copy.
  if (req.mode === "navigate" && url.origin === location.origin && !url.pathname.includes("/bids/")) {
    e.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const net = fetch(req, { cache: "no-store" }).then(r => { if (r.ok) cache.put("./index.html", r.clone()); return r; });
      try { return await Promise.race([net, timeout(4000)]); }
      catch (err) {
        const saved = await cache.match("./index.html");
        if (saved) { net.catch(() => {}); return saved; }
        return net;
      }
    })());
    return;
  }

  // Icons and fonts: use the saved copy, refresh it in the background.
  const sameStatic = url.origin === location.origin && /\.(png|json)$/.test(url.pathname) && !url.pathname.includes("/bids/");
  const fonts = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (sameStatic || fonts) {
    e.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req);
      const net = fetch(req).then(r => { if (r.ok || r.type === "opaque") cache.put(req, r.clone()); return r; }).catch(() => hit);
      return hit || net;
    })());
  }
  // Everything else (bid board, team board, calendars, videos) goes straight to the internet.
});
