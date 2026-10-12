// Service worker de Alfa Brother.
// Siempre intenta traer la versión más nueva de internet; la copia guardada
// solo se usa si no hay conexión. Así las actualizaciones llegan de inmediato.
const CACHE = 'alfa-brother-v1';
const BASICOS = ['./', './index.html', './manifest.webmanifest', './iconos/icono-192.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(BASICOS)).catch(() => {}));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const req = e.request;
  const url = new URL(req.url);
  // Solo archivos propios del juego; Supabase y fuentes van directo a internet.
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  e.respondWith(
    fetch(req)
      .then(res => {
        const copia = res.clone();
        caches.open(CACHE).then(c => c.put(req, copia)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
  );
});
