// Service worker de Alfa Brother.
// Siempre intenta traer la versión más nueva de internet; la copia guardada
// solo se usa si no hay conexión. Así las actualizaciones llegan de inmediato.
const CACHE = 'alfa-brother-v3';
const BASICOS = ['./', './index.html', './manifest.webmanifest', './iconos/icono-192.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(BASICOS)).catch(() => {}));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

// Una respuesta que vino de una redirección no se puede usar para abrir la página: se copia "limpia"
const limpia = res => res && res.redirected
  ? res.blob().then(b => new Response(b, { status: res.status, statusText: res.statusText, headers: res.headers }))
  : res;

// Si no hay internet ni copia guardada: una pantalla que reintenta sola (en lugar del error del navegador)
const SIN_RED = `<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Alfa Brother</title><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#1B1440;color:#fff;font-family:system-ui,sans-serif;text-align:center;padding:24px">
<div><div style="font-size:3rem">📡</div><h1 style="font-size:1.4rem">No se pudo abrir Alfa Brother</h1>
<p style="color:#C9C3EE">Revisa tu internet. Volvemos a intentar en unos segundos…</p>
<button onclick="location.reload()" style="margin-top:12px;border:0;border-radius:999px;padding:12px 22px;font-weight:700;background:#FFD54A;color:#1B1440">Reintentar</button></div>
<script>setTimeout(() => location.reload(), 5000)</script></body></html>`;

const conTiempo = (p, ms) => Promise.race([p, new Promise((_, no) => setTimeout(() => no(new Error('tiempo')), ms))]);

self.addEventListener('fetch', e => {
  const req = e.request;
  const url = new URL(req.url);
  // Solo archivos propios del juego; Supabase y fuentes van directo a internet.
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  const pagina = req.mode === 'navigate';
  e.respondWith((async () => {
    try {
      const res = await conTiempo(fetch(req), pagina ? 10000 : 15000);
      if (res && res.ok && res.type === 'basic') {
        const copia = res.clone();
        caches.open(CACHE).then(c => c.put(pagina ? './index.html' : req, copia)).catch(() => {});
      }
      return await limpia(res);
    } catch {
      const guardada = (await caches.match(req, { ignoreSearch: true }).catch(() => null))
        || (pagina ? await caches.match('./index.html').catch(() => null) : null);
      if (guardada) return await limpia(guardada);
      if (pagina) return new Response(SIN_RED, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      return Response.error();
    }
  })());
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
