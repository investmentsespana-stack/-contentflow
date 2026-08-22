import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { evaluateAutonomyAdmission } from "../_shared/autonomy-admission.mjs";

async function callInternal(url:string,service:string,path:string,timeoutMs=5000){
  try{
    const ctl=new AbortController(),t=setTimeout(()=>ctl.abort(),timeoutMs);
    const r=await fetch(`${url}/functions/v1/${path}`,{method:'POST',signal:ctl.signal,headers:{Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:'{}'});
    clearTimeout(t);
    return{status:r.status,body:await r.json().catch(()=>({}))};
  }catch(e){return{warning:String(e)}}
}

async function collectAdmissionSignals(sb:any){
  const errors:string[]=[];
  const recovery=await sb.from('director_external_evidence')
    .select('status,verified,updated_at')
    .eq('project_key','contentflow')
    .eq('evidence_type','recovery_certification')
    .order('updated_at',{ascending:false})
    .limit(1)
    .maybeSingle();
  if(recovery.error)errors.push(`recovery:${recovery.error.message}`);

  const activeRuns=await sb.from('contentflow_builder_runs')
    .select('backlog_task_id,status')
    .in('status',['claimed','running','review_required'])
    .is('finished_at',null);
  if(activeRuns.error)errors.push(`active_runs:${activeRuns.error.message}`);
  const counts=new Map<number,number>();
  for(const r of activeRuns.data||[]){const id=Number(r.backlog_task_id);counts.set(id,(counts.get(id)||0)+1)}
  const ownershipConflicts=Array.from(counts.values()).filter(n=>n>1).length;

  const incidents=await sb.from('director_repair_incidents')
    .select('id',{count:'exact',head:true})
    .eq('project_key','contentflow')
    .in('status',['open','analyzing']);
  if(incidents.error)errors.push(`incidents:${incidents.error.message}`);

  const retries=await sb.from('contentflow_retry_state')
    .select('circuit_state')
    .eq('project_key','contentflow');
  if(retries.error)errors.push(`retry_state:${retries.error.message}`);
  const retryStates=(retries.data||[]).length;
  const openCircuits=(retries.data||[]).filter((r:any)=>String(r.circuit_state)==='open').length;

  const evidenceWait=await sb.from('contentflow_build_backlog')
    .select('id',{count:'exact',head:true})
    .eq('project_key','contentflow')
    .eq('status','WAITING_FOR_EVIDENCE_PRODUCER');
  if(evidenceWait.error)errors.push(`evidence_wait:${evidenceWait.error.message}`);

  const policy=await sb.from('director_control_policy')
    .select('desired_running')
    .eq('project_key','contentflow')
    .maybeSingle();
  if(policy.error)errors.push(`control_policy:${policy.error.message}`);

  const canary=await sb.from('director_canary_policy')
    .select('stable_parallelism')
    .eq('project_key','contentflow')
    .maybeSingle();
  if(canary.error)errors.push(`canary_policy:${canary.error.message}`);

  return {
    telemetryHealthy:errors.length===0,
    telemetryErrors:errors,
    recovery:{
      verified:Boolean(recovery.data?.verified),
      status:String(recovery.data?.status||''),
      verifiedAt:recovery.data?.updated_at||null
    },
    ownershipConflicts,
    openIncidents:Number(incidents.count||0),
    openCircuits,
    retryStates,
    waitingForEvidence:Number(evidenceWait.count||0),
    requestedParallelism:Number(policy.data?.desired_running||0),
    stableParallelism:Number(canary.data?.stable_parallelism||2)
  };
}

Deno.serve(async(req)=>{
  const H={'content-type':'application/json','cache-control':'no-store'};
  if(!['GET','POST'].includes(req.method))return new Response('{}',{status:405,headers:H});
  const url=Deno.env.get('SUPABASE_URL')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,sb=createClient(url,service,{auth:{persistSession:false}});
  const out:any={architecture:'MASTER_DIRECTOR_CONTROL_PLANE_V9_RECOVERY_AWARE',evidence_pre:null,tool_sync:null,evidence_tool_runs:[],recovery_pre:null,pre_reconcile:null,admission:null,planner:null,core_support:null,adaptive_dispatch:null,post_reconcile:null,evidence_post:null,recovery_post:null,review_workers_scheduled:0};
  try{
    const evPre=await sb.rpc('contentflow_evidence_first_reconcile',{p_project_key:'contentflow',p_limit:80});out.evidence_pre={data:evPre.data,error:evPre.error?.message||null};
    const ts=await sb.rpc('contentflow_sync_tool_execution_queue',{p_project_key:'contentflow'});out.tool_sync={data:ts.data,error:ts.error?.message||null};
    for(let i=0;i<2;i++){const r=await callInternal(url,service,'contentflow-evidence-tool-runner',5000);out.evidence_tool_runs.push(r);if((r as any)?.body?.status==='idle')break;}
    const evAfterTools=await sb.rpc('contentflow_evidence_first_reconcile',{p_project_key:'contentflow',p_limit:80});out.evidence_after_tools={data:evAfterTools.data,error:evAfterTools.error?.message||null};
    out.recovery_pre=await callInternal(url,service,'contentflow-throughput-recovery',9000);
    const pre=await sb.rpc('contentflow_master_reconcile',{p_project_key:'contentflow'});out.pre_reconcile={data:pre.data,error:pre.error?.message||null};

    const signals=await collectAdmissionSignals(sb);
    const admission=evaluateAutonomyAdmission(signals);
    out.admission={...admission,telemetry_errors:signals.telemetryErrors};

    let coreError:any=null;
    if(admission.admitted){
      try{
        const ctl=new AbortController(),t=setTimeout(()=>ctl.abort(),1200);
        const p=await fetch(`${url}/functions/v1/contentflow-capacity-planner`,{method:'POST',signal:ctl.signal,headers:{Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:'{}'});
        clearTimeout(t);out.planner={status:p.status,body:await p.json().catch(()=>({}))};
      }catch(e){out.planner={warning:String(e)}}
      const c=await sb.rpc('contentflow_director_core_cycle_auto',{p_project_key:'contentflow'});
      coreError=c.error;
      out.core_support={data:c.data,error:c.error?.message||null};
    }else{
      out.planner={skipped:true,reason:'autonomy_admission_denied'};
      out.core_support={skipped:true,reason:'recovery_aware_support_only',blockers:admission.blockers};
    }

    out.adaptive_dispatch=await callInternal(url,service,'contentflow-adaptive-dispatcher',7000);
    const post=await sb.rpc('contentflow_master_reconcile',{p_project_key:'contentflow'});out.post_reconcile={data:post.data,error:post.error?.message||null};
    const evPost=await sb.rpc('contentflow_evidence_first_reconcile',{p_project_key:'contentflow',p_limit:80});out.evidence_post={data:evPost.data,error:evPost.error?.message||null};
    out.recovery_post=await callInternal(url,service,'contentflow-throughput-recovery',9000);

    const {count:reviews}=await sb.from('contentflow_review_work_queue').select('builder_run_id',{count:'exact',head:true}).eq('state','pending').lte('available_at',new Date().toISOString());
    const n=Math.min(3,Number(reviews||0));out.review_workers_scheduled=n;
    if(n>0)EdgeRuntime.waitUntil(Promise.all(Array.from({length:n},async()=>{try{await fetch(`${url}/functions/v1/contentflow-rara`,{method:'POST',headers:{Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:'{}'})}catch{}})));
    else{
      const {count:incs}=await sb.from('director_repair_incidents').select('id',{count:'exact',head:true}).eq('project_key','contentflow').in('status',['open','analyzing']);
      if(Number(incs||0)>0){out.review_workers_scheduled=1;EdgeRuntime.waitUntil(fetch(`${url}/functions/v1/contentflow-rara`,{method:'POST',headers:{Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:'{}'}).catch(()=>null))}
    }

    const ok=!evPre.error&&!ts.error&&!evAfterTools.error&&!pre.error&&!coreError&&!post.error&&!evPost.error;
    return new Response(JSON.stringify({ok,architecture:'MASTER_DIRECTOR_CONTROL_PLANE_V9_RECOVERY_AWARE',out}),{status:ok?200:500,headers:H});
  }catch(e){
    return new Response(JSON.stringify({ok:false,error:String(e),architecture:'MASTER_DIRECTOR_CONTROL_PLANE_V9_RECOVERY_AWARE',out}),{status:500,headers:H});
  }
});
