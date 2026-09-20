import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const H={"content-type":"application/json","cache-control":"no-store"};
const json=(b:unknown,s=200)=>new Response(JSON.stringify(b),{status:s,headers:H});
const PROJECTS:Record<string,{key:string,name:string,repo?:string}>={
  contentflow:{key:"contentflow",name:"ContentFlow / Director",repo:"investmentsespana-stack/-contentflow"},
  avatar:{key:"avatar-platform-v1",name:"Avatar",repo:"investmentsespana-stack/avatar-platform"},
  academy:{key:"agent-academy-platform-v1",name:"Cygnus Academy / Skool",repo:"investmentsespana-stack/-contentflow"},
};
async function sha256(t:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(t));return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("")}
function resolveProject(v:unknown){const s=String(v||"contentflow").toLowerCase();if(s.includes("avatar"))return {id:"avatar",...PROJECTS.avatar};if(/academy|academia|skool|cygnus/.test(s))return {id:"academy",...PROJECTS.academy};return {id:"contentflow",...PROJECTS.contentflow}}
async function github(repo:string){
  const token=Deno.env.get("GITHUB_TOKEN")||Deno.env.get("GH_TOKEN")||"";
  const observedAt=new Date().toISOString();
  if(!token)return {source:"github",freshness:"UNAVAILABLE",observedAt,repository:repo,error:"GITHUB_TOKEN_NOT_CONFIGURED_IN_GATEWAY"};
  const headers={accept:"application/vnd.github+json",authorization:`Bearer ${token}`,"user-agent":"jarvis-project-state-gateway"};
  const day=new Date();day.setUTCHours(0,0,0,0);const since=day.toISOString();
  async function get(path:string){const c=new AbortController();const tm=setTimeout(()=>c.abort(),10000);try{const r=await fetch(`https://api.github.com/repos/${repo}${path}`,{headers,signal:c.signal});const t=await r.text();let d:any={};try{d=t?JSON.parse(t):{}}catch{d={raw:t}};if(!r.ok)throw new Error(`HTTP ${r.status}: ${String(d?.message||t).slice(0,180)}`);return d}finally{clearTimeout(tm)}}
  try{
    const [runs,head,commits]=await Promise.all([get("/actions/runs?per_page=100"),get("/commits/main"),get(`/commits?sha=main&since=${encodeURIComponent(since)}&per_page=100`)]);
    const today=(runs.workflow_runs||[]).filter((r:any)=>Date.parse(r.created_at||0)>=day.getTime());
    return {source:"github",freshness:"LIVE_QUERY",observedAt,repository:repo,head:{sha:head.sha,message:head.commit?.message,date:head.commit?.committer?.date||head.commit?.author?.date},runsToday:today.map((r:any)=>({id:r.id,name:r.name,run_number:r.run_number,status:r.status,conclusion:r.conclusion,head_sha:r.head_sha,created_at:r.created_at,updated_at:r.updated_at,html_url:r.html_url})),commitsToday:(commits||[]).map((c:any)=>({sha:c.sha,message:c.commit?.message,date:c.commit?.committer?.date||c.commit?.author?.date,html_url:c.html_url}))};
  }catch(e){return {source:"github",freshness:"ERROR",observedAt,repository:repo,error:String((e as Error)?.message||e)}}
}

