import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const normalizeError = (error: any) => ({ message: error?.message ?? String(error), code: error?.code ?? null, details: error?.details ?? null, hint: error?.hint ?? null });

Deno.serve(async (_req: Request) => {
  const headers = { "content-type": "application/json", "cache-control": "no-store" };
  const url = Deno.env.get("SUPABASE_URL");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !service) return new Response(JSON.stringify({ ok: false, error: "MISSING_RUNTIME_CONFIGURATION" }), { status: 500, headers });

  const sb = createClient(url, service, { auth: { persistSession: false } });
  const out: any = { architecture: "DIRECTOR_RECOVERY_SANDBOX_V1", steps: [] };

  try {
    const created = await sb.rpc("recovery_cert_create_task", { p_project_id: "contentflow", p_payload: { kind: "director-worker-recovery-cert" } });
    if (created.error) throw created.error;
    const taskId = created.data.task_id;
    out.taskId = taskId;
    out.steps.push({ step: "queued", state: created.data.state });

    const firstClaim = await sb.rpc("recovery_cert_claim_task", { p_task_id: taskId, p_worker_id: "worker-old", p_lease_seconds: 1 });
    if (firstClaim.error) throw firstClaim.error;
    out.steps.push({ step: "claim-old", fencing: firstClaim.data.fencing_token, lease: firstClaim.data.lease_id });

    await sleep(1300);
    const reconciled = await sb.rpc("recovery_cert_reconcile_task", { p_task_id: taskId });
    if (reconciled.error) throw reconciled.error;
    out.steps.push({ step: "reconcile", state: reconciled.data.state, error: reconciled.data.last_error, fencing: reconciled.data.fencing_token });

    const secondClaim = await sb.rpc("recovery_cert_claim_task", { p_task_id: taskId, p_worker_id: "worker-new", p_lease_seconds: 5 });
    if (secondClaim.error) throw secondClaim.error;
    out.steps.push({ step: "claim-new", fencing: secondClaim.data.fencing_token, lease: secondClaim.data.lease_id });

    const staleResponse = await fetch(`${url}/functions/v1/recovery-worker-sandbox`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-recovery-cert": "director-worker-e2e-v1" },
      body: JSON.stringify({ taskId, workerId: "worker-old", fencingToken: firstClaim.data.fencing_token, evidence: { kind: "stale-evidence" } }),
    });
    const stale = await staleResponse.json();
    out.steps.push({ step: "stale-result", http: staleResponse.status, payload: stale });

    const freshResponse = await fetch(`${url}/functions/v1/recovery-worker-sandbox`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-recovery-cert": "director-worker-e2e-v1" },
      body: JSON.stringify({ taskId, workerId: "worker-new", fencingToken: secondClaim.data.fencing_token, evidence: { kind: "recovery-proof", validated: true } }),
    });
    const fresh = await freshResponse.json();
    out.steps.push({ step: "fresh-result", http: freshResponse.status, payload: fresh });

    const final = await sb.rpc("recovery_cert_get_task", { p_task_id: taskId });
    if (final.error) throw final.error;
    out.final = final.data;

    const eventTypes = (final.data?.events ?? []).map((event: any) => event.event_type);
    const passed = final.data?.task?.state === "completed"
      && secondClaim.data.fencing_token === firstClaim.data.fencing_token + 1
      && stale?.result?.accepted === false
      && stale?.result?.reason === "STALE_WORKER"
      && fresh?.result?.accepted === true
      && eventTypes.includes("LeaseExpired")
      && eventTypes.includes("ResultRejected")
      && eventTypes.includes("TaskCompleted");

    out.ok = passed;
    out.profile = "director-worker-recovery-e2e-v1";
    return new Response(JSON.stringify(out), { status: passed ? 200 : 500, headers });
  } catch (error) {
    out.ok = false;
    out.error = normalizeError(error);
    return new Response(JSON.stringify(out), { status: 500, headers });
  }
});