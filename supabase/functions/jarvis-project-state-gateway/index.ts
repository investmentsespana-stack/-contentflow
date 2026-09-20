import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const H={"content-type":"application/json","cache-control":"no-store"};
const json=(b:unknown,s=200)=>new Response(JSON.stringify(b),{status:s,headers:H});

const PROJECTS:Record<string,{key:string,name:string,repo:string}> = {
  contentflow:{key:"contentflow",name:"ContentFlow / Director",repo:"investmentsespana-stack/-contentflow"},
  avatar:{key:"avatar-platform-v1",name:"Avatar",repo:"investmentsespana-stack/avatar-platform"},
  academy:{key:"agent-academy-platform-v1",name:"Cygnus Academy / Skool",repo:"investmentsespana-stack/-contentflow"},
  trading:{key:"super_estrategia_adaptativa",name:"Trading / Super Estrategia Adaptativa",repo:"investmentsespana-stack/-contentflow"},
};

async function sha256(t:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(t));return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("")}
function resolveProject(v:unknown){
  const s=String(v||"contentflow").toLowerCase();
  if(s.includes("avatar"))return {id:"avatar",...PROJECTS.avatar};
  if(/academy|academia|skool|cygnus/.test(s))return {id:"academy",...PROJECTS.academy};
  if(/trading|super_estrategia|estrategia adaptativa|strategyquant|sqx|oro|gold|\bnq\b|nasdaq/.test(s))return {id:"trading",...PROJECTS.trading};
  return {id:"contentflow",...PROJECTS.contentflow};
}
function ageSeconds(ts:unknown){const t=Date.parse(String(ts||""));return Number.isFinite(t)?Math.max(0,Math.round((Date.now()-t)/1000)):null}
function bucketStatus(s:unknown){
  const x=String(s||"").toUpperCase();
  if(x.includes("VERIFY")||x.includes("REVIEW"))return "VERIFYING";
  if(x.includes("CLAIM"))return "CLAIMED";
  if(x.includes("RUN"))return "RUNNING";
  if(x.includes("DONE")||x.includes("COMPLETE")||x==="SUCCESS")return "DONE";
  if(x.includes("BLOCK")||x.includes("FAIL"))return "BLOCKED";
  return "PENDING";
}
async function github(repo:string){
  const token=Deno.env.get("GITHUB_TOKEN")||Deno.env.get("GH_TOKEN")||"";
  const observedAt=new Date().toISOString();
  if(!token)return {source:"github",freshness:"UNAVAILABLE",observedAt,repository:repo,error:"GITHUB_TOKEN_NOT_CONFIGURED_IN_GATEWAY"};
  const headers={accept:"application/vnd.github+json",authorization:`Bearer ${token}`,"user-agent":"jarvis-project-state-gateway"};
  const day=new Date();day.setUTCHours(0,0,0,0);const since=day.toISOString();
  async function get(path:string){
    const c=new AbortController(),tm=setTimeout(()=>c.abort(),10000);
    try{
      const r=await fetch(`https://api.github.com/repos/${repo}${path}`,{headers,signal:c.signal});
      const t=await r.text();let d:any={};try{d=t?JSON.parse(t):{}}catch{d={raw:t}};
      if(!r.ok)throw new Error(`HTTP ${r.status}: ${String(d?.message||t).slice(0,180)}`);
      return d;
    }finally{clearTimeout(tm)}
  }
  try{
    const [runs,head,commits]=await Promise.all([get("/actions/runs?per_page=100"),get("/commits/main"),get(`/commits?sha=main&since=${encodeURIComponent(since)}&per_page=100`)]);
    const today=(runs.workflow_runs||[]).filter((r:any)=>Date.parse(r.created_at||0)>=day.getTime());
    return {source:"github",freshness:"LIVE_QUERY",observedAt,repository:repo,
      head:{sha:head.sha,message:head.commit?.message,date:head.commit?.committer?.date||head.commit?.author?.date},
      runsToday:today.map((r:any)=>({id:r.id,name:r.name,run_number:r.run_number,status:r.status,conclusion:r.conclusion,head_sha:r.head_sha,created_at:r.created_at,updated_at:r.updated_at,html_url:r.html_url})),
      commitsToday:(commits||[]).map((c:any)=>({sha:c.sha,message:c.commit?.message,date:c.commit?.committer?.date||c.commit?.author?.date,html_url:c.html_url}))
    };
  }catch(e){return {source:"github",freshness:"ERROR",observedAt,repository:repo,error:String((e as Error)?.message||e)}}
}

