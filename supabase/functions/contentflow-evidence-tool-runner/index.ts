import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const generic=new Set(['claimed','runner_started','runner_v2_started','runner_v4_started','runner_v5_started','artifact_generated','judge_completed','runner_completed','owner_finalized']);
const text=(v:any)=>JSON.stringify(v||{}).toLowerCase();
Deno.serve(async(req)=>{
 const H={'content-type':'application/json','cache-control':'no-store'};
 if(req.method!=='POST')return new Response(JSON.stringify({ok:false,error:'POST required'}),{status:405,headers:H});
 const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'',presented=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
 if(!service||presented!==service)return new Response(JSON.stringify({ok:false,error:'service_role_required'}),{status:403,headers:H});
 const url=Deno.env.get('SUPABASE_URL')||'',sb=createClient(url,service,{auth:{persistSession:false}}),project='contentflow';
 const sync=await sb.rpc('contentflow_sync_tool_execution_queue',{p_project_key:project});
 const claim=await sb.rpc('contentflow_claim_tool_execution_task',{p_project_key:project});
 const q:any=claim.data?.[0];
 if(!q)return new Response(JSON.stringify({ok:true,status:'idle',sync:sync.data||null}),{headers:H});
 const finish=async(success:boolean,evidence:any,error:string|null)=>await sb.rpc('contentflow_finish_tool_execution_task',{p_queue_id:q.queue_id,p_claim_token:q.claim_token,p_success:success,p_evidence:evidence||{},p_error:error});
 const {data:reqRow}=await sb.from('contentflow_evidence_requirements').select('*').eq('project_key',project).eq('evidence_task_key',q.task_key).order('id',{ascending:false}).limit(1).maybeSingle();
 if(!reqRow){const f=await finish(false,{},'evidence_requirement_missing');return new Response(JSON.stringify({ok:false,status:'failed',reason:'evidence_requirement_missing',finish:f.data||null}),{headers:H});}
 const {data:sourceTask}=await sb.from('contentflow_build_backlog').select('id,task_key,runtime_verified,runtime_evidence,result,status,updated_at').eq('id',reqRow.backlog_task_id).maybeSingle();
 const {data:sourceRun}=await sb.from('contentflow_builder_runs').select('id,status,result,error,quality_score,created_at,finished_at').eq('id',reqRow.source_run_id).maybeSingle();
 const {data:events}=await sb.from('contentflow_runtime_event_ledger').select('id,event_type,actor,payload,created_at').eq('builder_run_id',reqRow.source_run_id).order('id',{ascending:true});
 const runtimeEvidence=sourceTask?.runtime_evidence||{};
 const rt=text(runtimeEvidence), evText=text(events), cls=String(reqRow.requirement_class||'unknown');
 const nonGeneric=(events||[]).filter((e:any)=>!generic.has(String(e.event_type)));
 let ok=false; let matched:string[]=[];
 const has=(s:string)=>rt.includes(s)||evText.includes(s);
 if(cls==='runtime_evidence'||cls==='persistence_integration'){
   ok=Boolean(sourceTask?.runtime_verified)&&(Object.keys(runtimeEvidence||{}).length>0||nonGeneric.length>0);
   if(ok)matched=nonGeneric.map((e:any)=>String(e.event_type));
 } else if(cls==='runtime_test'){
   ok=has('test')||has('assert')||has('integration')||has('ci_');
   if(ok)matched=(events||[]).map((e:any)=>String(e.event_type)).filter((x:string)=>/test|assert|integration|ci/i.test(x));
 } else if(cls==='static_analysis'){
   ok=has('static')||has('lint')||has('mypy')||has('scan');
   if(ok)matched=(events||[]).map((e:any)=>String(e.event_type)).filter((x:string)=>/static|lint|mypy|scan/i.test(x));
 } else if(cls==='external_approval'){
   ok=has('approval')||has('approved_by');
   if(ok)matched=(events||[]).map((e:any)=>String(e.event_type)).filter((x:string)=>/approv/i.test(x));
 } else if(cls==='source_contract'){
   ok=Boolean(sourceTask?.runtime_verified)&&has('source')&&Object.keys(runtimeEvidence||{}).length>0;
 }
 if(!ok){
   const err=`EVIDENCE_NOT_AVAILABLE:${cls}; no deterministic persisted evidence satisfies requirement for source_run_id=${reqRow.source_run_id}`;
   const f=await finish(false,{},err);
   return new Response(JSON.stringify({ok:true,status:'evidence_unavailable_no_nexo_call',queue_id:q.queue_id,evidence_task_key:q.task_key,requirement_class:cls,source_run_id:reqRow.source_run_id,error:err,finish:f.data||null}),{headers:H});
 }
 const evidence={architecture:'EVIDENCE_FIRST_EXECUTION_V1',source_task_key:reqRow.task_key,source_run_id:reqRow.source_run_id,requirement_class:cls,requirement_fingerprint:reqRow.requirement_fingerprint,matched_event_types:matched,persisted_runtime_evidence:runtimeEvidence,verified_at:new Date().toISOString(),verification_method:'deterministic_platform_evidence_check'};
 const f=await finish(true,evidence,null);
 return new Response(JSON.stringify({ok:true,status:'verified',queue_id:q.queue_id,evidence_task_key:q.task_key,requirement_class:cls,source_run_id:reqRow.source_run_id,finish:f.data||null}),{headers:H});
});
