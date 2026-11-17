// =====================================================================
// RK Motorsport – Supabase Edge Function: economic-send
// Opretter fakturakladder i e-conomic for alle kørere, som teamchefen
// har godkendt på et løb. Kaldes fra appen (kun admin).
//
// Hemmeligheder (Supabase → Edge Functions → Secrets):
//   ECONOMIC_APP_SECRET     – X-AppSecretToken fra jeres e-conomic udvikler-app
//   ECONOMIC_GRANT_TOKEN    – X-AgreementGrantToken fra teamets e-conomic aftale
// SUPABASE_URL, SUPABASE_ANON_KEY og SUPABASE_SERVICE_ROLE_KEY findes automatisk.
//
// Body: { event_id: string, driver_ids?: string[] }  eller  { test: true }
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const ECO = "https://restapi.e-conomic.com";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function eco(path: string, init: RequestInit = {}) {
  const res = await fetch(ECO + path, {
    ...init,
    headers: {
      "X-AppSecretToken": Deno.env.get("ECONOMIC_APP_SECRET") ?? "",
      "X-AgreementGrantToken": Deno.env.get("ECONOMIC_GRANT_TOKEN") ?? "",
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    const msg = data?.message ?? data?.errorCode ?? res.statusText;
    const details = data?.errors ? " " + JSON.stringify(data.errors) : "";
    throw new Error(`e-conomic ${res.status}: ${msg}${details}`);
  }
  return data;
}

const round2 = (n: number) => Math.round(n * 100) / 100;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    // --- kun teamchefen (admin) må kalde funktionen
    const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: isAdmin, error: authErr } = await userClient.rpc("is_admin");
    if (authErr || !isAdmin) return json({ error: "Kun teamchefen kan sende til e-conomic" }, 403);

    const body = await req.json().catch(() => ({}));

    // --- forbindelsestest
    if (body.test) {
      const self = await eco("/self");
      return json({ ok: true, company: self?.company?.name ?? self?.agreementNumber });
    }

    const eventId: string = body.event_id;
    if (!eventId) return json({ error: "event_id mangler" }, 400);

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: settings } = await db.from("settings").select("*").eq("id", 1).single();
    const { data: event, error: evErr } = await db.from("events").select("*").eq("id", eventId).single();
    if (evErr || !event) return json({ error: "Løbet findes ikke" }, 404);

    let q = db.from("approvals").select("*, drivers(*)").eq("event_id", eventId).eq("status", "chief_approved");
    if (Array.isArray(body.driver_ids) && body.driver_ids.length) q = q.in("driver_id", body.driver_ids);
    const { data: approvals, error: apErr } = await q;
    if (apErr) throw apErr;

    const results: any[] = [];
    for (const ap of approvals ?? []) {
      const driver = ap.drivers;
      // Lås rækken atomisk, så et dobbeltklik ikke giver to kladder
      const { data: claimed } = await db.from("approvals").update({ status: "sending", error: null })
        .eq("event_id", eventId).eq("driver_id", ap.driver_id).eq("status", "chief_approved").select();
      if (!claimed?.length) continue;

      try {
        if (!driver.economic_customer_number) throw new Error("Køreren har intet e-conomic kundenummer");

        const { data: parts, error: pErr } = await db.from("parts_log")
          .select("*, products(economic_product_number)")
          .eq("event_id", eventId).eq("driver_id", ap.driver_id).order("created_at");
        if (pErr) throw pErr;
        if (!parts?.length) throw new Error("Ingen linjer");

        // Saml ens linjer (samme vare/tekst og pris)
        const merged = new Map<string, any>();
        for (const p of parts) {
          const key = (p.product_id ?? p.description.trim().toLowerCase()) + "|" + (p.unit_price ?? "");
          const m = merged.get(key);
          if (m) m.qty += Number(p.qty);
          else merged.set(key, { ...p, qty: Number(p.qty) });
        }

        const customer = await eco(`/customers/${driver.economic_customer_number}`);
        const layoutNumber = customer.layout?.layoutNumber ?? settings?.economic_layout_number;
        if (!layoutNumber) throw new Error("Intet layout – angiv standard-layout under e-conomic indstillinger");
        const defaultProduct = settings?.economic_product_number;
        const vatFactor = settings?.prices_incl_vat === false ? 1 : 1.25;

        const lines = [...merged.values()].map((l, i) => {
          const productNumber = l.products?.economic_product_number || defaultProduct;
          if (!productNumber) throw new Error("Intet varenummer – angiv standard-varenr. under e-conomic indstillinger");
          return {
            lineNumber: i + 1,
            sortKey: i + 1,
            product: { productNumber: String(productNumber) },
            description: l.description,
            quantity: l.qty,
            unitNetPrice: round2(Number(l.unit_price) / vatFactor),
          };
        });

        const draft = await eco("/invoices/drafts", {
          method: "POST",
          body: JSON.stringify({
            date: new Date().toISOString().slice(0, 10),
            currency: customer.currency ?? "DKK",
            customer: { customerNumber: customer.customerNumber },
            paymentTerms: { paymentTermsNumber: customer.paymentTerms.paymentTermsNumber },
            layout: { layoutNumber },
            recipient: {
              name: customer.name,
              address: customer.address,
              zip: customer.zip,
              city: customer.city,
              vatZone: { vatZoneNumber: customer.vatZone.vatZoneNumber },
            },
            notes: {
              heading: `Reservedele – ${event.name}`,
              textLine1: `Kører: ${driver.name}${driver.race_number ? " #" + driver.race_number : ""}`,
            },
            lines,
          }),
        });

        await db.from("approvals").update({
          status: "sent", economic_draft_number: draft.draftInvoiceNumber, sent_at: new Date().toISOString(), error: null,
        }).eq("event_id", eventId).eq("driver_id", ap.driver_id);
        await db.from("parts_log").update({ invoiced: true }).eq("event_id", eventId).eq("driver_id", ap.driver_id);
        results.push({ driver: driver.name, ok: true, draft: draft.draftInvoiceNumber });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        await db.from("approvals").update({ status: "chief_approved", error: msg })
          .eq("event_id", eventId).eq("driver_id", ap.driver_id);
        results.push({ driver: driver.name, ok: false, error: msg });
      }
    }
    return json({ results });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
