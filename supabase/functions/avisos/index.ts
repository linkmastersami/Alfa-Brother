// Función "avisos" de Alfa Brother (Supabase Edge Function).
// Manda las notificaciones al celular de los jugadores.
//
// - GET  → regresa la llave pública para suscribirse. La primera vez crea las
//          llaves solita y las guarda en la tabla push_ajustes.
// - POST → la base de datos la llama cuando hay algo nuevo en el juego.
//          Solo funciona con la clave secreta que vive en push_ajustes.
//
// Al publicarla, apaga "Verify JWT" (los celulares la llaman sin iniciar sesión).

import webpush from "npm:web-push@3.6.7";

const BASE = Deno.env.get("SUPABASE_URL")!;
const LLAVE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (d: unknown, status = 200) =>
  new Response(JSON.stringify(d), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function rest(ruta: string, init: RequestInit = {}) {
  const r = await fetch(`${BASE}/rest/v1/${ruta}`, {
    ...init,
    headers: { apikey: LLAVE, Authorization: `Bearer ${LLAVE}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}

type Ajustes = { vapid_publica: string; vapid_privada: string; clave: string; funcion_url: string };

async function ajustes(): Promise<Ajustes> {
  let [a] = await rest("push_ajustes?id=eq.1&select=*");
  if (!a?.vapid_publica || !a?.vapid_privada || !a?.clave || !a?.funcion_url) {
    const v = webpush.generateVAPIDKeys();
    const par = a?.vapid_publica && a?.vapid_privada ? { vapid_publica: a.vapid_publica, vapid_privada: a.vapid_privada }
      : { vapid_publica: v.publicKey, vapid_privada: v.privateKey };
    const fila = { id: 1, ...par, clave: a?.clave || crypto.randomUUID(), funcion_url: `${BASE}/functions/v1/avisos` };
    if (a) await rest("push_ajustes?id=eq.1", { method: "PATCH", body: JSON.stringify(fila) });
    // si dos celulares llegan al mismo tiempo, se queda la primera fila
    else await rest("push_ajustes", { method: "POST", headers: { Prefer: "resolution=ignore-duplicates,return=minimal" }, body: JSON.stringify(fila) });
    [a] = await rest("push_ajustes?id=eq.1&select=*");
  }
  return a;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const a = await ajustes();
    if (req.method === "GET") return json({ publica: a.vapid_publica });
    if (req.method !== "POST") return json({ error: "METODO" }, 405);
    if (req.headers.get("x-clave") !== a.clave) return json({ error: "NO_AUTORIZADO" }, 401);

    const { titulo, cuerpo, solo, url } = await req.json();
    webpush.setVapidDetails("mailto:produccion@alfabrother.app", a.vapid_publica, a.vapid_privada);

    const ids = Array.isArray(solo) ? solo.filter((x) => /^[0-9a-f-]{36}$/i.test(String(x))) : [];
    const filtro = ids.length ? `&jugador_id=in.(${ids.join(",")})` : "";
    const subs: { endpoint: string; sub: webpush.PushSubscription }[] = await rest(`push_subs?select=endpoint,sub${filtro}`);
    const datos = JSON.stringify({ titulo: String(titulo || "Alfa Brother"), cuerpo: String(cuerpo || ""), url: url || "./" });

    let enviados = 0;
    const vencidos: string[] = [];
    await Promise.all(subs.map(async (s) => {
      try {
        // web-push solo cifra y firma; el envío va con fetch (más estable en Deno)
        const d = webpush.generateRequestDetails(s.sub, datos, { TTL: 43200, urgency: "high" });
        const r = await fetch(d.endpoint, { method: d.method, headers: d.headers as Record<string, string>, body: d.body ? new Uint8Array(d.body) : undefined });
        await r.body?.cancel();
        if (r.ok) enviados++;
        else if (r.status === 404 || r.status === 410) vencidos.push(s.endpoint);   // el celular ya no existe o quitó el permiso
        else console.error("aviso fallido", r.status, s.endpoint.slice(0, 60));
      } catch (e) {
        console.error("aviso fallido", String(e));
      }
    }));
    if (vencidos.length) {
      const lista = vencidos.map((v) => `"${v.replace(/"/g, '\\"')}"`).join(",");
      await rest(`push_subs?endpoint=in.(${encodeURIComponent(lista)})`, { method: "DELETE" });
    }
    return json({ enviados, borrados: vencidos.length, total: subs.length });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