Deno.serve(async(req:Request)=>{
  if(req.method!=="POST")return json({ok:false,error:"POST required"},405);
  const url=Deno.env.get("SUPABASE_URL")||"",service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
  if(!url||!service)return json({ok:false,error:"runtime_config_missing"},500);
  const sb=createClient(url,service,{auth:{persistSession:false}});
  const auth=req.headers.get("authorization")||"",token=auth.replace(/^Bearer\s+/i,"").trim();
  if(!token)return json({ok:false,error:"device_auth_required"},401);
  const tq=await sb.from("jarvis_device_tokens").select("token_hash,revoked_at").eq("token_hash",await sha256(token)).maybeSingle();
  if(tq.error||!tq.data||tq.data.revoked_at)return json({ok:false,error:"device_auth_invalid"},401);

  const body=await req.json().catch(()=>({})),project=resolveProject(body?.project_key||body?.project);
  const observedAt=new Date().toISOString();

  const [cycleQ,runsQ,eventsQ,evidenceQ,factsQ,tracesQ,gh]=await Promise.all([
    sb.from("director_cycle_runs").select("id,status,phase,dispatched,started_at,finished_at,pre_state,post_state,warnings,error,workflow_version,trace_id").eq("project_key",project.key).order("started_at",{ascending:false}).limit(1),
    sb.from("contentflow_builder_runs").select("id,task_key,status,quality_score,review_approved,created_at,finished_at,heartbeat_at,lease_expires_at,activity_phase,runner_instance_id,trace_id,project_key").eq("project_key",project.key).order("created_at",{ascending:false}).limit(100),
    sb.from("director_autonomy_events").select("id,event_type,task_key,source,outcome,quality_score,started_at,finished_at,notes,project_key").eq("project_key",project.key).order("id",{ascending:false}).limit(100),
    sb.from("director_external_evidence").select("id,task_key,evidence_type,environment,engine,version,status,evidence,source,verified,created_at,updated_at").eq("project_key",project.key).order("updated_at",{ascending:false}).limit(100),
    sb.from("director_context_facts").select("id,fact_key,version,status,payload,source,source_ref,observed_at,expires_at,verified,supersedes_id").eq("project_key",project.key).eq("status","active").order("observed_at",{ascending:false}).limit(100),
    sb.from("director_trace_spans").select("span_id,trace_id,parent_span_id,span_name,span_kind,span_status,started_at,ended_at,attributes,error_class,error_message").eq("project_key",project.key).order("started_at",{ascending:false}).limit(50),
    github(project.repo)
  ]);

  const runs:any[]=runsQ.data||[],events:any[]=eventsQ.data||[],buckets:Record<string,any[]>={PENDING:[],CLAIMED:[],RUNNING:[],VERIFYING:[],DONE:[],BLOCKED:[]};
  for(const r of runs){const k=bucketStatus(r.status);buckets[k].push({...r,heartbeat_age_seconds:ageSeconds(r.heartbeat_at)})}
  const cycle:any=cycleQ.data?.[0]||null;
  const latestRara=events.find((e:any)=>/rara/i.test(String(e.source||"")+" "+String(e.event_type||"")))||null;

  let trading:any=null;
  if(project.id==="trading"){
    const deviceQ=await sb.from("trading_sqx_bridge_devices").select("id,device_name,status,capabilities,last_health,last_seen_at,updated_at").eq("status","ACTIVE").order("last_seen_at",{ascending:false}).limit(1);
    const device:any=deviceQ.data?.[0]||null;
    const [cmdQ,sqxEventQ,raraQ,govQ]=await Promise.all([
      device?sb.from("trading_sqx_bridge_commands").select("id,command_type,payload,state,created_at,claimed_at,completed_at,result,error,updated_at").eq("device_id",device.id).order("created_at",{ascending:false}).limit(20):Promise.resolve({data:[],error:null}),
      device?sb.from("trading_sqx_bridge_events").select("id,event_type,payload,created_at,command_id").eq("device_id",device.id).order("created_at",{ascending:false}).limit(30):Promise.resolve({data:[],error:null}),
      sb.from("trading_sqx_rara_verifications").select("id,director_request_id,bridge_command_id,verdict,reason,evidence,created_at").order("created_at",{ascending:false}).limit(20),
      device?sb.from("trading_sqx_governance_policy").select("mode,allowed_projects,require_local_control,updated_at").eq("device_id",device.id).maybeSingle():Promise.resolve({data:null,error:null})
    ]);
    trading={
      device:device?{...device,last_seen_age_seconds:ageSeconds(device.last_seen_at)}:null,
      commands:cmdQ.data||[],events:sqxEventQ.data||[],raraVerifications:raraQ.data||[],
      governance:govQ.data||null,
      errors:{device:deviceQ.error?.message||null,commands:(cmdQ as any).error?.message||null,events:(sqxEventQ as any).error?.message||null,rara:raraQ.error?.message||null,governance:(govQ as any).error?.message||null}
    };
  }

  const conflicts:any[]=[];
  const ghLive=(gh as any).freshness==="LIVE_QUERY";
  if(!ghLive)conflicts.push({code:"SOURCE_PARTIAL",type:"GITHUB_NOT_LIVE",detail:(gh as any).error||(gh as any).freshness});
  if(runsQ.error)conflicts.push({code:"SOURCE_PARTIAL",type:"DIRECTOR_RUNS_QUERY_ERROR",detail:runsQ.error.message});
  if(eventsQ.error)conflicts.push({code:"SOURCE_PARTIAL",type:"DIRECTOR_EVENTS_QUERY_ERROR",detail:eventsQ.error.message});
  if(evidenceQ.error)conflicts.push({code:"SOURCE_PARTIAL",type:"EVIDENCE_QUERY_ERROR",detail:evidenceQ.error.message});
  if(factsQ.error)conflicts.push({code:"SOURCE_PARTIAL",type:"PROVENANCE_QUERY_ERROR",detail:factsQ.error.message});
  if(project.id==="trading"){
    if(!trading?.device)conflicts.push({code:"SOURCE_PARTIAL",type:"SQX_DEVICE_UNAVAILABLE"});
    else if(Number(trading.device.last_seen_age_seconds??999999)>120)conflicts.push({code:"STALE_SOURCE",type:"SQX_HEARTBEAT_STALE",age_seconds:trading.device.last_seen_age_seconds});
  }

  const dirActive=(buckets.RUNNING.length+buckets.CLAIMED.length)>0;
  const ghActive=ghLive&&(((gh as any).runsToday||[]).some((r:any)=>r.status==="in_progress"||r.status==="queued"));
  if(!dirActive&&ghActive)conflicts.push({code:"CONFLICT_DETECTED",type:"DIRECTOR_ZERO_VS_GITHUB_ACTIVE_RUN",resolution:"Do not interpret hub zero as zero global activity."});

  const coverage:any={
    director:!cycleQ.error&&!runsQ.error&&!eventsQ.error,
    github:ghLive,
    evidence:!evidenceQ.error,
    provenance:!factsQ.error,
    traces:!tracesQ.error
  };
  if(project.id==="trading")coverage.sqxBridge=Boolean(trading?.device)&&!trading?.errors?.device;
  if(project.id==="avatar")coverage.gpuVmIndependent=false;

  const required=project.id==="avatar"?["director","github","evidence","provenance","traces","gpuVmIndependent"]:
    project.id==="trading"?["director","github","evidence","provenance","traces","sqxBridge"]:
    ["director","github","evidence","provenance","traces"];
  const canonical=required.every(k=>coverage[k]===true)&&conflicts.length===0;

  const architectureMap=(evidenceQ.data||[]).find((e:any)=>e.task_key==="graphify_trading_knowledge_graph_v1"&&e.status==="pass"&&e.verified)||null;

  return json({
    ok:true,schema:"jarvis.project.state.gateway.v2",source:"jarvis-project-state-gateway",
    freshness:canonical?"LIVE_RECONCILED":"LIVE_RECONCILED_PARTIAL",observedAt,
    stateClass:canonical?"CANONICAL":"GLOBAL_PARTIAL_NOT_CANONICAL",
    project:{id:project.id,key:project.key,name:project.name,repository:project.repo},
    ESTADO_HUB_INTERNO:{source:"director_state_hub",freshness:coverage.director?"LIVE_QUERY":"ERROR",observedAt,director:cycle,tasks:buckets,rara:latestRara,recentEvents:events.slice(0,30)},
    ESTADO_OPERATIVO_GLOBAL:{
      source:["director_state_hub","github","external_evidence","context_provenance","trace_spans",...(project.id==="trading"?["sqx_bridge","sqx_rara"]:[])],
      freshness:canonical?"LIVE_RECONCILED":"LIVE_RECONCILED_PARTIAL",observedAt,
      latestCommit:(gh as any).head||null,lastGitHubRun:(gh as any).runsToday?.[0]||null,
      githubRunsToday:(gh as any).runsToday||[],githubCommitsToday:(gh as any).commitsToday||[],
      activeTasks:[...buckets.RUNNING,...buckets.CLAIMED],queuedTasks:buckets.PENDING,verifyingTasks:buckets.VERIFYING,
      completedTasks:buckets.DONE,blockedTasks:buckets.BLOCKED,
      latestExternalEvidence:(evidenceQ.data||[]).slice(0,50),
      activeContextFacts:factsQ.data||[],
      recentTraces:tracesQ.data||[],
      architectureMap,
      trading,
      conflicts
    },
    coverage,conflicts,
    rawSourceErrors:{
      cycle:cycleQ.error?.message||null,runs:runsQ.error?.message||null,events:eventsQ.error?.message||null,
      evidence:evidenceQ.error?.message||null,provenance:factsQ.error?.message||null,traces:tracesQ.error?.message||null,
      github:(gh as any).error||null
    }
  });
});
