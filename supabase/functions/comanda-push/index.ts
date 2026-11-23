// DL COMANDA PRO · envía avisos push aunque la app esté cerrada
// La llama la base de datos (trigger avisar_push) cuando entra un pedido, queda listo o se cancela.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

let cfg: Record<string, string> | null = null;
async function config() {
  if (cfg) return cfg;
  const { data, error } = await sb.from("config_privada").select("clave,valor");
  if (error) throw error;
  cfg = Object.fromEntries((data || []).map((r) => [r.clave, r.valor]));
  webpush.setVapidDetails(cfg.vapid_subject, cfg.vapid_public, cfg.vapid_private);
  return cfg;
}

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let c: Record<string, string>;
  try { c = await config(); } catch (e) { return json({ error: "config", detail: String(e) }, 500); }
  if (req.headers.get("x-hook-secret") !== c.hook_secret) return json({ error: "unauthorized" }, 401);

  const { tipo, pedido_id, mesa_id } = await req.json().catch(() => ({}));
  if (tipo === "cuenta" && mesa_id) return await avisarCuenta(mesa_id);
  if (!tipo || !pedido_id) return json({ error: "datos" }, 400);

  const { data: p } = await sb.from("pedidos").select("*,pedido_items(nombre,cant)").eq("id", pedido_id).maybeSingle();
  if (!p) return json({ ok: true, enviados: 0 });

  const items = (p.pedido_items || []).map((i: { cant: number; nombre: string }) => `${i.cant}× ${i.nombre}`).join(", ");
  let q = sb.from("push_subs").select("id,user_id,personal_id,rol,endpoint,p256dh,auth").eq("empresa_id", p.empresa_id);
  let msg: { title: string; body: string; tag: string; urgente?: boolean };

  if (tipo === "nuevo") {
    q = q.eq("rol", "cocina").eq("cocina", true).or(`estacion.is.null,estacion.eq.${p.estacion === "bar" ? "bar" : "cocina"}`);
    const est = p.estacion === "bar" ? "🍹 BAR · " : "";
    msg = { title: `🔔 ${est}Nuevo pedido #${p.numero} · ${p.mesa}`, body: `${p.mesero}: ${items}`.slice(0, 180), tag: `nuevo-${p.id}` };
  } else if (tipo === "listo") {
    q = p.mesero_id ? q.eq("personal_id", p.mesero_id) : q.eq("rol", "dueno");
    msg = { title: p.estacion === "bar" ? `🍹 Bebidas #${p.numero} listas · ${p.mesa}` : `🍽️ Pedido #${p.numero} listo · ${p.mesa}`, body: `Pasa por ${p.estacion === "bar" ? "el bar" : "la cocina"} a recogerlo. ${items}`.slice(0, 180), tag: `listo-${p.id}`, urgente: true };
  } else if (tipo === "cancelado") {
    if (!p.mesero_id) return json({ ok: true, enviados: 0 });
    q = q.eq("personal_id", p.mesero_id);
    msg = { title: `❌ Cocina canceló el pedido #${p.numero} · ${p.mesa}`, body: items.slice(0, 180), tag: `cancelado-${p.id}` };
  } else return json({ error: "tipo" }, 400);

  const { data: subs } = await q;
  if (!subs?.length) return json({ ok: true, enviados: 0 });

  return await enviar(subs, p.empresa_id, msg, tipo === "listo" ? 900 : 1800);
});

// Mesa pide la cuenta → avisa a quien tiene la función de caja
async function avisarCuenta(mesa_id: string) {
  const { data: m } = await sb.from("mesas").select("id,empresa_id,nombre,cuenta_en,cuenta_propina,cuenta_por").eq("id", mesa_id).maybeSingle();
  if (!m || !m.cuenta_en) return json({ ok: true, enviados: 0 });
  const { data: ps } = await sb.from("pedidos").select("total").eq("mesa_id", m.id).eq("pagado", false).neq("estado", "cancelado");
  const sub = (ps || []).reduce((a: number, p: { total: number }) => a + p.total, 0);
  const prop = m.cuenta_propina ? Math.round(sub * 0.1) : 0;
  const fmt = (n: number) => "$" + n.toLocaleString("es-CO");
  const { data: subs } = await sb.from("push_subs").select("id,user_id,personal_id,rol,endpoint,p256dh,auth").eq("empresa_id", m.empresa_id).eq("rol", "cocina").eq("caja", true);
  if (!subs?.length) return json({ ok: true, enviados: 0 });
  return await enviar(subs, m.empresa_id, {
    title: `🧾 ${m.nombre} pide la cuenta · ${fmt(sub + prop)}`,
    body: `${m.cuenta_por || "Mesero"}: ${m.cuenta_propina ? `el cliente ACEPTA la propina voluntaria (${fmt(prop)})` : "el cliente NO desea propina"}`,
    tag: `cuenta-${m.id}`, urgente: true,
  }, 1800);
}

type Sub = { id: number; user_id: string; personal_id: string | null; rol: string; endpoint: string; p256dh: string; auth: string };
async function enviar(subs: Sub[], empresa_id: string, msg: Record<string, unknown>, ttl: number) {
  const { data: perf } = await sb.from("perfiles").select("user_id,empresa_id").in("user_id", subs.map((s) => s.user_id));
  const vivos = new Set((perf || []).filter((x) => x.empresa_id === empresa_id).map((x) => x.user_id));
  const payload = JSON.stringify({ ...msg, url: "./" });
  let enviados = 0;
  const muertos: number[] = [];
  await Promise.all(subs.filter((s) => vivos.has(s.user_id)).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
        { TTL: ttl, urgency: "high" });
      enviados++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) muertos.push(s.id);
    }
  }));
  const huerfanos = subs.filter((s) => !vivos.has(s.user_id)).map((s) => s.id);
  if (muertos.length || huerfanos.length) await sb.from("push_subs").delete().in("id", [...muertos, ...huerfanos]);
  return json({ ok: true, enviados });
}
