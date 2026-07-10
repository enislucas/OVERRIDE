/* OVERRIDE web // service worker — offline cache so the alarm has NO overnight
   network dependency. IDENTICAL file in v7/v8/v9 (assets are scope-relative;
   cache entries are keyed by full URL so the versions never collide). The alarm
   itself runs in the foreground page — a SW cannot run a background alarm. */
var CACHE = 'override-web-v10-4';
var ASSETS = [
  './index.html', './app.js', './core.js', './style.css', './alarm.css', './phone.css',
  './silence.wav', './alarm.wav', './manifest.webmanifest', './apple-touch-icon.png',
  './icons/icon-192.png', './icons/icon-512.png'
];

self.addEventListener('install', function (e) {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(ASSETS.map(function (a) { return new Request(a, { cache: 'reload' }); })); }).catch(function () {}));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.map(function (k) { if (k !== CACHE) return caches.delete(k); }));
    }).then(function () { return self.clients.claim(); })
  );
});
self.addEventListener('fetch', function (e) {
  if (e.request.method !== 'GET') return;
  e.respondWith(
    caches.match(e.request).then(function (r) {
      return r || fetch(e.request).then(function (resp) {
        try {
          var copy = resp.clone();
          caches.open(CACHE).then(function (c) { c.put(e.request, copy); });
        } catch (x) {}
        return resp;
      }).catch(function () { return caches.match('./index.html'); });
    })
  );
});
