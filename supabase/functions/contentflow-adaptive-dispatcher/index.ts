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

 const {data:workers}=await sb.from('director_worker_queue').select('model_id,status,total_assignments,total_completions,last_quality_score,updated_at').eq('status','ready');
 const viable=(workers||[]).filter((w:any)=>Number(w.last_quality_score||0)>=85||Number(w.total_completions||0)>=3).sort((a:any,b:any)=>{
   const ar=(Number(a.total_completions||0)+1)/(Number(a.total_assignments||0)+2),br=(Number(b.total_completions||0)+1)/(Number(b.total_assignments||0)+2);
   return (br-ar)||(Number(b.last_quality_score||0)-Number(a.last_quality_score||0));
 });

 const {data:tasks}=await sb.from('contentflow_build_backlog').select('id,task_key,depends_on,priority,stage,status,next_eligible_at,execution_lane').eq('project_key',project).eq('execution_lane','llm_artifact').in('status',['ready','planned']).order('priority',{ascending:false}).order('stage',{ascending:true}).limit(80);
 const {data:retry}=await sb.from('contentflow_retry_state').select('backlog_task_id,circuit_state,last_model,next_retry_at').eq('project_key',project);
 const retryById=new Map((retry||[]).map((r:any)=>[Number(r.backlog_task_id),r]));
 const {data:all}=await sb.from('contentflow_build_backlog').select('task_key,status').eq('project_key',project);
 const statusByKey=new Map((all||[]).map((x:any)=>[String(x.task_key),String(x.status)]));
 const candidates:any[]=[];
 for(const t of tasks||[]){
   const rs:any=retryById.get(Number(t.id));
   if(rs?.circuit_state==='open')continue;
   if(t.next_eligible_at&&new Date(t.next_eligible_at).getTime()>Date.now())continue;
   const deps=Array.isArray(t.depends_on)?t.depends_on.map(String):[];
   if(!deps.every((d:string)=>statusByKey.get(d)==='completed'))continue;
   const {count:active}=await sb.from('contentflow_builder_runs').select('id',{count:'exact',head:true}).eq('backlog_task_id',t.id).in('status',['claimed','running','review_required']).is('finished_at',null);
   if(Number(active||0)>0)continue;
   candidates.push({task_key:t.task_key,priority:t.priority,stage:t.stage,avoid_model:String(rs?.last_model||'')});
   if(candidates.length>=Math.max(1,slots))break;
 }

 // SINGLE-WRITER CONTRACT:
 // This function is advisory only. It MUST NOT mutate backlog, builder runs,
 // worker ownership, leases, or invoke the dispatch executor. director_core is
 // the sole dispatch writer.
 return new Response(JSON.stringify({
   ok:true,
   mode:'observe_only',
   dispatcher:'adaptive-v4-observe-only',
   accepted:0,
   mutations:0,
   single_writer:'director_core',
   master_hard_cap:MASTER_HARD_CAP,
   recommended_cap:max,
   running_workers:Number(runningWorkers||0),
   available_slots:slots,
   viable_workers:viable.map((w:any)=>String(w.model_id)),
   recommended_tasks:candidates
 }),{status:200,headers:H});
});
