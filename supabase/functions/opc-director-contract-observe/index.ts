import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const headers = { "content-type": "application/json", "cache-control": "no-store" };

Deno.serve((req) => {
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ ok: false, error: "OBSERVE_ONLY_GET_REQUIRED" }), { status: 405, headers });
  }

  const now = new Date().toISOString();
  const generation = 1;
  return new Response(JSON.stringify({
    ok: true,
    contract: { schemaName: "standard-director-contract", apiVersion: "v1", contractVersion: "1.0.0", mode: "observe-only" },
    metadata: { directorId: "opc-director", projectId: "opc", projectType: "autonomous-business", environment: "sandbox", generation },
    spec: { lifecycleState: "bootstrap", autonomyLevel: "bounded-autonomous", capacity: { concurrencyLimit: 0 } },
    status: { phase: "bootstrap", health: "Healthy", observedGeneration: generation, lastObservedAt: now, executable: false },
    conditions: [
      { type: "Ready", status: "False", reason: "BootstrapNotExecutable", message: "External execution is disabled until conformance and sandbox recovery gates pass.", severity: "info", observedGeneration: generation, lastTransitionTime: now },
      { type: "Isolated", status: "True", reason: "IndependentProjectBoundary", message: "OPC has no direct ContentFlow state, memory, tools or credentials.", severity: "info", observedGeneration: generation, lastTransitionTime: now }
    ],
    capabilities: { supportedTaskClasses: ["lead-management", "qualification", "sales", "crm", "customer-support", "business-operations"], acceptedCommands: [] },
    security: { projectBoundary: "opc", allowedScopes: ["observe"], crossProjectAccess: false },
    observability: { traceable: true, evidenceBacked: true, dataSource: "bootstrap-static-contract" },
    recovery: { failurePolicyProfile: "director-recovery-v1", leaseFencingRequired: true, evidenceRequiredForCompletion: true, checkpointStrategy: "last-safe-state" },
    compatibility: { minMasterContractVersion: "1.0.0", maxMasterContractVersion: "1.x" }
  }), { status: 200, headers });
});
