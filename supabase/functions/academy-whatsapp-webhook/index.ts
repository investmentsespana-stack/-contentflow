import { createClient } from "@supabase/supabase-js";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const sb = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false, autoRefreshToken: false } });

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
});

function safeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function getConfig() {
  const { data, error } = await sb.from("academy_whatsapp_config").select("*").eq("id", 1).single();
  if (error) throw error;
  return data;
}

async function resolveAnswer(text: string) {
  const { data, error } = await sb.rpc("academy_whatsapp_resolve_answer", { p_text: text, p_language: "es" });
  if (error) throw error;
  return data as {
    intent: string;
    confidence: number;
    answer: string;
    knowledge_id: string;
    requires_human: boolean;
    source_type: string;
    source_ref: string;
    source_verified_at: string;
  };
}

async function upsertConversation(waId: string, displayName: string | null, intent: string, humanRequired: boolean) {
  const now = new Date().toISOString();
  const { data: existing } = await sb.from("academy_whatsapp_conversations")
    .select("id,status,human_required")
    .eq("wa_id", waId)
    .maybeSingle();

  if (existing?.id) {
    const nextStatus = humanRequired ? "human_required" : (existing.status === "closed" ? "open" : existing.status);
    const { data, error } = await sb.from("academy_whatsapp_conversations")
      .update({
        display_name: displayName ?? undefined,
        last_message_at: now,
        last_intent: intent,
        human_required: existing.human_required || humanRequired,
        status: nextStatus
      })
      .eq("id", existing.id)
      .select("id")
      .single();
    if (error) throw error;
    return data.id as string;
  }

  const { data, error } = await sb.from("academy_whatsapp_conversations")
    .insert({
      wa_id: waId,
      display_name: displayName,
      last_intent: intent,
      human_required: humanRequired,
      status: humanRequired ? "human_required" : "open",
      last_message_at: now
    })
    .select("id")
    .single();
  if (error) throw error;
  return data.id as string;
}

async function queueAndMaybeSend(
  conversationId: string,
  recipient: string,
  answer: string,
  knowledgeId: string | null,
  cfg: any
) {
  const { data: queued, error: qErr } = await sb.from("academy_whatsapp_outbox")
    .insert({
      conversation_id: conversationId,
      recipient_wa_id: recipient,
      body: answer,
      source_knowledge_id: knowledgeId,
      status: "pending"
    })
    .select("id")
    .single();
  if (qErr) throw qErr;

  const accessToken = Deno.env.get("WHATSAPP_ACCESS_TOKEN") ?? "";
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? cfg.phone_number_id ?? "";
  const graphVersion = Deno.env.get("META_GRAPH_VERSION") ?? "";

  if (!cfg.enabled) {
    await sb.from("academy_whatsapp_outbox")
      .update({ status: "blocked", last_error: "channel_disabled_until_meta_binding_complete" })
      .eq("id", queued.id);
    return { sent: false, reason: "channel_disabled" };
  }

  if (!accessToken || !phoneNumberId || !graphVersion) {
    await sb.from("academy_whatsapp_outbox")
      .update({ status: "blocked", last_error: "missing_access_token_phone_number_id_or_graph_version" })
      .eq("id", queued.id);
    return { sent: false, reason: "credentials_missing" };
  }

  const res = await fetch(`https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`, {
    method: "POST",
    headers: {
      "authorization": `Bearer ${accessToken}`,
      "content-type": "application/json"
    },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: recipient,
      type: "text",
      text: { preview_url: false, body: answer }
    })
  });

  const payload = await res.json().catch(() => ({}));
  if (!res.ok) {
    await sb.from("academy_whatsapp_outbox")
      .update({
        status: "failed",
        attempts: 1,
        last_error: `graph_${res.status}:${JSON.stringify(payload).slice(0, 500)}`
      })
      .eq("id", queued.id);
    return { sent: false, reason: `graph_${res.status}` };
  }

  const wamid = payload?.messages?.[0]?.id ?? null;
  await sb.from("academy_whatsapp_outbox")
    .update({
      status: "sent",
      attempts: 1,
      whatsapp_message_id: wamid,
      sent_at: new Date().toISOString(),
      last_error: null
    })
    .eq("id", queued.id);

  await sb.from("academy_whatsapp_messages").insert({
    conversation_id: conversationId,
    whatsapp_message_id: wamid,
    direction: "outbound",
    message_type: "text",
    body: answer,
    knowledge_id: knowledgeId,
    status: "sent",
    metadata: { transport: "meta_cloud_api" }
  });

  return { sent: true, wamid };
}