Deno.serve(async(req:Request)=>{
  if(req.method!=="POST")return json({ok:false,error:"POST required"},405);
  const url=Deno.env.get("SUPABASE_URL")||"";const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
  if(!url||!service)return json({ok:false,error:"runtime_config_missing"},500);
  const sb=createClient(url,service,{auth:{persistSession:false}});
  const auth=req.headers.get("authorization")||"";const token=auth.replace(/^Bearer\s+/i,"").trim();
  if(!token)return json({ok:false,error:"device_auth_required"},401);
  const tq=await sb.from("jarvis_device_tokens").select("token_hash,revoked_at").eq("token_hash",await sha256(token)).maybeSingle();
  if(tq.error||!tq.data||tq.data.revoked_at)return json({ok:false,error:"device_auth_invalid"},401);
  const body=await req.json().catch(()=>({}));const project=resolveProject(body?.project_key||body?.project);
  const observedAt=new Date().toISOString();
  const [cycleQ,runsQ,eventsQ,gh]=await Promise.all([
    sb.from("director_cycle_runs").select("id,status,dispatched,started_at,finished_at,pre_state,post_state,warnings").eq("project_key",project.key).order("started_at",{ascending:false}).limit(1),
    sb.from("contentflow_builder_runs").select("id,task_key,status,quality_score,review_approved,created_at,project_key").eq("project_key",project.key).order("created_at",{ascending:false}).limit(100),
    sb.from("director_autonomy_events").select("id,event_type,source,outcome,finished_at,notes,project_key").eq("project_key",project.key).order("finished_at",{ascending:false}).limit(50),
    github(project.repo||"investmentsespana-stack/-contentflow")
  ]);
  const cycle:any=cycleQ.data?.[0]||null;const runs:any[]=runsQ.data||[];const events:any[]=eventsQ.data||[];
  const statuses=["PENDING","CLAIMED","RUNNING","VERIFYING","DONE","BLOCKED"] as const;const buckets:Record<string,any[]>={};for(const x of statuses)buckets[x]=[];
  for(const r of runs){const s=String(r.status||"").toUpperCase();let k=s.includes("VERIFY")?"VERIFYING":s.includes("CLAIM")?"CLAIMED":s.includes("RUN")?"RUNNING":s.includes("DONE")||s.includes("COMPLETE")||s==="SUCCESS"?"DONE":s.includes("BLOCK")||s.includes("FAIL")?"BLOCKED":"PENDING";buckets[k].push(r)}
  const rara=events.find((e:any)=>/rara/i.test(String(e.source||"")+" "+String(e.event_type||"")))||null;
  const gpuHints=[...runs,...events].filter((x:any)=>/gpu|nebius|cuda|l40/i.test(JSON.stringify(x))).slice(0,20);
  const conflicts:any[]=[];const dirActive=(buckets.RUNNING.length+buckets.CLAIMED.length)>0;const ghActive=gh.freshness==="LIVE_QUERY"&&(((gh as any).runsToday||[]).length+((gh as any).commitsToday||[]).length)>0;
  if(!dirActive&&ghActive)conflicts.push({code:"CONFLICT_DETECTED",type:"DIRECTOR_ZERO_VS_GITHUB_ACTIVITY",resolution:"No interpretar 0 del hub como 0 actividad global."});
  if(gh.freshness!=="LIVE_QUERY")conflicts.push({code:"SOURCE_PARTIAL",type:"GITHUB_NOT_LIVE",detail:(gh as any).error||gh.freshness});
  const coverage={director:!cycleQ.error,github:gh.freshness==="LIVE_QUERY",gpuVmIndependent:false,evidenceIndependent:false};
  const canonical=coverage.director&&coverage.github&&coverage.gpuVmIndependent&&coverage.evidenceIndependent&&conflicts.length===0;
  return json({ok:true,schema:"jarvis.project.state.gateway.v1",source:"jarvis-project-state-gateway",freshness:canonical?"LIVE_RECONCILED":"LIVE_RECONCILED_PARTIAL",observedAt,stateClass:canonical?"CANONICAL":"GLOBAL_PARTIAL_NOT_CANONICAL",project:{id:project.id,key:project.key,name:project.name,repository:project.repo},ESTADO_HUB_INTERNO:{source:"director_state_hub",freshness:cycleQ.error?"ERROR":"LIVE_QUERY",observedAt,director:cycle,tasks:buckets,rara,recentEvents:events.slice(0,20)},ESTADO_OPERATIVO_GLOBAL:{source:["director_state_hub","github","gpu_vm_adapter_pending","evidence_adapter_pending"],freshness:canonical?"LIVE_RECONCILED":"LIVE_RECONCILED_PARTIAL",observedAt,latestCommit:(gh as any).head||null,lastGitHubRun:(gh as any).runsToday?.[0]||null,githubRunsToday:(gh as any).runsToday||[],githubCommitsToday:(gh as any).commitsToday||[],activeTasks:[...buckets.RUNNING,...buckets.CLAIMED],queuedTasks:buckets.PENDING,verifyingTasks:buckets.VERIFYING,completedTasks:buckets.DONE,blockedTasks:buckets.BLOCKED,gpuStatus:{status:"NOT_INDEPENDENTLY_VERIFIED",hints:gpuHints},conflicts},coverage,conflicts,rawSources:{github:gh,directorErrors:{cycle:cycleQ.error?.message||null,runs:runsQ.error?.message||null,events:eventsQ.error?.message||null}}});
});