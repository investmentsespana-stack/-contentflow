import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "GET, OPTIONS",
};

Deno.serve(async (req: Request) => {
  const headers = { ...cors, "content-type": "application/json", "cache-control": "no-store" };
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "GET") return new Response(JSON.stringify({ ok:false, error:"GET required" }), { status:405, headers });

  const auth = req.headers.get("Authorization") || "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const sb = createClient(url, anon, { global:{ headers:{ Authorization:auth } } });
  const { data:{ user } } = await sb.auth.getUser();
  if (!user) return new Response(JSON.stringify({ ok:false, error:"unauthorized" }), { status:401, headers });

  const u = new URL(req.url);
  const generationId = String(u.searchParams.get("generation_id") || "").trim();
  if (!generationId) return new Response(JSON.stringify({ ok:false, error:"generation_id required" }), { status:400, headers });

  const { data:g, error } = await sb.from("generations")
    .select("id,project_id,status,model,quality_score,actual_cost_usd,orchestrator_run_id,output_json,created_at")
    .eq("id", generationId).maybeSingle();
  if (error) return new Response(JSON.stringify({ ok:false, error:"generation_lookup_failed" }), { status:500, headers });
  if (!g) return new Response(JSON.stringify({ ok:false, error:"not_found" }), { status:404, headers });

  const output = (g.output_json && typeof g.output_json === "object") ? g.output_json : {};
  const terminal = ["completed","failed","blocked"].includes(String(g.status));
  const retryAfterMs = terminal ? 0 : 2000;
  return new Response(JSON.stringify({
    ok:true, generationId:g.id, projectId:g.project_id, status:g.status,
    terminal, retryAfterMs,
    selectedModel:g.model, qualityScore:Number(g.quality_score || 0),
    totalCostUsd:Number(g.actual_cost_usd || 0), orchestratorRunId:g.orchestrator_run_id,
    result:(output as any).final_result ?? (output as any).result ?? null,
    error:(output as any).error ?? null, createdAt:g.created_at
  }), { status:200, headers });
});