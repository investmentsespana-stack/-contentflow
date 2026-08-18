import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  const headers = { "content-type": "application/json", "cache-control": "no-store" };
  if (req.method !== "POST") return new Response(JSON.stringify({ ok: false, error: "POST_REQUIRED" }), { status: 405, headers });
  if (req.headers.get("x-recovery-cert") !== "director-worker-e2e-v1") return new Response(JSON.stringify({ ok: false, error: "CERT_HEADER_REQUIRED" }), { status: 403, headers });

  const url = Deno.env.get("SUPABASE_URL");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !service) return new Response(JSON.stringify({ ok: false, error: "MISSING_RUNTIME_CONFIGURATION" }), { status: 500, headers });

  const body = await req.json().catch(() => ({}));
  const { taskId, workerId, fencingToken, evidence, delayMs = 0 } = body;
  if (!taskId || !workerId || !Number.isInteger(fencingToken)) return new Response(JSON.stringify({ ok: false, error: "INVALID_INPUT" }), { status: 400, headers });
  if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, Math.min(Number(delayMs), 5000)));

  const sb = createClient(url, service, { auth: { persistSession: false } });
  const result = await sb.rpc("recovery_cert_submit_result", {
    p_task_id: taskId,
    p_worker_id: workerId,
    p_fencing_token: fencingToken,
    p_evidence: evidence ?? {},
  });

  if (result.error) return new Response(JSON.stringify({ ok: false, error: result.error.message }), { status: 500, headers });
  return new Response(JSON.stringify({ ok: true, workerId, fencingToken, result: result.data }), { status: 200, headers });
});