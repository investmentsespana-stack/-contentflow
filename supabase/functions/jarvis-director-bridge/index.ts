import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers={'content-type':'application/json','cache-control':'no-store'};
const ok=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
async function sha256(text:string){const bytes=new TextEncoder().encode(text);const digest=await crypto.subtle.digest('SHA-256',bytes);return Array.from(new Uint8Array(digest)).map(b=>b.toString(16).padStart(2,'0')).join('')}
function randomToken(){const b=new Uint8Array(32);crypto.getRandomValues(b);return Array.from(b).map(x=>x.toString(16).padStart(2,'0')).join('')}

const PROJECTS:Record<string,{key:string,name:string,aliases:string[],cycleFunction:string|null}> = {
  contentflow:{key:'contentflow',name:'ContentFlow / Director',aliases:['contentflow','director','orquestador'],cycleFunction:'contentflow-director-control'},
  avatar:{key:'avatar-platform-v1',name:'Avatar',aliases:['avatar','avatar-platform-v1','proyecto avatar'],cycleFunction:'contentflow-direct-tool-kick-avatar'},
  academy:{key:'agent-academy-platform-v1',name:'Cygnus Academy / Skool',aliases:['academy','academia','skool','cygnus','cygnus academy','agent-academy-platform-v1'],cycleFunction:'contentflow-direct-tool-kick-academy'},
  trading:{key:'super_estrategia_adaptativa',name:'Trading / Super Estrategia Adaptativa',aliases:['trading','super_estrategia_adaptativa','super estrategia','estrategia adaptativa','strategyquant','sqx','oro','gold','nq','nasdaq'],cycleFunction:null},
};
function resolveProject(input:unknown){
  const raw=String(input||'contentflow').trim().toLowerCase();
  for(const [id,p] of Object.entries(PROJECTS))if(id===raw||p.key===raw||p.aliases.includes(raw))return {id,...p};
  return null;
}
async function callFunction(url:string,service:string,fn:string,payload:unknown={}){
  const ctl=new AbortController(),timer=setTimeout(()=>ctl.abort(),220000);
  try{const r=await fetch(`${url}/functions/v1/${fn}`,{method:'POST',signal:ctl.signal,headers:{Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:JSON.stringify(payload)});const text=await r.text();let result:any;try{result=text?JSON.parse(text):{}}catch{result={raw:text}}return{ok:r.ok&&result?.ok!==false,httpStatus:r.status,result}}finally{clearTimeout(timer)}
}

Deno.serve(async(req:Request)=>{
  if(req.method!=='POST')return ok({ok:false,error:'POST required'},405);
  const url=Deno.env.get('SUPABASE_URL')||'',service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
  if(!url||!service)return ok({ok:false,error:'runtime_config_missing'},500);
  const sb=createClient(url,service,{auth:{persistSession:false}});
  const body=await req.json().catch(()=>({})),action=String(body?.action||'status');

  if(action==='pair'){
    const code=String(body?.pairing_code||'').trim();
    if(!/^\d{6}$/.test(code))return ok({ok:false,error:'invalid_pairing_code'},401);
    const codeHash=await sha256(code),q=await sb.from('jarvis_pairing_codes').select('code_hash,expires_at,consumed_at').eq('code_hash',codeHash).maybeSingle();
    if(q.error||!q.data||q.data.consumed_at||new Date(q.data.expires_at).getTime()<=Date.now())return ok({ok:false,error:'pairing_code_invalid_or_expired'},401);
    const consume=await sb.from('jarvis_pairing_codes').update({consumed_at:new Date().toISOString()}).eq('code_hash',codeHash).is('consumed_at',null).select('code_hash').maybeSingle();
    if(consume.error||!consume.data)return ok({ok:false,error:'pairing_code_already_used'},409);
    const token=randomToken(),tokenHash=await sha256(token),ins=await sb.from('jarvis_device_tokens').insert({token_hash:tokenHash,label:'jarvis-windows'});
    if(ins.error)return ok({ok:false,error:'device_token_create_failed',detail:ins.error.message},500);
    return ok({ok:true,device_token:token,scheme:'Bearer'});
  }

  const token=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'').trim();
  if(!token)return ok({ok:false,error:'device_auth_required'},401);
  const tokenHash=await sha256(token),tq=await sb.from('jarvis_device_tokens').select('token_hash,revoked_at').eq('token_hash',tokenHash).maybeSingle();
  if(tq.error||!tq.data||tq.data.revoked_at)return ok({ok:false,error:'device_auth_invalid'},401);
  await sb.from('jarvis_device_tokens').update({last_used_at:new Date().toISOString()}).eq('token_hash',tokenHash);

  if(action==='projects')return ok({ok:true,schema:'jarvis.projects.v2',projects:Object.entries(PROJECTS).map(([id,p])=>({id,key:p.key,name:p.name,aliases:p.aliases,supportsCycle:Boolean(p.cycleFunction)}))});
  const project=resolveProject(body?.project_key||body?.project||'contentflow');
  if(!project)return ok({ok:false,error:'unsupported_project',available:Object.entries(PROJECTS).map(([id,p])=>({id,key:p.key,name:p.name}))},400);
  if(action==='select'||action==='project_select')return ok({ok:true,schema:'jarvis.project.select.v2',project:{id:project.id,key:project.key,name:project.name},selectedAt:new Date().toISOString()});

  if(action==='status'||action==='project_status'){
    const [cycleQ,runsQ,eventsQ,evidenceQ]=await Promise.all([
      sb.from('director_cycle_runs').select('id,status,phase,dispatched,started_at,finished_at,pre_state,post_state,warnings,error').eq('project_key',project.key).order('started_at',{ascending:false}).limit(1),
      sb.from('contentflow_builder_runs').select('id,task_key,status,quality_score,review_approved,created_at,heartbeat_at,project_key').eq('project_key',project.key).order('created_at',{ascending:false}).limit(50),
      sb.from('director_autonomy_events').select('id,event_type,source,outcome,finished_at,notes,project_key').eq('project_key',project.key).order('id',{ascending:false}).limit(20),
      sb.from('director_external_evidence').select('id,task_key,evidence_type,status,evidence,source,verified,updated_at').eq('project_key',project.key).order('updated_at',{ascending:false}).limit(30)
    ]);
    if(cycleQ.error||runsQ.error||eventsQ.error||evidenceQ.error)return ok({ok:false,error:'project_status_query_failed',detail:[cycleQ.error?.message,runsQ.error?.message,eventsQ.error?.message,evidenceQ.error?.message].filter(Boolean)},500);
    const runs:any[]=runsQ.data||[],counts:Record<string,number>={};for(const r of runs)counts[String(r.status||'unknown')]=(counts[String(r.status||'unknown')]||0)+1;
    const rara=(eventsQ.data||[]).find((e:any)=>/rara/i.test(String(e.source||'')+' '+String(e.event_type||'')))||null;
    return ok({ok:true,schema:'jarvis.project.status.v4',project:{id:project.id,key:project.key,name:project.name},observedAt:new Date().toISOString(),director:cycleQ.data?.[0]||null,recentRuns:{total:runs.length,counts,runs:runs.slice(0,20)},rara,recentEvents:eventsQ.data||[],externalEvidence:evidenceQ.data||[]});
  }

  if(action==='cycle'||action==='project_cycle'){
    if(!project.cycleFunction)return ok({ok:false,error:'project_cycle_not_supported',project:{id:project.id,key:project.key,name:project.name},researchOnly:true},409);
    const called=await callFunction(url,service,project.cycleFunction,{});
    return ok({ok:called.ok,schema:'jarvis.project.command.v4',action:'cycle',project:{id:project.id,key:project.key,name:project.name},source:project.cycleFunction,result:called.result,httpStatus:called.httpStatus},called.httpStatus>=200&&called.httpStatus<300?200:502);
  }
  return ok({ok:false,error:'unsupported_action',allowed:['projects','select','status','cycle','project_select','project_status','project_cycle']},400);
});
