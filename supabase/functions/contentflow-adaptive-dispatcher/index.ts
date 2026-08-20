import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MASTER_HARD_CAP = 2;

Deno.serve(async(req)=>{
 const H={'content-type':'application/json','cache-control':'no-store'};
 if(req.method!=='POST')return new Response(JSON.stringify({ok:false,error:'POST required'}),{status:405,headers:H});
 const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'',presented=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
 if(!service||presented!==service)return new Response(JSON.stringify({ok:false,error:'service_role_required'}),{status:403,headers:H});
 const url=Deno.env.get('SUPABASE_URL')||'',sb=createClient(url,service,{auth:{persistSession:false}}),project='contentflow';
 const {data:cap}=await sb.rpc('contentflow_recommended_parallelism',{p_project_key:project});
 const {data:lane}=await sb.from('contentflow_nexo_lane_status').select('production_max,global_max').limit(1).maybeSingle();
 const {count:runningWorkers}=await sb.from('director_worker_queue').select('model_id',{count:'exact',head:true}).eq('status','running');
 const recommended=Math.max(1,Math.min(Number(cap||1),Number(lane?.production_max||1),Number(lane?.global_max||1)));
 const max=Math.min(MASTER_HARD_CAP,recommended);
 const slots=Math.max(0,max-Number(runningWorkers||0));
 if(!slots)return new Response(JSON.stringify({ok:true,accepted:0,reason:'capacity_full',cap:max,master_hard_cap:MASTER_HARD_CAP}),{headers:H});

 const {data:workers}=await sb.from('director_worker_queue').select('model_id,status,total_assignments,total_completions,last_quality_score,updated_at').eq('status','ready');
 const viable=(workers||[]).filter((w:any)=>Number(w.last_quality_score||0)>=85||Number(w.total_completions||0)>=3).sort((a:any,b:any)=>{
   const ar=(Number(a.total_completions||0)+1)/(Number(a.total_assignments||0)+2),br=(Number(b.total_completions||0)+1)/(Number(b.total_assignments||0)+2);
   return (br-ar)||(Number(b.last_quality_score||0)-Number(a.last_quality_score||0));
 });
 if(viable.length<1)return new Response(JSON.stringify({ok:true,accepted:0,reason:'insufficient_viable_workers',cap:max}),{headers:H});

 const {data:tasks}=await sb.from('contentflow_build_backlog').select('id,task_key,title,description,task_type,acceptance_criteria,depends_on,priority,stage,status,next_eligible_at,execution_lane').eq('project_key',project).eq('execution_lane','llm_artifact').in('status',['ready','planned']).order('priority',{ascending:false}).order('stage',{ascending:true}).limit(80);
 const {data:retry}=await sb.from('contentflow_retry_state').select('backlog_task_id,circuit_state,last_model,last_error,attempt_count,next_retry_at').eq('project_key',project);
 const retryById=new Map((retry||[]).map((r:any)=>[Number(r.backlog_task_id),r]));
 const {data:all}=await sb.from('contentflow_build_backlog').select('task_key,status').eq('project_key',project);
 const statusByKey=new Map((all||[]).map((x:any)=>[String(x.task_key),String(x.status)]));
 const chosen:any[]=[];
 const reservedWorkers=new Set<string>();
 for(const t of tasks||[]){
   const rs:any=retryById.get(Number(t.id));
   if(rs?.circuit_state==='open')continue;
   if(t.next_eligible_at&&new Date(t.next_eligible_at).getTime()>Date.now())continue;
   const deps=Array.isArray(t.depends_on)?t.depends_on.map(String):[];
   if(!deps.every((d:string)=>statusByKey.get(d)==='completed'))continue;
   const {count:active}=await sb.from('contentflow_builder_runs').select('id',{count:'exact',head:true}).eq('backlog_task_id',t.id).in('status',['claimed','running','review_required']).is('finished_at',null);
   if(Number(active||0)>0)continue;
   const worker=viable.find((w:any)=>!reservedWorkers.has(String(w.model_id))&&String(w.model_id)!==String(rs?.last_model||''))||viable.find((w:any)=>!reservedWorkers.has(String(w.model_id)));
   if(!worker)break;
   const reviewer=viable.find((w:any)=>String(w.model_id)!==String(worker.model_id)&&String(w.model_id)!==String(rs?.last_model||''))||viable.find((w:any)=>String(w.model_id)!==String(worker.model_id));
   if(!reviewer)continue;
   const workerId=String(worker.model_id);
   reservedWorkers.add(workerId);
   chosen.push({task:t,worker:workerId,reviewer:String(reviewer.model_id),avoided_model:String(rs?.last_model||'')});
   if(chosen.length>=slots)break;
 }
 if(!chosen.length)return new Response(JSON.stringify({ok:true,accepted:0,reason:'no_dispatchable_llm_artifact_tasks',cap:max,master_hard_cap:MASTER_HARD_CAP}),{headers:H});

 const {data:cfg}=await sb.from('contentflow_internal_runner_config').select('runner_secret').eq('id',1).maybeSingle();
 const secret=String(cfg?.runner_secret||'');
 if(!secret)return new Response(JSON.stringify({ok:false,error:'runner_secret_missing'}),{status:500,headers:H});
 const accepted:any[]=[];
 for(const x of chosen){
   const t=x.task;
   const claim=await sb.from('contentflow_build_backlog').update({status:'running',selected_model:x.worker,team:`adaptive:${x.worker}|review:${x.reviewer}`,updated_at:new Date().toISOString()}).eq('id',t.id).eq('execution_lane','llm_artifact').in('status',['ready','planned']).select('id').maybeSingle();
   if(!claim.data)continue;
   const {data:run}=await sb.from('contentflow_builder_runs').select('id,lease_token').eq('backlog_task_id',t.id).eq('status','claimed').order('id',{ascending:false}).limit(1).maybeSingle();
   if(!run){await sb.from('contentflow_build_backlog').update({status:'ready',selected_model:null,updated_at:new Date().toISOString()}).eq('id',t.id);continue;}
   await sb.from('contentflow_builder_runs').update({selected_model:x.worker,idempotency_key:`contentflow:${t.task_key}:run:${run.id}`,heartbeat_at:new Date().toISOString(),lease_expires_at:new Date(Date.now()+180000).toISOString(),runner_instance_id:null,heartbeat_seq:0,control_protocol:'fenced-v2'}).eq('id',run.id);
   const prior=(workers||[]).find((q:any)=>q.model_id===x.worker);
   const w=await sb.from('director_worker_queue').update({status:'running',current_task_key:t.task_key,last_started_at:new Date().toISOString(),total_assignments:Number(prior?.total_assignments||0)+1,updated_at:new Date().toISOString()}).eq('model_id',x.worker).eq('status','ready').select('model_id').maybeSingle();
   if(!w.data){await sb.from('contentflow_build_backlog').update({status:'ready',selected_model:null,updated_at:new Date().toISOString()}).eq('id',t.id);await sb.from('contentflow_builder_runs').update({status:'deferred',finished_at:new Date().toISOString(),error:'worker_claim_race_recovered',lease_revoked_at:new Date().toISOString()}).eq('id',run.id);continue;}
   const depKeys=Array.isArray(t.depends_on)?t.depends_on.map(String):[];
   let depContext='NO_DEPENDENCIES';
   if(depKeys.length){const {data:deps}=await sb.from('contentflow_build_backlog').select('task_key,title,status,quality_score,result').eq('project_key',project).in('task_key',depKeys);depContext=(deps||[]).map((d:any)=>`DEPENDENCY: ${d.task_key} | status=${d.status} | quality=${d.quality_score}\nVERIFIED RESULT:\n${String(d.result||'').slice(0,3000)}`).join('\n---\n')||depContext;}
   const prompt=`PROYECTO: ContentFlow AI\nTAREA: ${t.title}\nDESCRIPCION: ${t.description||''}\nTIPO: ${t.task_type||'general'}\nCRITERIO DE ACEPTACION: ${t.acceptance_criteria||''}\n\nBUILDER_RUN_ID: ${run.id}\nLa evidencia runtime debe estar persistida y correlacionada con este builder_run_id. No inventes UUIDs, pruebas, despliegues ni evidencia.\n\nEVIDENCIA VERIFICADA DE DEPENDENCIAS:\n${depContext}\n\nProduce el artefacto minimo verificable. Si falta evidencia, marca NEEDS_EVIDENCE y no simules implementación.`;
   EdgeRuntime.waitUntil(fetch(`${url}/functions/v1/contentflow-dispatch-executor-v2`,{method:'POST',headers:{Authorization:`Bearer ${service}`,'Content-Type':'application/json','X-ContentFlow-Internal':secret},body:JSON.stringify({task_type:t.task_type||'general',task:prompt,model_hint:x.worker,reviewer_hint:x.reviewer,claim_task_key:t.task_key,builder_run_id:run.id,lease_token:run.lease_token})}).catch(async(e)=>{await sb.from('contentflow_builder_runs').update({status:'failed',finished_at:new Date().toISOString(),error:`adaptive_dispatch_fetch_failed:${String(e)}`}).eq('id',run.id);await sb.from('contentflow_build_backlog').update({status:'ready',selected_model:null,updated_at:new Date().toISOString()}).eq('id',t.id);await sb.from('director_worker_queue').update({status:'ready',current_task_key:null,updated_at:new Date().toISOString()}).eq('model_id',x.worker);}));
   accepted.push({task_key:t.task_key,run_id:run.id,worker:x.worker,reviewer:x.reviewer,avoided_model:x.avoided_model});
 }
 return new Response(JSON.stringify({ok:true,accepted:accepted.length,cap:max,master_hard_cap:MASTER_HARD_CAP,dispatcher:'adaptive-v3-lane-isolated',items:accepted}),{status:202,headers:H});
});