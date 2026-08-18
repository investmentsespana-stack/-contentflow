import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = { "content-type": "application/json", "cache-control": "no-store" };
const PROJECT_ID = "contentflow";

function condition(type: string, status: "True" | "False" | "Unknown", reason: string, message: string, severity: "info" | "warning" | "critical", observedGeneration: number) {
  return { type, status, reason, message, severity, observedGeneration, lastTransitionTime: new Date().toISOString() };
}

Deno.serve(async (req) => {
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ ok: false, error: "OBSERVE_ONLY_GET_REQUIRED" }), { status: 405, headers });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !service) {
    return new Response(JSON.stringify({ ok: false, error: "MISSING_RUNTIME_CONFIGURATION" }), { status: 500, headers });
  }

  const sb = createClient(url, service, { auth: { persistSession: false } });
  const now = new Date().toISOString();
  const conditions: Array<Record<string, unknown>> = [];
  const probeErrors: Record<string, string> = {};

  let generation = 1;
  let concurrencyLimit = 2;
  let lifecycleState = "running";
  let reviewRequired = 0;
  let openIncidents = 0;
  let latestCycle: Record<string, unknown> | null = null;

  try {
    const policy = await sb.from("director_control_policy").select("*").eq("project_key", PROJECT_ID).maybeSingle();
    if (policy.error) throw policy.error;
    const row = (policy.data || {}) as Record<string, unknown>;
    generation = Number(row.generation ?? row.version ?? 1) || 1;
    concurrencyLimit = Number(row.max_parallel ?? row.desired_running_workers ?? row.concurrency_limit ?? 2) || 2;
    lifecycleState = String(row.lifecycle_state ?? (row.enabled === false ? "paused" : "running"));
    conditions.push(condition("PolicyReadable", "True", "PolicyObserved", "Director control policy was observed without mutation.", "info", generation));
  } catch (e) {
    probeErrors.policy = String(e);
    conditions.push(condition("PolicyReadable", "Unknown", "PolicyProbeFailed", "Director policy could not be observed.", "warning", generation));
  }

  try {
    const reviews = await sb.from("contentflow_builder_runs").select("id", { count: "exact", head: true }).eq("status", "review_required");
    if (reviews.error) throw reviews.error;
    reviewRequired = Number(reviews.count || 0);
    conditions.push(condition("ReviewGate", reviewRequired > 0 ? "False" : "True", reviewRequired > 0 ? "ReviewRequired" : "NoPendingReview", `${reviewRequired} run(s) require review.`, reviewRequired > 0 ? "warning" : "info", generation));
  } catch (e) {
    probeErrors.reviews = String(e);
    conditions.push(condition("ReviewGate", "Unknown", "ReviewProbeFailed", "Review state could not be observed.", "warning", generation));
  }

  try {
    const incidents = await sb.from("director_repair_incidents").select("id", { count: "exact", head: true }).eq("project_key", PROJECT_ID).in("status", ["open", "analyzing"]);
    if (incidents.error) throw incidents.error;
    openIncidents = Number(incidents.count || 0);
    conditions.push(condition("RecoveryRequired", openIncidents > 0 ? "True" : "False", openIncidents > 0 ? "OpenRepairIncident" : "NoOpenRepairIncident", `${openIncidents} open/analyzing repair incident(s).`, openIncidents > 0 ? "warning" : "info", generation));
  } catch (e) {
    probeErrors.incidents = String(e);
    conditions.push(condition("RecoveryRequired", "Unknown", "IncidentProbeFailed", "Repair incident state could not be observed.", "warning", generation));
  }

  try {
    const cycle = await sb.from("director_cycle_runs").select("*").eq("project_key", PROJECT_ID).order("id", { ascending: false }).limit(1).maybeSingle();
    if (cycle.error) throw cycle.error;
    latestCycle = (cycle.data || null) as Record<string, unknown> | null;
    conditions.push(condition("Progressing", latestCycle ? "True" : "Unknown", latestCycle ? "CycleObserved" : "NoCycleObserved", latestCycle ? "Latest Director cycle is observable." : "No Director cycle was returned.", latestCycle ? "info" : "warning", generation));
  } catch (e) {
    probeErrors.cycle = String(e);
    conditions.push(condition("Progressing", "Unknown", "CycleProbeFailed", "Director cycle state could not be observed.", "warning", generation));
  }

  const criticalFalse = conditions.some((c) => c.severity === "critical" && c.status === "False");
  const warningOrUnknown = conditions.some((c) => c.severity === "warning" || c.status === "Unknown");
  const health = criticalFalse ? "Unhealthy" : warningOrUnknown || openIncidents > 0 || reviewRequired > 0 ? "Degraded" : "Healthy";

  return new Response(JSON.stringify({
    ok: true,
    contract: { schemaName: "standard-director-contract", apiVersion: "v1", contractVersion: "1.0.0", mode: "observe-only" },
    metadata: { directorId: "contentflow-director", projectId: PROJECT_ID, projectType: "software-orchestration", environment: "experimental", generation },
    spec: { lifecycleState, autonomyLevel: "bounded-autonomous", capacity: { concurrencyLimit } },
    status: { phase: lifecycleState, health, observedGeneration: generation, lastObservedAt: now, reviewRequired, openIncidents, latestCycle },
    conditions,
    capabilities: { supportedTaskClasses: ["software-build", "qa-review", "runtime-recovery"], acceptedCommands: [] },
    security: { projectBoundary: PROJECT_ID, allowedScopes: ["observe"], crossProjectAccess: false },
    observability: { traceable: true, evidenceBacked: true, probeErrors },
    recovery: { failurePolicyProfile: "director-recovery-v1", leaseFencingRequired: true, evidenceRequiredForCompletion: true, checkpointStrategy: "last-safe-state" },
    compatibility: { minMasterContractVersion: "1.0.0", maxMasterContractVersion: "1.x" }
  }), { status: 200, headers });
});