Deno.serve(async (req: Request) => {
  try {
    const url = new URL(req.url);

    if (req.method === "GET" && url.searchParams.get("health") === "1") {
      const cfg = await getConfig();
      return json({
        service: "academy-whatsapp-webhook",
        mode: "truth_first_verified_information",
        phone_e164: cfg.phone_e164,
        status: cfg.status,
        enabled: cfg.enabled,
        webhook_verified: cfg.webhook_verified,
        meta_binding: {
          waba_id_present: Boolean(cfg.waba_id),
          phone_number_id_present: Boolean(cfg.phone_number_id),
          access_token_configured: cfg.access_token_configured,
          app_secret_configured: cfg.app_secret_configured,
          verify_token_configured: cfg.verify_token_configured,
          graph_version_configured: cfg.graph_version_configured
        }
      });
    }

    if (req.method === "GET") {
      const mode = url.searchParams.get("hub.mode") ?? "";
      const token = url.searchParams.get("hub.verify_token") ?? "";
      const challenge = url.searchParams.get("hub.challenge") ?? "";
      const expected = Deno.env.get("WHATSAPP_VERIFY_TOKEN") ?? "";

      if (!expected) return new Response("verify token not configured", { status: 503 });

      if (mode === "subscribe" && safeEq(token, expected)) {
        await sb.from("academy_whatsapp_config").update({
          webhook_verified: true,
          verify_token_configured: true,
          last_verified_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        }).eq("id", 1);

        return new Response(challenge, {
          status: 200,
          headers: { "content-type": "text/plain" }
        });
      }

      return new Response("forbidden", { status: 403 });
    }

    if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

    const raw = await req.text();
    const appSecret = Deno.env.get("META_APP_SECRET") ?? "";
    const headerSig = req.headers.get("x-hub-signature-256") ?? "";

    if (!appSecret) return new Response("app secret not configured", { status: 503 });

    const expectedSig = `sha256=${await hmacHex(appSecret, raw)}`;
    if (!safeEq(headerSig, expectedSig)) return new Response("invalid signature", { status: 401 });

    await sb.from("academy_whatsapp_config").update({
      app_secret_configured: true,
      updated_at: new Date().toISOString()
    }).eq("id", 1);

    const payload = JSON.parse(raw || "{}");
    const cfg = await getConfig();
    let processed = 0;

    for (const entry of payload?.entry ?? []) {
      for (const change of entry?.changes ?? []) {
        const value = change?.value ?? {};
        const contacts = new Map<string, string>();
        for (const c of value?.contacts ?? []) contacts.set(c?.wa_id ?? "", c?.profile?.name ?? "");

        for (const st of value?.statuses ?? []) {
          if (!st?.id) continue;
          await sb.from("academy_whatsapp_outbox")
            .update({
              status: st.status === "failed" ? "failed" : "sent",
              last_error: st.status === "failed" ? JSON.stringify(st.errors ?? []).slice(0, 500) : null
            })
            .eq("whatsapp_message_id", st.id);
        }

        for (const msg of value?.messages ?? []) {
          const waId = msg?.from ?? "";
          const wamid = msg?.id ?? "";
          if (!waId || !wamid) continue;

          const { data: duplicate } = await sb.from("academy_whatsapp_messages")
            .select("id")
            .eq("whatsapp_message_id", wamid)
            .maybeSingle();
          if (duplicate?.id) continue;

          const body = msg?.type === "text" ? (msg?.text?.body ?? "") : "";
          const answer = body ? await resolveAnswer(body) : await resolveAnswer("unknown");
          const conversationId = await upsertConversation(
            waId,
            contacts.get(waId) || null,
            answer.intent,
            answer.requires_human
          );

          await sb.from("academy_whatsapp_messages").insert({
            conversation_id: conversationId,
            whatsapp_message_id: wamid,
            direction: "inbound",
            message_type: msg?.type ?? "unknown",
            body: body || null,
            intent: answer.intent,
            knowledge_id: answer.knowledge_id,
            confidence: answer.confidence,
            status: "received",
            metadata: {
              source_type: answer.source_type,
              source_ref: answer.source_ref,
              meta_timestamp: msg?.timestamp ?? null
            }
          });

          if (answer.requires_human) {
            await sb.from("academy_whatsapp_handoffs").insert({
              conversation_id: conversationId,
              reason: `truth_first:${answer.intent}`,
              user_question: body || `[${msg?.type ?? "non_text"}]`,
              metadata: { confidence: answer.confidence, source_ref: answer.source_ref }
            });
          }

          await queueAndMaybeSend(conversationId, waId, answer.answer, answer.knowledge_id, cfg);
          processed++;
        }
      }
    }

    return json({ ok: true, processed });
  } catch (error) {
    console.error("academy-whatsapp-webhook", error);
    return json({ ok: false, error: "internal_error" }, 500);
  }
});
