// Service worker de Alfa Brother.
// Siempre intenta traer la versión más nueva de internet; la copia guardada
// solo se usa si no hay conexión. Así las actualizaciones llegan de inmediato.
const CACHE = 'alfa-brother-v2';
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

// Avisos al celular: llegan aunque el juego esté cerrado
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { cuerpo: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'Alfa Brother', {
    body: d.cuerpo || '',
    icon: 'iconos/icono-192.png',
    tag: 'alfa-brother',
    renotify: true,
    data: { url: d.url || './' },
  }));
});

// Tocar el aviso abre el juego (o lo trae al frente si ya está abierto)
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(ventanas => {
    const v = ventanas.find(w => w.url.startsWith(self.registration.scope));
    return v ? v.focus() : self.clients.openWindow(e.notification.data?.url || './');
  }));
});
