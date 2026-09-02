--
-- PostgreSQL database dump
--

\restrict kXa32Te5YJ8WM2YE7YRN2EgaY2mqRL4tjYuNcjweu7MSrvL3lOeIlb777GIBd3d

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Ubuntu 17.11-1.pgdg24.04+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: academy_configure_web_runtime_executor_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.academy_configure_web_runtime_executor_v1() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_count int:=0;
begin
  update public.contentflow_build_backlog
  set execution_lane='tool_executor',
      status='ready',
      workflow_state='artifact_pending',
      completion_phase='runtime_verification',
      blocked_reason=null,
      next_eligible_at=now(),
      workflow_contract=workflow_contract || jsonb_build_object(
        'environment','live_public_web',
        'no_retry_without_new_evidence',false,
        'execution_recipe',jsonb_build_object(
          'handler','edge_function',
          'function','academy-web-runtime-evidence',
          'mode',case task_key
             when 'academy_web_analytics_runtime_evidence_v1' then 'analytics'
             when 'academy_web_accessibility_runtime_validation_v2' then 'accessibility'
             else 'error_loading' end,
          'target','academy_public_web',
          'deterministic',true
        )
      )
  where project_key='agent-academy-platform-v1'
    and task_key in (
      'academy_web_analytics_runtime_evidence_v1',
      'academy_web_accessibility_runtime_validation_v2',
      'academy_web_error_loading_runtime_validation_v2'
    );
  get diagnostics v_count=row_count;
  return jsonb_build_object('configured',v_count,'architecture','ACADEMY_PARALLEL_WEB_RUNTIME_EXECUTOR_V1');
end $$;


--
-- Name: academy_plan_execution_buffer_v1(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.academy_plan_execution_buffer_v1(p_project_key text DEFAULT 'agent-academy-platform-v1'::text, p_target integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_dispatchable int:=0;
  v_waiting int:=0;
  v_external_blockers int:=0;
  v_internal_blockers int:=0;
  v_tool_pending int:=0;
  v_review_pending int:=0;
  v_summary jsonb:='{}'::jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
  if p_project_key<>'agent-academy-platform-v1' then return jsonb_build_object('ok',false,'reason','academy_scope_only'); end if;

  select public.contentflow_dispatchable_count(p_project_key) into v_dispatchable;

  select count(*) into v_waiting
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.status in ('planned','ready','verification_required');

  select count(distinct d.id) into v_external_blockers
  from public.contentflow_build_backlog b
  cross join lateral jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
  join public.contentflow_build_backlog d on d.project_key=b.project_key and d.task_key=dep.value
  where b.project_key=p_project_key and b.status in ('planned','ready')
    and d.status='blocked'
    and coalesce(d.blocked_reason,'') like 'EXTERNAL_%';

  select count(distinct d.id) into v_internal_blockers
  from public.contentflow_build_backlog b
  cross join lateral jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
  join public.contentflow_build_backlog d on d.project_key=b.project_key and d.task_key=dep.value
  where b.project_key=p_project_key and b.status in ('planned','ready')
    and d.status not in ('completed','blocked');

  select count(*) into v_tool_pending from public.contentflow_tool_execution_queue q
  join public.contentflow_build_backlog b on b.id=q.backlog_task_id
  where q.project_key=p_project_key and q.state='pending' and b.status in ('blocked','ready');

  select count(*) into v_review_pending from public.contentflow_review_work_queue q
  join public.contentflow_builder_runs r on r.id=q.builder_run_id
  where r.project_key=p_project_key and q.state='pending' and q.available_at<=now();

  v_summary:=jsonb_build_object(
    'architecture','ACADEMY_IDLE_DEPENDENCY_AWARE_PLANNER_V1',
    'target',greatest(1,least(coalesce(p_target,10),20)),
    'dispatchable_llm',v_dispatchable,
    'waiting_tasks',v_waiting,
    'external_blocking_dependencies',v_external_blockers,
    'internal_blocking_dependencies',v_internal_blockers,
    'tool_pending',v_tool_pending,
    'review_pending',v_review_pending,
    'classification',case when v_dispatchable>0 then 'executable_work_available' when v_external_blockers>0 then 'dependency_blocked_not_idle' when v_waiting>0 then 'internal_dependency_wait' else 'true_idle' end
  );

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'academy_idle_plan','academy_dependency_aware_planner_v1','dependency_aware_support',
    case when v_dispatchable>0 then 'work_available' when v_external_blockers>0 then 'external_dependency_wait_preserve_parallel_support' when v_waiting>0 then 'internal_dependency_wait' else 'true_idle' end,
    false,v_summary::text,now());

  return v_summary;
end
$$;


--
-- Name: academy_security_remediation_canary_v2_once(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.academy_security_remediation_canary_v2_once() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
declare
  before_rls boolean; before_anon boolean; before_auth boolean; before_service boolean;
  during_rls boolean:=false; during_anon boolean:=true; during_auth boolean:=true; during_service boolean:=false;
  after_rls boolean; after_anon boolean; after_auth boolean; after_service boolean;
begin
  select c.relrowsecurity,
         has_table_privilege('anon','public.contentflow_capability_certifications','SELECT'),
         has_table_privilege('authenticated','public.contentflow_capability_certifications','SELECT'),
         has_table_privilege('service_role','public.contentflow_capability_certifications','SELECT')
    into before_rls,before_anon,before_auth,before_service
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='contentflow_capability_certifications';

  begin
    execute 'alter table public.contentflow_capability_certifications enable row level security';
    execute 'revoke all on public.contentflow_capability_certifications from anon, authenticated, public';
    select c.relrowsecurity,
           has_table_privilege('anon','public.contentflow_capability_certifications','SELECT'),
           has_table_privilege('authenticated','public.contentflow_capability_certifications','SELECT'),
           has_table_privilege('service_role','public.contentflow_capability_certifications','SELECT')
      into during_rls,during_anon,during_auth,during_service
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='contentflow_capability_certifications';
    if not during_rls or during_anon or during_auth or not during_service then
      raise exception 'CANARY_ASSERTION_FAILED';
    end if;
    raise exception 'CANARY_FORCE_ROLLBACK';
  exception
    when raise_exception then
      if sqlerrm not in ('CANARY_FORCE_ROLLBACK','CANARY_ASSERTION_FAILED') then raise; end if;
      if sqlerrm='CANARY_ASSERTION_FAILED' then
        return jsonb_build_object('ok',false,'phase','during','error','CANARY_ASSERTION_FAILED');
      end if;
  end;

  select c.relrowsecurity,
         has_table_privilege('anon','public.contentflow_capability_certifications','SELECT'),
         has_table_privilege('authenticated','public.contentflow_capability_certifications','SELECT'),
         has_table_privilege('service_role','public.contentflow_capability_certifications','SELECT')
    into after_rls,after_anon,after_auth,after_service
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='contentflow_capability_certifications';

  return jsonb_build_object(
    'ok', (before_rls=after_rls and before_anon=after_anon and before_auth=after_auth and before_service=after_service and during_rls and not during_anon and not during_auth and during_service),
    'suite','academy_security_remediation_canary_v2',
    'target','public.contentflow_capability_certifications',
    'mode','production_subtransaction_forced_rollback',
    'before',jsonb_build_object('rls',before_rls,'anon_select',before_anon,'authenticated_select',before_auth,'service_select',before_service),
    'during',jsonb_build_object('rls',during_rls,'anon_select',during_anon,'authenticated_select',during_auth,'service_select',during_service),
    'after',jsonb_build_object('rls',after_rls,'anon_select',after_anon,'authenticated_select',after_auth,'service_select',after_service),
    'no_persistent_target_mutation',true,
    'observed_at',now()
  );
end $$;


--
-- Name: academy_whatsapp_emit_director_help_alert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.academy_whatsapp_emit_director_help_alert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into public.director_help_alerts(
    project_key,task_key,component,error_class,error_fingerprint,attempts,status,summary,actions_tried
  ) values (
    'agent-academy-platform-v1',
    'academy_whatsapp_human_handoff',
    'academy-whatsapp-webhook',
    'HUMAN_RESPONSE_REQUIRED',
    'academy_whatsapp_handoff:'||new.id::text,
    0,
    'open',
    'WhatsApp Cygnus requires human response. handoff_id='||new.id::text||' reason='||new.reason,
    jsonb_build_array('truth_first_fallback_created','no_unverified_answer_sent')
  );
  return new;
end;
$$;


--
-- Name: academy_whatsapp_resolve_answer(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.academy_whatsapp_resolve_answer(p_text text, p_language text DEFAULT 'es'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v text := lower(coalesce(p_text,''));
  v_intent text := 'unknown';
  k public.academy_whatsapp_knowledge%rowtype;
  v_conf numeric := 0.40;
begin
  -- Specific user intents first. Generic identity/greeting are intentionally last
  -- so phrases such as “cuánto cuesta la academia” cannot be swallowed by “academia”.
  if v ~ '(precio|cuánto cuesta|cuanto cuesta|costo|mensualidad|pago|premium|membresía|membresia)' then v_intent:='pricing'; v_conf:=0.95;
  elsif v ~ '(inscrib|registro|registrar|entrar|acceso|unirme|unir|skool)' then v_intent:='enrollment'; v_conf:=0.90;
  elsif v ~ '(certificado|certificación|certificacion|diploma)' then v_intent:='certification'; v_conf:=0.93;
  elsif v ~ '(curso|cursos|clase|clases|programa|programas)' then v_intent:='courses'; v_conf:=0.88;
  elsif v ~ '(soporte|contacto|correo|email|ayuda|hablar con alguien|persona)' then v_intent:='support'; v_conf:=0.90;
  elsif v ~ '(página|pagina|web|sitio|website|url)' then v_intent:='website'; v_conf:=0.92;
  elsif v ~ '(método|metodo|cómo enseñan|como enseñan|aprendiendo haciendo|práctica|practica)' then v_intent:='methodology'; v_conf:=0.90;
  elsif v ~ '(qué es cygnus|que es cygnus|quienes son|quiénes son|qué es la academia|que es la academia|cygnus academy)' then v_intent:='identity'; v_conf:=0.90;
  elsif v ~ '(hola|buenas|buenos días|buenos dias|buenas tardes|buenas noches|hello|hi)' then v_intent:='greeting'; v_conf:=0.95;
  end if;

  select * into k from public.academy_whatsapp_knowledge
  where intent=v_intent and language=coalesce(nullif(p_language,''),'es') and active
  order by priority desc, updated_at desc limit 1;

  if not found then
    select * into k from public.academy_whatsapp_knowledge
    where intent='unknown' and language='es' and active order by priority desc limit 1;
    v_intent:='unknown'; v_conf:=0.30;
  end if;

  return jsonb_build_object(
    'intent',v_intent,
    'confidence',v_conf,
    'answer',k.answer_text,
    'knowledge_id',k.id,
    'requires_human',k.requires_human,
    'source_type',k.source_type,
    'source_ref',k.source_ref,
    'source_verified_at',k.source_verified_at
  );
end;
$$;


--
-- Name: attach_director_usage_to_running_orchestrator_task(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.attach_director_usage_to_running_orchestrator_task() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_task_id bigint;
  v_count integer;
begin
  select count(*), min(id)
    into v_count, v_task_id
  from public.orchestrator_tasks
  where user_id = new.user_id
    and project_key = new.project_key
    and status = 'running';

  if v_count = 1 and v_task_id is not null then
    update public.orchestrator_tasks
       set input_tokens = coalesce(new.input_tokens,0) + coalesce(new.judge_input_tokens,0),
           output_tokens = coalesce(new.output_tokens,0) + coalesce(new.judge_output_tokens,0)
     where id = v_task_id;
  end if;
  return new;
end;
$$;


--
-- Name: audit_builder_claim(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_builder_claim() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_token text:=gen_random_uuid()::text;
begin
  if old.status is distinct from new.status
     and new.status='running'
     and coalesce(new.execution_lane,'llm_artifact')='llm_artifact' then
    insert into public.contentflow_builder_runs(
      project_key,backlog_task_id,task_key,task_type,status,selected_model,
      lease_token,lease_generation,heartbeat_at,lease_expires_at,control_protocol
    ) values(
      new.project_key,new.id,new.task_key,new.task_type,'claimed',new.selected_model,
      v_token,1,now(),now()+interval '3 minutes','fenced-v2'
    );
  end if;
  return new;
end $$;


--
-- Name: avatar_product_progress_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.avatar_product_progress_v1() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
with x as (
 select b.status,b.task_key,b.quality_score,b.blocked_reason
 from public.contentflow_build_backlog b
 join public.director_project_task_scope s on s.project_key=b.project_key and s.task_key=b.task_key and s.counts_toward_progress=true
 where b.project_key='avatar-platform-v1'
)
select jsonb_build_object(
 'architecture','AVATAR_DURABLE_FANOUT_FANIN_V1',
 'total_product_tasks',count(*),
 'completed',count(*) filter(where status='completed'),
 'running',count(*) filter(where status='running'),
 'review_pending',count(*) filter(where status='blocked' and blocked_reason='REVIEW_PENDING'),
 'ready',count(*) filter(where status='ready'),
 'planned',count(*) filter(where status='planned'),
 'blocked_other',count(*) filter(where status='blocked' and coalesce(blocked_reason,'')<>'REVIEW_PENDING'),
 'percent_effective',round(100.0*count(*) filter(where status='completed')/nullif(count(*),0),1)
) from x;
$$;


--
-- Name: contentflow_academy_stale_state_watchdog_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_academy_stale_state_watchdog_v1(p_project_key text DEFAULT 'agent-academy-platform-v1'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_reopened int:=0; v_incidents int:=0; v_verify int:=0;
begin
  with candidates as (
    select id, task_key from public.contentflow_build_backlog
    where project_key=p_project_key
      and status='blocked'
      and execution_lane='llm_artifact'
      and coalesce(blocked_reason,'') in ('STATE_GUARD_BLOCKED_UNSPECIFIED','INTERNAL_STALE_STATE_GUARD_REVIEW_REQUIRED','')
      and updated_at < now()-interval '30 minutes'
  ), upd as (
    update public.contentflow_build_backlog b
    set status='ready', blocked_reason=null, next_eligible_at=now(), workflow_state='artifact_pending', updated_at=now(),
        patch_feedback=concat_ws(E'\n',nullif(patch_feedback,''),'AUTO_RECOVERY academy_stale_state_watchdog_v1 at '||now()::text)
    from candidates c where b.id=c.id returning b.task_key
  ) select count(*) into v_reopened from upd;

  insert into public.director_repair_incidents(project_key,task_key,component,error_class,error_fingerprint,symptom,evidence,risk_level)
  select p_project_key,b.task_key,'verifier','stale_verification','stale_verification:'||b.task_key,
         'verification_required exceeded 30 minutes without terminal decision',
         jsonb_build_object('status',b.status,'updated_at',b.updated_at,'workflow_state',b.workflow_state,'execution_lane',b.execution_lane,'runtime_verified',b.runtime_verified),
         'low'
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.status='verification_required' and b.updated_at<now()-interval '30 minutes'
    and not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='stale_verification:'||b.task_key and i.status in ('open','analyzing','repairing','validating','needs_help'))
  on conflict do nothing;
  get diagnostics v_verify=row_count;

  insert into public.director_repair_incidents(project_key,task_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,requires_human)
  select p_project_key,b.task_key,'dependency','stale_external_blocker','stale_external_blocker:'||b.task_key,
         coalesce(b.blocked_reason,'external blocker persisted beyond watchdog threshold'),
         jsonb_build_object('status',b.status,'updated_at',b.updated_at,'blocked_reason',b.blocked_reason,'hours_stale',round(extract(epoch from (now()-b.updated_at))/3600,1)),
         'low', true
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.status='blocked' and b.updated_at<now()-interval '2 hours'
    and coalesce(b.blocked_reason,'') not in ('STATE_GUARD_BLOCKED_UNSPECIFIED','INTERNAL_STALE_STATE_GUARD_REVIEW_REQUIRED','')
    and not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='stale_external_blocker:'||b.task_key and i.status in ('open','analyzing','repairing','validating','needs_help'))
  on conflict do nothing;
  get diagnostics v_incidents=row_count;

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes)
  values(p_project_key,'stale_state_watchdog','academy_stale_state_watchdog_v1','automatic_recovery',
         'reopened='||v_reopened||';stale_verification_incidents='||v_verify||';external_blocker_incidents='||v_incidents,
         (v_incidents>0),
         'Low-risk unspecified state guards reopen automatically; stale verifications become RARA incidents; external/human prerequisites remain fail-closed and are escalated explicitly.');

  return jsonb_build_object('reopened_internal',v_reopened,'verification_incidents',v_verify,'external_blocker_incidents',v_incidents);
end $$;


--
-- Name: contentflow_acquire_nexo_slot(text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_acquire_nexo_slot(p_lane text, p_model text, p_task_key text, p_timeout_seconds integer) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare v_phase smallint; v_global integer; v_lane integer; v_active_global integer; v_active_lane integer; v_slot uuid; begin if p_lane not in ('production','qa','recruitment','fallback') then raise exception 'invalid_lane'; end if; perform pg_advisory_xact_lock(hashtext('contentflow_nexo_capacity')); update contentflow_nexo_slots set released_at=now(),release_reason='expired' where released_at is null and expires_at<=now(); select s.active_phase,p.global_max,case p_lane when 'production' then p.production_max when 'qa' then p.qa_max when 'recruitment' then p.recruitment_max else p.fallback_max end into v_phase,v_global,v_lane from contentflow_capacity_state s join contentflow_capacity_phases p on p.phase=s.active_phase where s.id=1; select count(*) into v_active_global from contentflow_nexo_slots where released_at is null and expires_at>now(); select count(*) into v_active_lane from contentflow_nexo_slots where released_at is null and expires_at>now() and lane=p_lane; if v_active_global>=v_global or v_active_lane>=v_lane then return null; end if; insert into contentflow_nexo_slots(lane,model,task_key,expires_at) values(p_lane,p_model,p_task_key,now()+make_interval(secs=>greatest(p_timeout_seconds,30)+30)) returning slot_id into v_slot; return v_slot; end $$;


--
-- Name: contentflow_activity_begin_v1(bigint, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_activity_begin_v1(p_run_id bigint, p_lease_token text, p_runner_instance_id text, p_phase text, p_timeout_seconds integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; v_deadline timestamptz; v_lease_deadline timestamptz;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 if coalesce(p_phase,'')='' or p_timeout_seconds<10 or p_timeout_seconds>600 then raise exception 'invalid_activity_deadline'; end if;
 perform pg_advisory_xact_lock(hashtext('contentflow:run:'||p_run_id::text));
 select * into r from public.contentflow_builder_runs where id=p_run_id for update;
 if not found then return jsonb_build_object('ok',false,'reason','run_not_found'); end if;
 if r.lease_revoked_at is not null or r.lease_token is distinct from p_lease_token then return jsonb_build_object('ok',false,'reason','fenced_out'); end if;
 if r.runner_instance_id is not null and r.runner_instance_id is distinct from p_runner_instance_id then return jsonb_build_object('ok',false,'reason','runner_instance_mismatch'); end if;
 if r.status not in ('claimed','running') or r.finished_at is not null then return jsonb_build_object('ok',false,'reason','not_active'); end if;
 v_deadline:=now()+make_interval(secs=>p_timeout_seconds+30);
 v_lease_deadline:=v_deadline+interval '45 seconds';
 update public.contentflow_builder_runs
 set activity_phase=p_phase,
     activity_deadline_at=v_deadline,
     heartbeat_deadline_at=v_deadline,
     lease_expires_at=greatest(coalesce(lease_expires_at,now()),v_lease_deadline),
     activity_seq=activity_seq+1,
     heartbeat_at=now(),
     runner_instance_id=coalesce(runner_instance_id,p_runner_instance_id),
     status=case when status='claimed' then 'running' else status end,
     activity_checkpoint=jsonb_set(coalesce(activity_checkpoint,'{}'::jsonb),'{current_phase}',to_jsonb(p_phase),true)
 where id=p_run_id;
 insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
 values(p_run_id,r.task_key,'activity_started',r.idempotency_key,'builder_runner_v4',jsonb_build_object('phase',p_phase,'deadline_at',v_deadline,'lease_deadline_at',v_lease_deadline,'runner_instance_id',p_runner_instance_id,'seq',r.activity_seq+1)) on conflict do nothing;
 return jsonb_build_object('ok',true,'phase',p_phase,'deadline_at',v_deadline,'lease_deadline_at',v_lease_deadline);
end $$;


--
-- Name: contentflow_activity_complete_v1(bigint, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_activity_complete_v1(p_run_id bigint, p_lease_token text, p_runner_instance_id text, p_phase text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; v_checkpoint jsonb;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 perform pg_advisory_xact_lock(hashtext('contentflow:run:'||p_run_id::text));
 select * into r from public.contentflow_builder_runs where id=p_run_id for update;
 if not found then return jsonb_build_object('ok',false,'reason','run_not_found'); end if;
 if r.lease_revoked_at is not null or r.lease_token is distinct from p_lease_token or r.runner_instance_id is distinct from p_runner_instance_id then return jsonb_build_object('ok',false,'reason','fenced_out'); end if;
 v_checkpoint:=jsonb_set(coalesce(r.activity_checkpoint,'{}'::jsonb),array['completed',p_phase],to_jsonb(now()),true);
 v_checkpoint:=jsonb_set(v_checkpoint,'{last_completed_phase}',to_jsonb(p_phase),true);
 update public.contentflow_builder_runs
 set activity_phase=null,activity_deadline_at=null,heartbeat_at=now(),heartbeat_deadline_at=now()+interval '120 seconds',lease_expires_at=greatest(coalesce(lease_expires_at,now()),now()+interval '150 seconds'),activity_checkpoint=v_checkpoint
 where id=p_run_id;
 insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
 values(p_run_id,r.task_key,'activity_completed',r.idempotency_key,'builder_runner_v4',jsonb_build_object('phase',p_phase,'runner_instance_id',p_runner_instance_id,'checkpoint',v_checkpoint)) on conflict do nothing;
 return jsonb_build_object('ok',true,'checkpoint',v_checkpoint);
end $$;


--
-- Name: contentflow_admit_persistent_change_v1(uuid, text, text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_admit_persistent_change_v1(p_change_id uuid, p_git_commit_sha text, p_migration_name text, p_git_pr_number bigint DEFAULT NULL::bigint, p_evidence_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_row public.contentflow_persistent_change_provenance%rowtype;
begin
 select * into v_row from public.contentflow_persistent_change_provenance where change_id=p_change_id for update;
 if not found then raise exception 'persistent_change_not_found'; end if;
 if v_row.break_glass then raise exception 'break_glass_change_requires_quarantine_reconciliation'; end if;
 if v_row.status not in ('intent_registered','rejected') then raise exception 'persistent_change_not_admittable:%',v_row.status; end if;
 if coalesce(p_git_commit_sha,'') !~ '^[0-9a-f]{40}$' then raise exception 'valid_git_commit_sha_required'; end if;
 if coalesce(nullif(p_migration_name,''),'')='' then raise exception 'migration_name_required'; end if;
 update public.contentflow_persistent_change_provenance set git_commit_sha=lower(p_git_commit_sha),migration_name=p_migration_name,git_pr_number=coalesce(p_git_pr_number,git_pr_number),evidence_id=coalesce(nullif(p_evidence_id,''),evidence_id),status='admitted',admitted_at=now(),updated_at=now() where change_id=p_change_id;
 return jsonb_build_object('admitted',true,'change_id',p_change_id,'migration_name',p_migration_name,'git_commit_sha',lower(p_git_commit_sha));
end $_$;


--
-- Name: contentflow_apply_control_incident_strategy(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_apply_control_incident_strategy(p_incident_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare i public.director_repair_incidents%rowtype; s public.director_control_incident_strategy_state%rowtype; v_before jsonb; v_after jsonb; v_strategy text; v_detail jsonb:='{}'::jsonb; v_repaired boolean:=false; v_next int;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 select * into i from public.director_repair_incidents where id=p_incident_id for update;
 if not found then return jsonb_build_object('applied',false,'reason','incident_not_found'); end if;
 if i.error_class not in ('autonomy_no_progress','progress_stall','zero_throughput_semantic_deadlock') then return jsonb_build_object('applied',false,'reason','not_control_incident'); end if;
 if i.status not in ('open','analyzing') then return jsonb_build_object('applied',false,'reason','incident_not_actionable'); end if;
 insert into public.director_control_incident_strategy_state(project_key,incident_id,error_fingerprint) values(i.project_key,i.id,coalesce(i.error_fingerprint,i.error_class||':project')) on conflict(incident_id) do nothing;
 select * into s from public.director_control_incident_strategy_state where incident_id=i.id for update;
 if s.exhausted or s.strategy_index>=3 then
   update public.director_repair_incidents set status='needs_help',requires_human=true,max_attempts=3,attempts=least(attempts,3),outcome='control_strategy_budget_exhausted',updated_at=now() where id=i.id;
   return jsonb_build_object('applied',false,'reason','strategy_budget_exhausted','strategies_attempted',s.strategies_attempted);
 end if;
 v_before:=public.contentflow_control_incident_observation(i.project_key);
 v_next:=s.strategy_index+1;
 if v_next=1 then
   v_strategy:='progress_stall_reconcile';
   v_detail:=public.contentflow_progress_stall_reconcile(i.project_key);
 elsif v_next=2 then
   v_strategy:='runtime_state_reconcile';
   v_detail:=public.contentflow_reconcile_runtime_state(i.project_key);
 else
   v_strategy:='evidence_capability_reconcile';
   begin v_detail:=public.contentflow_reconcile_evidence_capability_queue(i.project_key); exception when undefined_function then v_detail:=jsonb_build_object('unavailable',true); end;
 end if;
 v_after:=public.contentflow_control_incident_observation(i.project_key);
 v_repaired:=coalesce((v_after->>'running')::int,0)>coalesce((v_before->>'running')::int,0)
          or coalesce((v_after->>'dispatchable')::int,0)>coalesce((v_before->>'dispatchable')::int,0)
          or (coalesce((v_before->>'ready')::int,0)>0 and coalesce((v_after->>'ready')::int,0)=0);
 update public.director_control_incident_strategy_state set strategy_index=v_next,last_strategy=v_strategy,strategies_attempted=strategies_attempted||to_jsonb(v_strategy),last_observation=v_after,exhausted=(v_next>=3 and not v_repaired),updated_at=now() where incident_id=i.id;
 insert into public.director_repair_actions(incident_id,action_type,action_payload,risk_level,status,result,error)
 values(i.id,v_strategy,jsonb_build_object('policy','CONTROL_INCIDENT_RETRY_POLICY_V1','strategy_index',v_next,'before',v_before),coalesce(i.risk_level,'low'),case when v_repaired then 'completed' else 'failed' end,jsonb_build_object('detail',v_detail,'after',v_after),case when v_repaired then null else 'control_strategy_no_progress' end);
 if v_repaired then
   update public.director_repair_incidents set status='resolved',resolved_at=now(),requires_human=false,attempts=v_next,max_attempts=3,executed_action=v_strategy,outcome='resolved_by_control_strategy',updated_at=now() where id=i.id;
 else
   update public.director_repair_incidents set status=case when v_next>=3 then 'needs_help' else 'open' end,requires_human=(v_next>=3),attempts=v_next,max_attempts=3,executed_action=v_strategy,outcome=case when v_next>=3 then 'control_strategy_budget_exhausted' else 'control_strategy_changed' end,updated_at=now() where id=i.id;
 end if;
 return jsonb_build_object('applied',true,'ok',v_repaired,'strategy',v_strategy,'strategy_index',v_next,'before',v_before,'after',v_after,'detail',v_detail,'exhausted',v_next>=3 and not v_repaired);
end $$;


--
-- Name: contentflow_apply_retry_policy(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_apply_retry_policy(p_run_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
 r public.contentflow_builder_runs%rowtype;
 b public.contentflow_build_backlog%rowtype;
 p public.contentflow_retry_policies%rowtype;
 s public.contentflow_retry_state%rowtype;
 cls text; att int; base_delay numeric; jitter numeric; delay_s int; next_at timestamptz;
 deps_complete boolean:=true;
 target_status text;
 late_judge_pass boolean:=false;
 late_runner_pass boolean:=false;
begin
 select * into r from public.contentflow_builder_runs where id=p_run_id;
 if not found or r.status not in ('failed','deferred') then return jsonb_build_object('applied',false,'reason','run_not_failed'); end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update;
 if not found then return jsonb_build_object('applied',false,'reason','backlog_missing'); end if;

 -- Durable async-ACK race guard: an old collector could mark a run quality=0/failed
 -- on the HTTP 202 acknowledgement while the async runner was still working.
 -- If the same run later emitted successful judge+runner completion events, that
 -- failure is transport/control-plane noise and must never reopen a quality circuit.
 if coalesce(r.error,'') ilike '%quality_or_cost_gate_failed%' then
   select
     coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='judge_completed'),false),
     coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='runner_completed'),false)
   into late_judge_pass,late_runner_pass
   from public.contentflow_runtime_event_ledger
   where builder_run_id=r.id;
   if late_judge_pass and late_runner_pass then
     delete from public.contentflow_retry_state where backlog_task_id=b.id;
     update public.contentflow_build_backlog
        set status=case when not exists(
              select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep)
              where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed')
            ) then 'ready' else 'planned' end,
            selected_model=null,blocked_reason=null,
            next_eligible_at=case when not exists(
              select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d2(dep)
              where not exists(select 1 from public.contentflow_build_backlog x2 where x2.project_key=b.project_key and x2.task_key=d2.dep and x2.status='completed')
            ) then now() else next_eligible_at end,
            updated_at=now()
      where id=b.id and status<>'completed';
     insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
     values(b.project_key,r.id,b.task_key,'false_quality_failure_tombstoned',r.idempotency_key,'director_retry_policy',
       jsonb_build_object('reason','async_ack_race','judge_pass',late_judge_pass,'runner_pass',late_runner_pass),r.trace_id)
     on conflict do nothing;
     return jsonb_build_object('applied',true,'action','false_quality_failure_tombstoned','run_id',r.id,'task_key',b.task_key);
   end if;
 end if;

 cls:=public.contentflow_classify_run_error(r.error);
 select * into p from public.contentflow_retry_policies where error_class=cls;
 select * into s from public.contentflow_retry_state where backlog_task_id=b.id for update;
 if found and s.last_run_id=r.id then return jsonb_build_object('applied',false,'reason','already_processed','class',cls,'attempt',s.attempt_count); end if;
 att:=case when found and s.error_class=cls then s.attempt_count+1 else 1 end;

 select not exists(
   select 1
   from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
   where not exists(
     select 1 from public.contentflow_build_backlog d
     where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
   )
 ) into deps_complete;

 if p.retryable and att<=p.max_attempts then
   base_delay:=least(p.max_backoff_seconds::numeric,p.initial_backoff_seconds*power(p.backoff_coefficient,att-1));
   jitter:=((('x'||substr(md5(b.task_key||':'||r.id::text),1,8))::bit(32)::bigint % 10001)::numeric/10000.0*2-1)*p.jitter_ratio;
   delay_s:=greatest(1,round(base_delay*(1+jitter))::int);
   next_at:=now()+make_interval(secs=>delay_s);
   target_status:=case when deps_complete then 'ready' else 'planned' end;
   insert into public.contentflow_retry_state(backlog_task_id,project_key,task_key,error_class,attempt_count,last_run_id,last_error,last_model,next_retry_at,circuit_state,circuit_open_until,updated_at)
   values(b.id,b.project_key,b.task_key,cls,att,r.id,r.error,r.selected_model,next_at,'cooldown',next_at,now())
   on conflict(backlog_task_id) do update set error_class=excluded.error_class,attempt_count=excluded.attempt_count,last_run_id=excluded.last_run_id,last_error=excluded.last_error,last_model=excluded.last_model,next_retry_at=excluded.next_retry_at,circuit_state='cooldown',circuit_open_until=excluded.circuit_open_until,updated_at=now();
   update public.contentflow_build_backlog
      set status=target_status,selected_model=null,next_eligible_at=next_at,updated_at=now()
    where id=b.id and status in ('failed','blocked','ready','planned');
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'retry_scheduled',r.idempotency_key,'director_retry_policy',jsonb_build_object('error_class',cls,'attempt',att,'delay_seconds',delay_s,'next_retry_at',next_at,'switch_model',p.switch_model_on_retry,'dependencies_complete',deps_complete,'target_status',target_status),r.trace_id)
   on conflict do nothing;
   return jsonb_build_object('applied',true,'action','retry_scheduled','class',cls,'attempt',att,'next_retry_at',next_at,'delay_seconds',delay_s,'dependencies_complete',deps_complete,'target_status',target_status);
 else
   insert into public.contentflow_retry_state(backlog_task_id,project_key,task_key,error_class,attempt_count,last_run_id,last_error,last_model,next_retry_at,circuit_state,circuit_open_until,updated_at)
   values(b.id,b.project_key,b.task_key,cls,att,r.id,r.error,r.selected_model,null,'open',null,now())
   on conflict(backlog_task_id) do update set error_class=excluded.error_class,attempt_count=excluded.attempt_count,last_run_id=excluded.last_run_id,last_error=excluded.last_error,last_model=excluded.last_model,next_retry_at=null,circuit_state='open',circuit_open_until=null,updated_at=now();
   update public.contentflow_build_backlog set status='blocked',selected_model=null,next_eligible_at=null,updated_at=now() where id=b.id and status in ('failed','ready','planned','blocked');
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'retry_blocked',r.idempotency_key,'director_retry_policy',jsonb_build_object('error_class',cls,'attempt',att,'retryable',p.retryable,'max_attempts',p.max_attempts),r.trace_id)
   on conflict do nothing;
   return jsonb_build_object('applied',true,'action','blocked_for_repair','class',cls,'attempt',att);
 end if;
end
$$;


--
-- Name: contentflow_assert_persistent_change_admission_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_assert_persistent_change_admission_v1(p_change_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_row public.contentflow_persistent_change_provenance%rowtype;
begin
 select * into v_row from public.contentflow_persistent_change_provenance where change_id=p_change_id;
 if not found then raise exception 'PERSISTENT_CHANGE_ADMISSION_DENIED:missing_change'; end if;
 if v_row.break_glass or v_row.status<>'admitted' or v_row.git_commit_sha is null or v_row.migration_name is null then raise exception 'PERSISTENT_CHANGE_ADMISSION_DENIED:%',jsonb_build_object('change_id',p_change_id,'status',v_row.status,'break_glass',v_row.break_glass,'has_git_sha',v_row.git_commit_sha is not null,'has_migration',v_row.migration_name is not null); end if;
 return jsonb_build_object('admitted',true,'change_id',p_change_id,'git_commit_sha',v_row.git_commit_sha,'migration_name',v_row.migration_name);
end $$;


--
-- Name: contentflow_assert_tenant_security_admission_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_assert_tenant_security_admission_v1(p_scope text DEFAULT 'customer_facing'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$ declare v jsonb; begin if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if; v:=public.contentflow_tenant_security_admission_v1(p_scope); if not coalesce((v->>'admitted')::boolean,false) then raise exception 'TENANT_SECURITY_ADMISSION_DENIED:%',v->'blockers'; end if; return v; end $$;


--
-- Name: contentflow_autonomous_continuation_gate(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_autonomous_continuation_gate(p_project_key text DEFAULT 'contentflow'::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare v_cycle integer; v_stage integer; v_created integer:=0; begin if p_project_key<>'contentflow' then return 0; end if; if exists(select 1 from public.contentflow_build_backlog where project_key=p_project_key and status in ('planned','ready','running','blocked') and task_key not like 'gap_gap_%') then return 0; end if; if not exists(select 1 from public.contentflow_build_backlog where project_key=p_project_key and task_key='panel_qa_v1' and status='completed' and quality_score>=85) then return 0; end if; update public.contentflow_continuation_state set last_cycle=last_cycle+1,last_generated_at=now(),updated_at=now() where project_key=p_project_key and enabled=true returning last_cycle into v_cycle; if v_cycle is null or v_cycle>1 then return 0; end if; select coalesce(max(stage),0)+1 into v_stage from public.contentflow_build_backlog where project_key=p_project_key and task_key not like 'gap_gap_%'; insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria) values (p_project_key,'autonomous_continuation','autocont_v1_runtime_health','Verificar salud operativa post-QA','Audita dispatcher, runner, cola HTTP, backlog legitimo, HELP y workers usando evidencia runtime verificable.','general',v_stage,jsonb_build_array('panel_qa_v1'),'auto:continuation','ready',100,'Informe factual PASS/NEEDS_EVIDENCE/BLOCKED; Quality Gate >=85.'), (p_project_key,'autonomous_continuation','autocont_v1_autonomy_regression','Validar regresion del ciclo autonomo','Verifica despacho, recoleccion, juicio y cierre sin intervencion humana, sin reactivar deferred ni crear gap_gap.','architecture',v_stage,jsonb_build_array('autocont_v1_runtime_health'),'auto:continuation','planned',99,'Cadena autonoma verificable; Quality Gate >=85.'), (p_project_key,'autonomous_continuation','autocont_v1_release_readiness','Emitir readiness de siguiente fase','Integra salud y autonomia para decidir GO/NO-GO de ContentFlow para recibir siguiente proyecto.','general',v_stage,jsonb_build_array('autocont_v1_autonomy_regression'),'auto:continuation','planned',98,'GO/NO-GO factual y siguiente accion; Quality Gate >=85.') on conflict(project_key,task_key) do nothing; get diagnostics v_created=row_count; return v_created; end $$;


--
-- Name: contentflow_autonomy_supervisor(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_autonomy_supervisor(p_project_key text DEFAULT 'contentflow'::text, p_max_dispatch integer DEFAULT 10) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select public.contentflow_director_core_cycle(p_project_key,p_max_dispatch);
$$;


--
-- Name: contentflow_backlog_state_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_backlog_state_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  durable boolean := false;
  evidence_external boolean := false;
  explicit_external boolean := false;
  no_retry_without_evidence boolean := false;
  internal_artifact boolean := false;
  circuit_open boolean := false;
begin
  durable := coalesce(new.workflow_contract->>'contract_version','') <> '';
  evidence_external := new.execution_lane='evidence_producer' and coalesce(new.workflow_contract->>'runtime_required','false')='true';
  explicit_external := coalesce(new.blocked_reason,'') like 'EXTERNAL_%' or coalesce(new.blocked_reason,'') like 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED';
  no_retry_without_evidence := coalesce(new.workflow_contract->>'no_retry_without_new_evidence','false')='true';
  internal_artifact := coalesce(new.execution_lane,'llm_artifact')='llm_artifact'
    and coalesce(new.workflow_contract->>'runtime_required','false')='false'
    and coalesce(new.workflow_contract->>'publish_allowed','false')<>'true';
  select exists(
    select 1 from public.contentflow_retry_state rs
    where rs.project_key=new.project_key and rs.task_key=new.task_key and rs.circuit_state='open'
  ) into circuit_open;

  if new.status='ready' then
    if exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required' and r.finished_at is null) then
      new.status := 'blocked';
      new.blocked_reason := 'REVIEW_PENDING';
      new.next_eligible_at := null;
    elsif circuit_open then
      new.status := 'blocked';
      new.blocked_reason := 'RETRY_CIRCUIT_OPEN';
      new.next_eligible_at := null;
    else
      new.blocked_reason := null;
      new.next_eligible_at := coalesce(new.next_eligible_at,now());
    end if;
  elsif new.status='blocked' then
    if coalesce(new.blocked_reason,'')='REVIEW_PENDING'
       or exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required' and r.finished_at is null) then
      new.blocked_reason := 'REVIEW_PENDING';
      new.next_eligible_at := null;
    elsif circuit_open then
      new.blocked_reason := 'RETRY_CIRCUIT_OPEN';
      new.next_eligible_at := null;
    elsif evidence_external or explicit_external or no_retry_without_evidence then
      if coalesce(new.blocked_reason,'')='' then
        new.blocked_reason := case
          when new.task_key ilike '%social%access%' then 'EXTERNAL_PREREQUISITE_SOCIAL_ACCESS'
          when new.task_key ilike '%gpu%workspace%' then 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED'
          else 'EXTERNAL_RUNTIME_EVIDENCE_REQUIRED'
        end;
      end if;
      new.next_eligible_at := null;
    elsif internal_artifact then
      new.status := 'ready';
      new.blocked_reason := null;
      new.workflow_state := coalesce(nullif(new.workflow_state,''),'artifact_pending');
      new.next_eligible_at := coalesce(new.next_eligible_at,now()+interval '5 seconds');
      new.patch_feedback := concat_ws(E'\n',nullif(new.patch_feedback,''),'AUTO_CLASSIFIED_INTERNAL_ARTIFACT_V2: generic block converted to READY; runtime/publication evidence not required.');
    elsif durable and new.workflow_state in ('patch_required','artifact_patch_required','retry_wait') then
      new.status := 'ready';
      new.blocked_reason := null;
      new.next_eligible_at := coalesce(new.next_eligible_at,now()+interval '15 seconds');
    else
      new.blocked_reason := coalesce(nullif(new.blocked_reason,''),'STATE_GUARD_BLOCKED_UNSPECIFIED');
      new.next_eligible_at := coalesce(new.next_eligible_at,now()+interval '7 minutes');
    end if;
  end if;
  return new;
end
$$;


--
-- Name: contentflow_block_on_help_alert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_block_on_help_alert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF new.status='open' AND (TG_OP='INSERT' OR old.status IS DISTINCT FROM 'open') THEN
    UPDATE public.contentflow_build_backlog
       SET status='blocked', updated_at=now()
     WHERE project_key=new.project_key
       AND task_key=new.task_key
       AND status<>'completed';

    INSERT INTO public.director_autonomy_events(
      project_key,event_type,task_key,error_fingerprint,source,
      assignment_mode,outcome,required_user_intervention,notes
    )
    SELECT new.project_key,'problem_escalated',new.task_key,new.error_fingerprint,
           'help-alert-trigger','autonomous','HELP',true,
           coalesce(new.last_error,new.summary)
    WHERE NOT EXISTS (
      SELECT 1
        FROM public.director_autonomy_events e
       WHERE e.project_key=new.project_key
         AND e.event_type='problem_escalated'
         AND e.task_key IS NOT DISTINCT FROM new.task_key
         AND e.error_fingerprint IS NOT DISTINCT FROM new.error_fingerprint
         AND e.outcome='HELP'
         AND e.created_at >= now()-interval '24 hours'
    );
  END IF;
  RETURN new;
END
$$;


--
-- Name: contentflow_blocked_project_watchdog_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_blocked_project_watchdog_v1() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  p record;
  v_result jsonb := '[]'::jsonb;
  v_cycle jsonb;
begin
  for p in
    select distinct b.project_key
    from public.contentflow_build_backlog b
    where b.status = 'blocked'
      and not exists (
        select 1
        from public.contentflow_build_backlog a
        where a.project_key = b.project_key
          and a.status in ('ready','planned','running','verification_required')
      )
  loop
    begin
      select to_jsonb(public.contentflow_director_core_cycle_auto(p.project_key)) into v_cycle;
      v_result := v_result || jsonb_build_array(jsonb_build_object('project_key',p.project_key,'cycled',true,'result',v_cycle));
    exception when others then
      v_result := v_result || jsonb_build_array(jsonb_build_object('project_key',p.project_key,'cycled',false,'error',sqlerrm));
    end;
  end loop;
  return jsonb_build_object('architecture','BLOCKED_PROJECT_RECOVERY_WATCHDOG_V1','projects',v_result);
end;
$$;


--
-- Name: contentflow_blocked_reason_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_blocked_reason_reconcile(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_dep int:=0; v_circuit int:=0; v_cap int:=0; v_queue int:=0; v_unknown int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;

  update public.contentflow_build_backlog b set blocked_reason='DEPENDENCY_INCOMPLETE',updated_at=now()
   where b.project_key=p_project_key and b.status='blocked'
   and exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
              where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'));
  get diagnostics v_dep=row_count;

  update public.contentflow_build_backlog b set blocked_reason='CIRCUIT_OPEN',updated_at=now()
   where b.project_key=p_project_key and b.status='blocked'
   and exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open');
  get diagnostics v_circuit=row_count;

  update public.contentflow_build_backlog b set blocked_reason='CAPABILITY_NOT_AVAILABLE',updated_at=now()
   where b.project_key=p_project_key and b.status='blocked'
   and b.execution_lane in ('tool_executor','evidence_producer')
   and not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key);
  get diagnostics v_cap=row_count;

  update public.contentflow_build_backlog b set blocked_reason='EXECUTION_QUEUE_BLOCKED:'||coalesce(q.last_error,'UNSPECIFIED'),updated_at=now()
   from public.contentflow_tool_execution_queue q
   where q.backlog_task_id=b.id and q.project_key=p_project_key and q.state='blocked'
     and b.project_key=p_project_key and b.status='blocked'
     and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open')
     and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
                    where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'));
  get diagnostics v_queue=row_count;

  update public.contentflow_build_backlog b set blocked_reason='BLOCKED_UNCLASSIFIED',updated_at=now()
   where b.project_key=p_project_key and b.status='blocked' and coalesce(trim(b.blocked_reason),'')='';
  get diagnostics v_unknown=row_count;

  return jsonb_build_object('architecture','BLOCKED_REASON_COMPLETENESS_V1','dependency',v_dep,'circuit',v_circuit,'capability',v_cap,'queue',v_queue,'unclassified_filled',v_unknown);
end $$;


--
-- Name: contentflow_builder_heartbeat(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_builder_heartbeat(p_run_id bigint, p_extend_seconds integer DEFAULT 180) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare r public.contentflow_builder_runs%rowtype; begin if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if; if p_extend_seconds<30 or p_extend_seconds>600 then raise exception 'invalid_lease_extension'; end if; select * into r from public.contentflow_builder_runs where id=p_run_id for update; if not found then raise exception 'run_not_found'; end if; if r.status not in ('claimed','running','review_required') or r.finished_at is not null then return jsonb_build_object('ok',false,'reason','not_active'); end if; update public.contentflow_builder_runs set heartbeat_at=now(),lease_expires_at=now()+make_interval(secs=>p_extend_seconds),status=case when status='claimed' then 'running' else status end where id=p_run_id; insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload) values(p_run_id,r.task_key,'heartbeat',r.idempotency_key,'builder_runner',jsonb_build_object('lease_expires_at',now()+make_interval(secs=>p_extend_seconds))) on conflict do nothing; return jsonb_build_object('ok',true,'run_id',p_run_id,'lease_expires_at',now()+make_interval(secs=>p_extend_seconds)); end $$;


--
-- Name: FUNCTION contentflow_builder_heartbeat(p_run_id bigint, p_extend_seconds integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.contentflow_builder_heartbeat(p_run_id bigint, p_extend_seconds integer) IS 'LEGACY_QUARANTINED: canonical ownership heartbeat is fenced contentflow_builder_heartbeat_v2/activity protocol';


--
-- Name: contentflow_builder_heartbeat_v2(bigint, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_builder_heartbeat_v2(p_run_id bigint, p_lease_token text, p_runner_instance_id text, p_extend_seconds integer DEFAULT 180) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; v_lease timestamptz; v_hb_deadline timestamptz;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 if p_extend_seconds<60 or p_extend_seconds>600 then raise exception 'invalid_lease_extension'; end if;
 if coalesce(p_lease_token,'')='' or coalesce(p_runner_instance_id,'')='' then return jsonb_build_object('ok',false,'reason','ownership_required'); end if;
 select * into r from public.contentflow_builder_runs where id=p_run_id for update;
 if not found then return jsonb_build_object('ok',false,'reason','run_not_found'); end if;
 if r.lease_revoked_at is not null or r.lease_token is distinct from p_lease_token then return jsonb_build_object('ok',false,'reason','fenced_out','lease_generation',r.lease_generation); end if;
 if r.runner_instance_id is not null and r.runner_instance_id is distinct from p_runner_instance_id then return jsonb_build_object('ok',false,'reason','runner_instance_mismatch','lease_generation',r.lease_generation); end if;
 if r.status not in ('claimed','running') or r.finished_at is not null then return jsonb_build_object('ok',false,'reason','not_active'); end if;
 v_lease:=now()+make_interval(secs=>p_extend_seconds);
 v_hb_deadline:=now()+interval '75 seconds';
 update public.contentflow_builder_runs set heartbeat_at=now(),heartbeat_deadline_at=v_hb_deadline,lease_expires_at=v_lease,runner_instance_id=coalesce(runner_instance_id,p_runner_instance_id),heartbeat_seq=heartbeat_seq+1,status=case when status='claimed' then 'running' else status end where id=p_run_id;
 insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
 values(p_run_id,r.task_key,'heartbeat',r.idempotency_key,'builder_runner_v4',jsonb_build_object('lease_generation',r.lease_generation,'runner_instance_id',p_runner_instance_id,'heartbeat_deadline_at',v_hb_deadline)) on conflict do nothing;
 return jsonb_build_object('ok',true,'run_id',p_run_id,'lease_generation',r.lease_generation,'heartbeat_deadline_at',v_hb_deadline);
end $$;


--
-- Name: contentflow_builder_result_identity_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_builder_result_identity_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare cleaned text;begin
 if new.result is not null and new.id is not null then
   cleaned:=public.contentflow_strip_internal_execution_identity(new.id,new.result);
   if cleaned is distinct from new.result then
     new.result:=cleaned;
   end if;
 end if;
 return new;
end$$;


--
-- Name: contentflow_builder_span_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_builder_span_identity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ begin
 if new.span_id is null then new.span_id:=public.contentflow_make_span_id(); end if;
 return new;
end $$;


--
-- Name: contentflow_canonical_error_class(text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_canonical_error_class(p_project_key text, p_task_key text, p_error_class text, p_symptom text, p_evidence jsonb) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_lane text;
begin
  if coalesce(p_error_class,'unknown') <> 'unknown' then return p_error_class; end if;
  if p_task_key is not null then
    select coalesce(execution_lane,'llm_artifact') into v_lane
    from public.contentflow_build_backlog
    where project_key=p_project_key and task_key=p_task_key
    order by id desc limit 1;
  end if;
  if coalesce(p_symptom,'') ilike '%timeout%' then return 'builder_timeout'; end if;
  if coalesce(p_symptom,'') ilike '%quality gate%' or coalesce(p_symptom,'') ilike '%quality_gate%' then return 'quality_gate'; end if;
  if coalesce(p_symptom,'') ilike '%review%' and coalesce(p_symptom,'') ilike '%stall%' then return 'review_gate_stalled'; end if;
  if p_task_key is null and (coalesce(p_symptom,'') ilike '%progress%' or coalesce(p_symptom,'') ilike '%stall%') then return 'progress_stall'; end if;
  if v_lane='tool_executor' then return 'acceptance_evidence'; end if;
  if coalesce(p_evidence::text,'') ilike '%needs_evidence%' or coalesce(p_symptom,'') ilike '%evidence%' then return 'acceptance_evidence'; end if;
  return 'unknown';
end $$;


--
-- Name: contentflow_capability_certification_after_run_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_capability_certification_after_run_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status='completed' and coalesce(new.review_approved,false)=true and (old.status is distinct from new.status or old.review_approved is distinct from new.review_approved) then
    perform public.contentflow_reconcile_capability_certifications(new.project_key);
  end if;
  return new;
end $$;


--
-- Name: contentflow_capability_first_plan(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_capability_first_plan(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ begin if p_project_key<>'contentflow' then return jsonb_build_object('ok',true,'architecture','INFRASTRUCTURE_PLANNER_SCOPE_GUARD_V1','scope','contentflow_only','project_key',p_project_key,'skipped',true); end if; return public.contentflow_capability_first_plan_internal_v1(p_project_key); end $$;


--
-- Name: contentflow_capability_first_plan_internal_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_capability_first_plan_internal_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare rec record; k text; created_n int:=0; deferred_n int:=0; begin
 for rec in
   select distinct public.contentflow_evidence_prerequisite_class(r.requirement_class,r.requirement_text) as prereq
   from public.contentflow_evidence_requirements r
   join public.contentflow_build_backlog b on b.project_key=r.project_key and b.task_key=r.evidence_task_key
   left join public.contentflow_evidence_capability_registry c on c.prerequisite=public.contentflow_evidence_prerequisite_class(r.requirement_class,r.requirement_text)
   where r.project_key=p_project_key
     and b.status in ('blocked','ready','planned')
     and coalesce(c.producer_available,false)=false
     and public.contentflow_evidence_prerequisite_class(r.requirement_class,r.requirement_text) in ('runtime_persistence','source_contract','runtime_test','static_analysis','deployment_trace','repo_and_runtime_test')
 loop
   k:='capability_'||regexp_replace(rec.prereq,'[^a-zA-Z0-9_]+','_','g')||'_producer_source_v1';
   if not exists(select 1 from public.contentflow_build_backlog where project_key=p_project_key and task_key=k) then
     insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,execution_lane,completion_phase,runtime_verified)
     values(p_project_key,'capability_bootstrap',k,'Implement source contract for missing capability: '||rec.prereq,
       'Implement a reusable bounded source artifact for capability '||rec.prereq||'. Do not hardcode builder_run_id, evidence IDs, task IDs, credentials, or prior-run identifiers. Define interfaces, validation, error handling, idempotency/fencing where relevant, and an explicit certification hook. This task is SOURCE-ONLY: do not claim deployment, runtime execution, persisted evidence, or capability activation.',
       case when rec.prereq in ('runtime_persistence','runtime_test','static_analysis','deployment_trace','repo_and_runtime_test') then 'code' else 'architecture' end,
       1,'[]'::jsonb,'Director capability bootstrap','ready',100,
       'A complete reusable source/implementation artifact exists for the capability, contains no run-specific hardcoded IDs, defines deterministic inputs/outputs and certification hook, and makes no claim of live deployment or runtime certification.',
       'llm_artifact','artifact_only',false);
     created_n:=created_n+1;
   end if;
 end loop;
 update public.contentflow_build_backlog b set status='deferred',updated_at=now()
 where b.project_key=p_project_key and b.task_key in ('capability_source_contract_producer_v1','capability_runtime_persistence_producer_v1') and b.status='blocked';
 get diagnostics deferred_n=row_count;
 return jsonb_build_object('architecture','CAPABILITY_FIRST_PLANNING_V1','created_source_bootstraps',created_n,'deferred_circular_bootstraps',deferred_n,'missing_capabilities',(select jsonb_agg(x.prereq order by x.prereq) from (select distinct public.contentflow_evidence_prerequisite_class(r.requirement_class,r.requirement_text) prereq from public.contentflow_evidence_requirements r join public.contentflow_build_backlog b on b.project_key=r.project_key and b.task_key=r.evidence_task_key left join public.contentflow_evidence_capability_registry c on c.prerequisite=public.contentflow_evidence_prerequisite_class(r.requirement_class,r.requirement_text) where r.project_key=p_project_key and b.status in ('blocked','ready','planned') and coalesce(c.producer_available,false)=false) x));
end $$;


--
-- Name: contentflow_capacity_evaluate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_capacity_evaluate() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare v_phase smallint; v_started timestamptz; v_auto boolean; v_requests integer; v_success numeric; v_429 integer; v_upstream integer; v_timeouts integer; v_p95 numeric; v_to smallint; v_reason text; begin select active_phase,phase_started_at,auto_scale into v_phase,v_started,v_auto from contentflow_capacity_state where id=1; if not v_auto then return jsonb_build_object('changed',false,'reason','autoscale_disabled','phase',v_phase); end if; select count(*),coalesce(100.0*count(*) filter(where success)/nullif(count(*),0),0),count(*) filter(where status_code=429),count(*) filter(where error_class='UPSTREAM'),count(*) filter(where error_class='TIMEOUT'),coalesce(percentile_cont(0.95) within group(order by latency_ms),0) into v_requests,v_success,v_429,v_upstream,v_timeouts,v_p95 from contentflow_nexo_request_metrics where created_at>=greatest(v_started,now()-interval '6 hours') and lane in ('production','qa','fallback'); v_to:=v_phase; v_reason:='hold'; if v_requests>=100 and now()-v_started>=interval '6 hours' then if (v_429>greatest(2,ceil(v_requests*0.01)) or v_upstream>greatest(2,ceil(v_requests*0.02)) or v_timeouts>greatest(2,ceil(v_requests*0.02)) or v_success<95) and v_phase>1 then v_to:=v_phase-1; v_reason:='degrade_due_error_rate'; elsif v_success>=98 and v_429=0 and v_upstream<=greatest(1,floor(v_requests*0.01)) and v_timeouts<=greatest(1,floor(v_requests*0.01)) and v_p95<=120000 and v_phase<3 then v_to:=v_phase+1; v_reason:='scale_up_stable_metrics'; end if; end if; if v_to<>v_phase then update contentflow_capacity_state set active_phase=v_to,phase_started_at=now(),updated_at=now() where id=1; insert into contentflow_capacity_decisions(from_phase,to_phase,reason,metrics) values(v_phase,v_to,v_reason,jsonb_build_object('requests',v_requests,'success_pct',v_success,'rate_limit_429',v_429,'upstream',v_upstream,'timeouts',v_timeouts,'p95_latency_ms',v_p95)); end if; return jsonb_build_object('changed',v_to<>v_phase,'from_phase',v_phase,'to_phase',v_to,'reason',v_reason,'requests',v_requests,'success_pct',v_success,'rate_limit_429',v_429,'upstream',v_upstream,'timeouts',v_timeouts,'p95_latency_ms',v_p95); end $$;


--
-- Name: contentflow_checkpoint_stage(bigint, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_checkpoint_stage(p_backlog_task_id bigint, p_stage_name text, p_stage_state text, p_error_class text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_checkpoint jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare b public.contentflow_build_backlog%rowtype;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;
 select * into b from public.contentflow_build_backlog where id=p_backlog_task_id;
 if not found then return jsonb_build_object('ok',false,'reason','task_not_found'); end if;
 insert into public.contentflow_durable_task_stages(backlog_task_id,project_key,task_key,stage_name,stage_state,attempts,artifact_version,last_error_class,last_error,checkpoint,updated_at)
 values(b.id,b.project_key,b.task_key,p_stage_name,p_stage_state,case when p_stage_state in ('running','rejected','failed') then 1 else 0 end,b.artifact_version,p_error_class,left(p_error,2000),coalesce(p_checkpoint,'{}'::jsonb),now())
 on conflict(backlog_task_id,stage_name) do update set stage_state=excluded.stage_state,attempts=public.contentflow_durable_task_stages.attempts+case when excluded.stage_state in ('running','rejected','failed') then 1 else 0 end,artifact_version=excluded.artifact_version,last_error_class=excluded.last_error_class,last_error=excluded.last_error,checkpoint=public.contentflow_durable_task_stages.checkpoint||excluded.checkpoint,updated_at=now();
 update public.contentflow_build_backlog set last_checkpoint_at=now() where id=b.id;
 return jsonb_build_object('ok',true,'task_key',b.task_key,'stage',p_stage_name,'state',p_stage_state);
end $$;


--
-- Name: contentflow_claim_direct_tool_execution_task(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_claim_direct_tool_execution_task(p_project_key text DEFAULT 'contentflow'::text) RETURNS TABLE(queue_id bigint, backlog_task_id bigint, task_key text, title text, description text, acceptance_criteria text, task_type text, claim_token uuid, workflow_contract jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare qid bigint; bid bigint; tok uuid:=gen_random_uuid();
begin
 select q.id,b.id into qid,bid
 from public.contentflow_tool_execution_queue q
 join public.contentflow_build_backlog b on b.id=q.backlog_task_id
 where q.project_key=p_project_key and q.state='pending' and q.attempts<12
   and b.status in ('blocked','ready')
   and b.execution_lane='tool_executor'
   and public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key)
   and (b.next_eligible_at is null or b.next_eligible_at<=now())
   and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required'))
   and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'))
 order by public.contentflow_dependency_impact_score(b.project_key,b.task_key) desc,b.priority desc,b.id asc
 for update of q,b skip locked limit 1;
 if qid is null then return; end if;
 update public.contentflow_tool_execution_queue set state='claimed',claim_token=tok,claimed_at=now(),attempts=attempts+1,updated_at=now() where id=qid and state='pending' and attempts<12;
 if not found then return; end if;
 update public.contentflow_build_backlog set status='running',blocked_reason=null,updated_at=now() where id=bid and status in ('blocked','ready') and execution_lane='tool_executor';
 if not found then update public.contentflow_tool_execution_queue set state='blocked',claim_token=null,claimed_at=null,updated_at=now(),last_error='BACKLOG_CLAIM_FAILED' where id=qid and claim_token=tok; return; end if;
 return query select q.id,b.id,b.task_key,b.title,b.description,b.acceptance_criteria,b.task_type,tok,b.workflow_contract from public.contentflow_tool_execution_queue q join public.contentflow_build_backlog b on b.id=q.backlog_task_id where q.id=qid and q.claim_token=tok;
end
$$;


--
-- Name: contentflow_claim_tool_execution_task(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_claim_tool_execution_task(p_project_key text DEFAULT 'contentflow'::text) RETURNS TABLE(queue_id bigint, backlog_task_id bigint, task_key text, title text, description text, acceptance_criteria text, task_type text, claim_token uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare qid bigint; bid bigint; tok uuid:=gen_random_uuid();
begin
 select q.id,b.id into qid,bid
 from public.contentflow_tool_execution_queue q
 join public.contentflow_build_backlog b on b.id=q.backlog_task_id
 where q.project_key=p_project_key and q.state='pending' and q.attempts<12
   and b.status in ('blocked','ready')
   and b.execution_lane='evidence_producer'
   and public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key)
   and (b.next_eligible_at is null or b.next_eligible_at<=now())
   and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required'))
   and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'))
 order by public.contentflow_dependency_impact_score(b.project_key,b.task_key) desc,b.priority desc,b.id asc
 for update of q,b skip locked limit 1;
 if qid is null then return; end if;
 update public.contentflow_tool_execution_queue set state='claimed',claim_token=tok,claimed_at=now(),attempts=attempts+1,updated_at=now() where id=qid and state='pending' and attempts<12;
 if not found then return; end if;
 update public.contentflow_build_backlog set status='running',blocked_reason=null,updated_at=now() where id=bid and status in ('blocked','ready') and execution_lane='evidence_producer';
 if not found then update public.contentflow_tool_execution_queue set state='blocked',claim_token=null,claimed_at=null,updated_at=now(),last_error='BACKLOG_CLAIM_FAILED' where id=qid and claim_token=tok; return; end if;
 return query select q.id,b.id,b.task_key,b.title,b.description,b.acceptance_criteria,b.task_type,tok from public.contentflow_tool_execution_queue q join public.contentflow_build_backlog b on b.id=q.backlog_task_id where q.id=qid and q.claim_token=tok;
end
$$;


--
-- Name: contentflow_classify_execution_lane_fields(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_classify_execution_lane_fields(p_task_type text, p_description text, p_acceptance text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
 select case
   when coalesce(p_description,'') ~* '(produce REAL, persisted, correlated evidence|evidence harness:)'
     or coalesce(p_acceptance,'') ~* '(correlated to source task|do not fabricate evidence|generic LLM prose.*do not satisfy)'
     then 'evidence_producer'
   when coalesce(p_description,'') ~* '(verify persisted evidence|deterministic verifier|verify runtime evidence)'
     or coalesce(p_acceptance,'') ~* '(verify persisted evidence|deterministic verification)'
     then 'tool_executor'
   else 'llm_artifact'
 end;
$$;


--
-- Name: contentflow_classify_run_error(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_classify_run_error(p_error text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
 select case
   when coalesce(p_error,'') ilike '%artifact_truncated%' or coalesce(p_error,'') ilike '%TRUNCATED_RESPONSE%' then 'artifact_truncation'
   when coalesce(p_error,'') ilike '%ARTIFACT_DEFECT%' or coalesce(p_error,'') ilike '%syntax error%' or coalesce(p_error,'') ilike '%prevents compilation%' then 'artifact_defect'
   when coalesce(p_error,'') ilike '%EXTERNAL_APPROVAL_WAIT%' then 'acceptance_evidence'
   when coalesce(p_error,'') ilike '%nexo_lane_capacity_limited%' or coalesce(p_error,'') ilike '%capacity%' or coalesce(p_error,'') ilike '%429%' or coalesce(p_error,'') ilike '%rate_limit%' then 'capacity'
   when coalesce(p_error,'') ilike '%judge_unavailable%' or coalesce(p_error,'') ilike '%judge_unavailable_or_unparseable%' then 'judge'
   when coalesce(p_error,'') ilike '%no_catalog_model_executable%' or coalesce(p_error,'') ilike '%worker_transport_failed%' or coalesce(p_error,'') ilike '%transport_failed%' or coalesce(p_error,'') ilike '%worker_provider_failed%' or coalesce(p_error,'') ilike '%provider_failed%' or coalesce(p_error,'') ilike '%runner_response_parse_failed%' or coalesce(p_error,'') ilike '%runner_response_parse%' or coalesce(p_error,'') ilike '%execution_failed%' then 'provider'
   when coalesce(p_error,'') ilike '%timeout%' or coalesce(p_error,'') ilike '%120000 ms%' then 'timeout'
   when coalesce(p_error,'') ilike '%ORPHAN_CLAIM%' or coalesce(p_error,'') ilike '%lease_expired%' or coalesce(p_error,'') ilike '%LEASE_REVOKED%' or coalesce(p_error,'') ilike '%stale_claim%' or coalesce(p_error,'') ilike '%worker_claim_race%' or coalesce(p_error,'') ilike '%fenced_out%' then 'state_recovery'
   when coalesce(p_error,'') ilike '%RARA_ARTIFACT_REVIEW_REJECTED%' or coalesce(p_error,'') ilike '%RARA_REVIEW_REJECTED%' then 'quality_review'
   when coalesce(p_error,'') ilike '%quality_or_cost_gate_failed%' then 'quality_gate'
   when coalesce(p_error,'') ilike '%REVIEW_REJECTED_AUTONOMOUS_SLA%' or coalesce(p_error,'') ilike '%Evidence not correlated%' or coalesce(p_error,'') ilike '%evidence missing%' or coalesce(p_error,'') ilike '%missing platform evidence%' or coalesce(p_error,'') ilike '%acceptance criterion%' then 'acceptance_evidence'
   else 'unknown' end;
$$;


--
-- Name: contentflow_clear_completed_block_residue(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_clear_completed_block_residue(p_project_key text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  update public.contentflow_build_backlog
     set blocked_reason=null,
         next_eligible_at=null,
         updated_at=now()
   where status='completed'
     and (p_project_key is null or project_key=p_project_key)
     and (blocked_reason is not null or next_eligible_at is not null);
  get diagnostics n=row_count;
  return jsonb_build_object('ok',true,'cleaned',n,'project_key',p_project_key);
end $$;


--
-- Name: contentflow_clear_retry_after_repair(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_clear_retry_after_repair(p_task_key text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  return public.contentflow_clear_retry_after_repair(p_task_key,'contentflow');
end
$$;


--
-- Name: contentflow_clear_retry_after_repair(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_clear_retry_after_repair(p_task_key text, p_project_key text DEFAULT 'contentflow'::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_last_run_id bigint;
begin
  select max(id) into v_last_run_id
  from public.contentflow_builder_runs
  where project_key=p_project_key and task_key=p_task_key and finished_at is not null;

  update public.contentflow_retry_state
     set attempt_count=0,
         last_run_id=coalesce(v_last_run_id,last_run_id),
         last_error=null,
         next_retry_at=null,
         circuit_state='closed',
         circuit_open_until=null,
         updated_at=now()
   where project_key=p_project_key and task_key=p_task_key;

  update public.contentflow_build_backlog
     set next_eligible_at=now(),
         blocked_reason=null,
         updated_at=now()
   where project_key=p_project_key and task_key=p_task_key
     and status in ('ready','blocked','planned');
  return found;
end
$$;


--
-- Name: contentflow_close_incident_on_evidence_verified(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_close_incident_on_evidence_verified() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status='verified' and old.status is distinct from new.status then
    update public.director_repair_incidents i
       set status='resolved',resolved_at=coalesce(i.resolved_at,now()),updated_at=now(),requires_human=false,
           validation='all persisted evidence requirements verified',outcome='resolved_by_evidence_reconciliation',
           executed_action=coalesce(i.executed_action,'evidence requirements reconciled automatically')
     where i.project_key=new.project_key
       and i.task_key=new.task_key
       and i.error_class='acceptance_evidence'
       and i.status in ('open','analyzing','needs_help')
       and exists(select 1 from public.contentflow_build_backlog b where b.id=new.backlog_task_id and b.runtime_verified=true)
       and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=new.project_key and er.backlog_task_id=new.backlog_task_id and er.status<>'verified');
  end if;
  return new;
end
$$;


--
-- Name: contentflow_completion_evidence_mode_v3(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_completion_evidence_mode_v3(p_task_key text, p_title text, p_description text, p_acceptance text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
with s as (select lower(coalesce(p_task_key,'')||' '||coalesce(p_title,'')||' '||coalesce(p_description,'')||' '||coalesce(p_acceptance,'')) txt)
select case
  when lower(coalesce(p_task_key,'')) like 'repair_evidence_req_%' or lower(coalesce(p_title,'')) like 'produce real evidence%' then 'evidence_activity'
  when txt ~ '(manual approval|human approval|owner approval|security team approval|sign.?off|authorization required)' then 'external_approval'
  when txt ~ '(version-controlled|version control|commit sha|commit hash|repository|repo link|file path|merged with sha|merged into|yaml file|json schema|/patterns/|\.yaml|\.json|\.md)' and txt ~ '(runtime|integration test|test execution|curl|http [245][0-9][0-9]|endpoint|middleware is invoked|runtime trace|runtime log)' then 'repo_and_runtime_test'
  when txt ~ '(runtime trace|runtime log|persisted runtime|database record|read.?back|evidence store|durable storage)' then 'runtime_persistence'
  when txt ~ '(integration test|unit test|test suite|test corpus|test execution|curl|dev environment|endpoint returns|http 403|http 404|http 410|middleware is invoked|actual execution|required.*runtime|runtime verification)' then 'runtime_test'
  when txt ~ '(static analysis|lint|mypy|scanner|scan report|irreversible operation|machine-readable report.*line number)' then 'static_analysis'
  when txt ~ '(version-controlled|version control|commit sha|commit hash|repository|repo link|file path|merged with sha|merged into|yaml file|json schema|/patterns/|\.yaml|\.json|\.md)' then 'repo_commit_or_file'
  when txt ~ '(deploy|deployment|staging|production trace)' then 'deployment_trace'
  when txt ~ '(specification includes|protocol spec|document .*specif|decision record .*document|mapping section|schema structure|validation rules|contract semantics|architecture contract)' then 'artifact_review_only'
  else 'unclassified' end from s;
$$;


--
-- Name: contentflow_contract_runtime_required(jsonb, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_contract_runtime_required(p_contract jsonb, p_task_type text, p_title text, p_description text, p_acceptance_criteria text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select case
    when coalesce(p_contract,'{}'::jsonb) ? 'runtime_required'
      then coalesce((p_contract->>'runtime_required')::boolean,false)
    when coalesce(p_contract->>'contract_version','')<>''
      then false
    else public.contentflow_requires_runtime_evidence(p_task_type,p_title,p_description,p_acceptance_criteria)
  end
$$;


--
-- Name: contentflow_control_incident_observation(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_control_incident_observation(p_project_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_ready int:=0; v_running int:=0; v_workers int:=0; v_dispatchable int:=0; v_last_progress timestamptz;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 select count(*) into v_ready from public.contentflow_build_backlog where project_key=p_project_key and status='ready';
 select count(*) into v_running from public.director_worker_queue where status='running';
 select count(*) into v_workers from public.director_worker_queue where status='ready';
 begin v_dispatchable:=public.contentflow_dispatchable_count(p_project_key); exception when others then v_dispatchable:=0; end;
 select max(updated_at) into v_last_progress from public.contentflow_build_backlog where project_key=p_project_key and status='completed' and task_key not like 'gap_gap_%';
 return jsonb_build_object('ready',v_ready,'running',v_running,'workers_ready',v_workers,'dispatchable',v_dispatchable,'last_progress',v_last_progress);
end $$;


--
-- Name: contentflow_control_lease_acquire_v1(text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_control_lease_acquire_v1(p_project_key text, p_holder_token text, p_ttl_seconds integer DEFAULT 90) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
declare v_ok boolean:=false; v_ttl int:=greatest(30,least(coalesce(p_ttl_seconds,90),300));
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 if coalesce(p_project_key,'')='' or coalesce(p_holder_token,'')='' then raise exception 'invalid_control_lease'; end if;
 perform pg_advisory_xact_lock(hashtext('contentflow:control-lease:'||p_project_key));
 update private.contentflow_control_leases
    set holder_token=p_holder_token,acquired_at=now(),expires_at=now()+make_interval(secs=>v_ttl)
  where project_key=p_project_key and (expires_at<=now() or holder_token=p_holder_token);
 if found then return true; end if;
 begin
   insert into private.contentflow_control_leases(project_key,holder_token,acquired_at,expires_at)
   values(p_project_key,p_holder_token,now(),now()+make_interval(secs=>v_ttl));
   v_ok:=true;
 exception when unique_violation then
   v_ok:=false;
 end;
 return v_ok;
end $$;


--
-- Name: contentflow_control_lease_release_v1(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_control_lease_release_v1(p_project_key text, p_holder_token text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 delete from private.contentflow_control_leases where project_key=p_project_key and holder_token=p_holder_token;
 return found;
end $$;


--
-- Name: contentflow_current_workflow_version(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_current_workflow_version(p_project_key text DEFAULT 'contentflow'::text) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((select version from public.director_workflow_versions where project_key=p_project_key and status='active' order by activated_at desc nulls last,created_at desc limit 1),'director-core-v2');
$$;


--
-- Name: contentflow_default_artifact_contract_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_default_artifact_contract_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if coalesce(new.workflow_contract,'{}'::jsonb)='{}'::jsonb then
    if coalesce(new.description,'') ~* '(specification only unless runtime evidence exists|do not claim live deployment or runtime evidence unless persisted evidence exists|do not fabricate image assets or claim that they exist|bounded implementation artifact)' then
      new.workflow_contract := jsonb_build_object(
        'contract_version','1',
        'runtime_required',false,
        'evidence_policy','declared_gaps_allowed',
        'artifact_kind',coalesce(nullif(new.task_type,''),'artifact')
      );
    end if;
  end if;
  return new;
end
$$;


--
-- Name: contentflow_deferred_progress_watchdog_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_deferred_progress_watchdog_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_total int:=0;
  v_obsolete int:=0;
  v_due int:=0;
  v_missing_wakeup int:=0;
  v_reactivated int:=0;
  v_incident_created int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;

  select count(*) into v_total
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred';

  select count(*) into v_obsolete
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred'
    and coalesce(blocked_reason,'') like 'OBSOLETE%';

  select count(*) into v_due
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred'
    and next_eligible_at is not null and next_eligible_at<=now()
    and coalesce(blocked_reason,'') not like 'OBSOLETE%';

  update public.contentflow_build_backlog
     set status='ready', blocked_reason=null, updated_at=now()
   where project_key=p_project_key and status='deferred'
     and next_eligible_at is not null and next_eligible_at<=now()
     and coalesce(blocked_reason,'') not like 'OBSOLETE%';
  get diagnostics v_reactivated=row_count;

  select count(*) into v_missing_wakeup
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred'
    and next_eligible_at is null
    and coalesce(blocked_reason,'') not like 'OBSOLETE%';

  if v_missing_wakeup>0 and not exists (
    select 1 from public.director_repair_incidents
    where project_key=p_project_key
      and error_fingerprint='deferred_missing_wakeup:v1'
      and status in ('open','analyzing','repairing','validating','needs_help')
  ) then
    insert into public.director_repair_incidents(
      project_key,component,error_class,error_fingerprint,symptom,evidence,
      risk_level,status,max_attempts,requires_human,root_cause,proposed_action
    ) values (
      p_project_key,'director_control','deferred_progress_stall','deferred_missing_wakeup:v1',
      'Deferred tasks exist without an explicit wake-up condition',
      jsonb_build_object('deferred_total',v_total,'obsolete',v_obsolete,'missing_wakeup',v_missing_wakeup,'due_reactivated',v_reactivated),
      'medium','open',3,false,
      'Deferred state lacks next_eligible_at or an explicit terminal/obsolete reason',
      'Classify each deferred task and assign an explicit wake-up condition, dependency, or obsolete terminal reason'
    );
    get diagnostics v_incident_created=row_count;
  end if;

  insert into public.director_autonomy_events(
    project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at
  ) values (
    p_project_key,'deferred_progress_watchdog','master_director_v3','durable_wait_contract',
    case when v_missing_wakeup=0 then 'healthy' else 'repair_required' end,
    false,
    jsonb_build_object('deferred_total',v_total,'obsolete',v_obsolete,'due',v_due,'reactivated',v_reactivated,'missing_wakeup',v_missing_wakeup,'incident_created',v_incident_created)::text,
    now()
  );

  return jsonb_build_object(
    'architecture','DEFERRED_PROGRESS_WATCHDOG_V1',
    'deferred_total',v_total,
    'obsolete',v_obsolete,
    'due',v_due,
    'reactivated',v_reactivated,
    'missing_wakeup',v_missing_wakeup,
    'incident_created',v_incident_created
  );
end $$;


--
-- Name: contentflow_dependency_impact_score(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_dependency_impact_score(p_project_key text, p_task_key text) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
with recursive walk(task_key) as (
  select b.task_key
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key
    and b.status not in ('completed','deferred')
    and exists (
      select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
      where d.value=p_task_key
    )
  union
  select b.task_key
  from public.contentflow_build_backlog b
  join walk w on exists (
    select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
    where d.value=w.task_key
  )
  where b.project_key=p_project_key
    and b.status not in ('completed','deferred')
)
select count(distinct task_key)::int from walk;
$$;


--
-- Name: contentflow_dependency_release_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_dependency_release_reconcile(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare released int:=0; held_deps int:=0; held_circuit int:=0; held_capability int:=0;
begin
  update public.contentflow_build_backlog b
     set status='ready',updated_at=now(),selected_model=null,blocked_reason=null,next_eligible_at=now()
   where b.project_key=p_project_key
     and b.status='blocked'
     and coalesce(b.blocked_reason,'') in ('','STATE_GUARD_BLOCKED_UNSPECIFIED','DEPENDENCY_INCOMPLETE')
     and (b.next_eligible_at is null or b.next_eligible_at<=now())
     and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open')
     and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value) where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'))
     and (coalesce(b.execution_lane,'llm_artifact') not in ('tool_executor','evidence_producer') or public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key));
  get diagnostics released=row_count;
  select count(*) into held_deps from public.contentflow_build_backlog b where b.project_key=p_project_key and b.status='blocked' and exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value) where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'));
  select count(*) into held_circuit from public.contentflow_build_backlog b where b.project_key=p_project_key and b.status='blocked' and exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open');
  select count(*) into held_capability from public.contentflow_build_backlog b where b.project_key=p_project_key and b.status='blocked' and coalesce(b.execution_lane,'llm_artifact') in ('tool_executor','evidence_producer') and not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key);
  perform public.contentflow_sync_tool_execution_queue(p_project_key);
  return jsonb_build_object('architecture','DEPENDENCY_RELEASE_RECONCILIATION_V2_EXTERNAL_BLOCKER_SAFE','released',released,'held_by_dependencies',held_deps,'held_by_circuit',held_circuit,'held_by_capability',held_capability);
end
$$;


--
-- Name: contentflow_detect_zero_throughput_deadlock(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_detect_zero_throughput_deadlock(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_ready int; v_dispatch int; v_workers int; v_running int; v_recent int; v_exists boolean;
begin
 select count(*) into v_ready from public.contentflow_build_backlog where project_key=p_project_key and status='ready';
 select count(*) into v_dispatch from public.contentflow_build_backlog b where b.project_key=p_project_key and b.status in ('planned','ready') and coalesce(b.execution_lane,'llm_artifact')='llm_artifact' and (b.next_eligible_at is null or b.next_eligible_at<=now()) and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'));
 select count(*) into v_workers from public.director_worker_queue where status='ready';
 select count(*) into v_running from public.contentflow_builder_runs where status in ('claimed','running') and finished_at is null;
 select count(*) into v_recent from public.contentflow_builder_runs where created_at>=now()-interval '30 minutes';
 v_exists := v_ready>0 and v_workers>0 and v_running=0 and v_recent=0 and v_dispatch=0;
 if v_exists and not exists(select 1 from public.director_repair_incidents where project_key=p_project_key and error_fingerprint='zero_throughput_semantic_deadlock:project' and status in ('open','analyzing','repairing','validating','needs_help')) then
   insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,root_cause,proposed_action)
   values(p_project_key,'routing','zero_throughput_semantic_deadlock','zero_throughput_semantic_deadlock:project','Ready work and workers exist but no dispatchable/running/recent work exists',jsonb_build_object('ready',v_ready,'dispatchable',v_dispatch,'workers_ready',v_workers,'running',v_running,'recent_runs_30m',v_recent),'low','Semantic routing/dependency deadlock: work is present but the routing contract exposes no executable path.','progress_stall_reconcile');
 end if;
 return jsonb_build_object('deadlock',v_exists,'ready',v_ready,'dispatchable',v_dispatch,'workers_ready',v_workers,'running',v_running,'recent_runs_30m',v_recent);
end
$$;


--
-- Name: contentflow_direct_tool_recipe_autorelease_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_direct_tool_recipe_autorelease_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.execution_lane='tool_executor'
     and coalesce((new.workflow_contract->>'runtime_required')::boolean,false)=true
     and new.workflow_contract ? 'execution_recipe'
     and jsonb_typeof(new.workflow_contract->'execution_recipe')='object'
     and coalesce(new.workflow_contract->'execution_recipe'->>'handler','') in ('database_rpc','edge_function') then
    update public.contentflow_tool_execution_queue
       set state='pending',last_error=null,claim_token=null,claimed_at=null,updated_at=now()
     where backlog_task_id=new.id
       and state='blocked'
       and last_error='CONTRACT_WAIT:direct_tool_execution_recipe_missing';
    if new.status='blocked' and coalesce(new.blocked_reason,'')='CONTRACT_WAIT:direct_tool_execution_recipe_missing' then
      new.status:='ready';
      new.blocked_reason:=null;
      new.next_eligible_at:=now();
    end if;
  end if;
  return new;
end;
$$;


--
-- Name: contentflow_director_core_cycle(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_director_core_cycle(p_project_key text DEFAULT 'contentflow'::text, p_max_dispatch integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
declare
  v_cycle_id bigint;
  v_lock_key bigint := hashtextextended('contentflow_director_core:'||coalesce(p_project_key,'contentflow'),0);
  v_locked boolean := false;
  v_warnings jsonb := '[]'::jsonb;
  v_orphan jsonb := '{}'::jsonb;
  v_normalized jsonb := '{}'::jsonb;
  v_reconciled jsonb := '{}'::jsonb;
  v_reviews jsonb := '{}'::jsonb;
  v_known jsonb := '{}'::jsonb;
  v_detected integer := 0;
  v_leases integer := 0;
  v_ready integer := 0;
  v_running integer := 0;
  v_dispatchable integer := 0;
  v_req bigint;
  v_dispatched integer := 0;
  v_i integer;
  v_pre jsonb := '{}'::jsonb;
  v_post jsonb := '{}'::jsonb;
  v_mismatch integer := 0;
  v_status text := 'completed';
  v_err text;
  v_production_max integer := 1;
  v_global_max integer := 1;
  v_allowed integer := 0;
  v_plan jsonb := '{}'::jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  p_max_dispatch := greatest(0,least(coalesce(p_max_dispatch,10),10));
  v_locked := pg_try_advisory_xact_lock(v_lock_key);
  if not v_locked then
    insert into public.director_cycle_runs(project_key,status,phase,finished_at,warnings)
    values(p_project_key,'skipped_locked','lock',now(),jsonb_build_array('another_director_cycle_is_active')) returning id into v_cycle_id;
    return jsonb_build_object('ok',true,'status','skipped_locked','cycle_id',v_cycle_id);
  end if;
  insert into public.director_cycle_runs(project_key,status,phase) values(p_project_key,'running','reconcile') returning id into v_cycle_id;

  begin v_orphan := public.contentflow_recover_orphan_claims(p_project_key,45); exception when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','orphan_recovery','error',sqlerrm)); end;
  begin v_normalized := public.contentflow_normalize_dispatchability(p_project_key); exception when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','normalize_dispatchability','error',sqlerrm)); end;
  begin v_reconciled := public.contentflow_reconcile_runtime_state(p_project_key); exception when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','runtime_reconcile','error',sqlerrm)); end;
  begin v_leases := public.contentflow_recover_expired_leases(p_project_key); exception when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','expired_leases','error',sqlerrm)); end;
  begin v_reviews := public.contentflow_review_gate_reconcile(p_project_key); exception when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','review_gate','error',sqlerrm)); end;

  begin perform public.contentflow_precycle_evidence_reconcile(p_project_key); exception when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','evidence_precycle','error',sqlerrm)); end;
  update public.director_cycle_runs set phase='support' where id=v_cycle_id;
  begin v_detected:=public.rara_detect_incidents(p_project_key); exception when unique_violation then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','rara_detect','error','duplicate_incident_suppressed')); when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','rara_detect','error',sqlerrm)); end;
  begin v_known:=public.rara_apply_known_repairs(p_project_key,20); exception when others then v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','rara_known_repairs','error',sqlerrm)); end;

  select count(*) into v_ready from public.director_worker_queue where status='ready';
  select count(*) into v_running from public.director_worker_queue where status='running';
  begin v_dispatchable:=public.contentflow_dispatchable_count(p_project_key); exception when others then v_dispatchable:=0; v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','dispatchable_count','error',sqlerrm)); end;
  if v_ready>0 and v_running=0 and v_dispatchable=0 and p_max_dispatch>0 then
    begin
      perform public.contentflow_plan_capability_certification_block(p_project_key);
      v_plan:=public.contentflow_plan_execution_buffer(p_project_key,greatest(2,least(v_ready,p_max_dispatch)));
      perform public.contentflow_capability_first_plan(p_project_key);
      perform public.contentflow_precycle_evidence_reconcile(p_project_key);
      v_dispatchable:=public.contentflow_dispatchable_count(p_project_key);
      insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
      values(p_project_key,'idle_replan','director_core','plan_before_idle',case when v_dispatchable>0 then 'work_released' else 'no_executable_leaf' end,false,v_plan::text,now());
    exception when others then
      v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','idle_replan','error',sqlerrm));
    end;
  end if;
  begin select production_max,global_max into v_production_max,v_global_max from public.contentflow_nexo_lane_status limit 1; exception when others then v_production_max:=1; v_global_max:=1; v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','capacity_read','error',sqlerrm)); end;
  v_production_max:=greatest(1,coalesce(v_production_max,1));
  v_global_max:=greatest(v_production_max,coalesce(v_global_max,v_production_max));

  -- p_max_dispatch is the GLOBAL active-worker cap, not a per-cycle dispatch allowance.
  v_allowed:=greatest(0,least(
    p_max_dispatch-v_running,
    v_ready,
    v_dispatchable,
    v_production_max-v_running,
    v_global_max-v_running
  ));
  v_pre:=jsonb_build_object('workers_ready',v_ready,'workers_running',v_running,'dispatchable',v_dispatchable,'production_max',v_production_max,'global_max',v_global_max,'master_parallelism_cap',p_max_dispatch,'dispatch_allowed',v_allowed,'orphan_recovery',v_orphan,'expired_leases_recovered',v_leases,'reviews',v_reviews,'rara_detected',v_detected,'rara_known',v_known);
  update public.director_cycle_runs set phase='dispatch',pre_state=v_pre where id=v_cycle_id;

  if v_allowed>0 then
    for v_i in 1..v_allowed loop
      begin
        v_req:=public.internal_builder_dispatch();
        exit when v_req is null;
        v_dispatched:=v_dispatched+1;
      exception when unique_violation then
        v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','dispatch','error','claim_uniqueness_collision_suppressed','iteration',v_i));
      when others then
        v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','dispatch','error',sqlerrm,'iteration',v_i));
      end;
    end loop;
  end if;

  update public.director_cycle_runs set phase='verify',dispatched=v_dispatched where id=v_cycle_id;
  select count(*) into v_mismatch
  from public.contentflow_builder_runs r
  left join public.contentflow_build_backlog b on b.id=r.backlog_task_id
  left join public.director_worker_queue q on q.model_id=r.selected_model
  where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null
    and (r.heartbeat_at is null or r.lease_expires_at is null or r.lease_expires_at<=now() or b.status<>'running' or b.selected_model is distinct from r.selected_model or q.status<>'running' or q.current_task_key is distinct from r.task_key);
  select count(*) into v_ready from public.director_worker_queue where status='ready';
  select count(*) into v_running from public.director_worker_queue where status='running';
  begin v_dispatchable:=public.contentflow_dispatchable_count(p_project_key); exception when others then v_dispatchable:=0; end;
  v_post:=jsonb_build_object('workers_ready',v_ready,'workers_running',v_running,'dispatchable',v_dispatchable,'active_state_mismatches',v_mismatch,'production_max',v_production_max,'master_parallelism_cap',p_max_dispatch,'capacity_respected',case when p_max_dispatch=0 then v_running<=v_production_max else v_running<=least(v_production_max,p_max_dispatch) end,'dispatch_mode',case when p_max_dispatch=0 then 'support_only' else 'active' end);
  if v_mismatch>0 then v_status:='completed_with_warnings'; v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','verify','error','active_state_invariant_failed','count',v_mismatch)); end if;
  if p_max_dispatch>0 and v_running>p_max_dispatch then v_status:='completed_with_warnings'; v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','verify','error','master_parallelism_cap_exceeded','running',v_running,'cap',p_max_dispatch)); end if;
  if v_running>v_production_max then v_status:='completed_with_warnings'; v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object('phase','verify','error','legacy_overcapacity_active','running',v_running,'production_max',v_production_max)); end if;
  if jsonb_array_length(v_warnings)>0 and v_status='completed' then v_status:='completed_with_warnings'; end if;
  update public.director_cycle_runs set status=v_status,phase='done',finished_at=now(),post_state=v_post,warnings=v_warnings,dispatched=v_dispatched where id=v_cycle_id;
  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'director_core_cycle','director_core','serialized_state_machine',v_status,false,format('cycle=%s dispatched=%s ready=%s running=%s dispatchable=%s production_max=%s master_cap=%s mismatches=%s warnings=%s',v_cycle_id,v_dispatched,v_ready,v_running,v_dispatchable,v_production_max,p_max_dispatch,v_mismatch,jsonb_array_length(v_warnings)),now());
  return jsonb_build_object('ok',true,'status',v_status,'cycle_id',v_cycle_id,'dispatched',v_dispatched,'pre',v_pre,'post',v_post,'warnings',v_warnings);
exception when others then
  v_err:=sqlerrm;
  if v_cycle_id is not null then update public.director_cycle_runs set status='failed',phase='failed',finished_at=now(),error=v_err,warnings=v_warnings where id=v_cycle_id; end if;
  return jsonb_build_object('ok',false,'status','failed','cycle_id',v_cycle_id,'error',v_err,'warnings',v_warnings);
end
$$;


--
-- Name: contentflow_director_core_cycle_auto(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_director_core_cycle_auto(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '35s'
    AS $$
declare p int; r jsonb;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 perform set_config('contentflow.project_key',coalesce(nullif(p_project_key,''),'contentflow'),true);
 p:=public.contentflow_recommended_parallelism(p_project_key);
 r:=public.contentflow_director_core_cycle(p_project_key,p);
 return coalesce(r,'{}'::jsonb)||jsonb_build_object('canary_parallelism',p,'workflow_version',public.contentflow_current_workflow_version(p_project_key),'dispatch_project_context',coalesce(nullif(p_project_key,''),'contentflow'));
end $$;


--
-- Name: contentflow_dispatch_capability_e2e_certification(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_dispatch_capability_e2e_certification(p_builder_run_id bigint, p_capability text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$ declare v_secret text; v_req bigint; begin if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if; if p_capability not in ('runtime_persistence','source_contract','runtime_test','registry_bridge') then raise exception 'unsupported_capability'; end if; select runner_secret into v_secret from public.contentflow_internal_runner_config where id=1; if v_secret is null then raise exception 'runner_secret_missing'; end if; select net.http_post(url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-capability-e2e-certifier',headers:=jsonb_build_object('Content-Type','application/json','X-ContentFlow-Internal',v_secret),body:=jsonb_build_object('builder_run_id',p_builder_run_id,'capability',p_capability),timeout_milliseconds:=120000) into v_req; perform net.wake(); return v_req; end $$;


--
-- Name: contentflow_dispatch_capability_review_finalizer(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_dispatch_capability_review_finalizer(p_builder_run_id bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$
declare v_secret text; v_req bigint;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
 select runner_secret into v_secret from public.contentflow_internal_runner_config where id=1;
 if v_secret is null then raise exception 'runner_secret_missing'; end if;
 select net.http_post(
   url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-capability-review-finalizer',
   headers:=jsonb_build_object('Content-Type','application/json','X-ContentFlow-Internal',v_secret),
   body:=jsonb_build_object('builder_run_id',p_builder_run_id),
   timeout_milliseconds:=120000
 ) into v_req;
 perform net.wake();
 return v_req;
end $$;


--
-- Name: contentflow_dispatch_director_autonomy_certification(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_dispatch_director_autonomy_certification(p_builder_run_id bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$
declare v_secret text; v_req bigint;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
 select runner_secret into v_secret from public.contentflow_internal_runner_config where id=1;
 if v_secret is null then raise exception 'runner_secret_missing'; end if;
 select net.http_post(
   url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-director-autonomy-certifier',
   headers:=jsonb_build_object('Content-Type','application/json','X-ContentFlow-Internal',v_secret),
   body:=jsonb_build_object('builder_run_id',p_builder_run_id),
   timeout_milliseconds:=120000
 ) into v_req;
 perform net.wake();
 return v_req;
end $$;


--
-- Name: contentflow_dispatchable_count(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_dispatchable_count(p_project_key text DEFAULT 'contentflow'::text) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
 select count(*)::int
 from public.contentflow_build_backlog b
 where b.project_key=p_project_key
   and b.status in ('planned','ready')
   and coalesce(b.execution_lane,'llm_artifact')='llm_artifact'
   and b.task_key not like 'gap_gap_%'
   and (b.next_eligible_at is null or b.next_eligible_at<=now())
   and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open')
   and not exists(select 1 from public.contentflow_builder_runs ar where ar.backlog_task_id=b.id and ar.status in ('claimed','running','review_required','verification_required') and ar.finished_at is null)
   and not exists(
     select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
     where not exists(
       select 1 from public.contentflow_build_backlog d
       where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
     )
   );
$$;


--
-- Name: contentflow_durable_contract_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_durable_contract_reconcile(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare reopened int:=0; obsolete_evidence int:=0; deps_removed int:=0; incidents_resolved int:=0; rec record; rc int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;

 -- Only optional/legacy evidence may be obsoleted. Explicit required evidence policies
 -- and workflow_contract.required_external_evidence are durable and must survive reconciliation.
 update public.contentflow_evidence_requirements er
 set status='obsolete',updated_at=now()
 from public.contentflow_build_backlog b
 where er.backlog_task_id=b.id and b.project_key=p_project_key
   and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'')
   and coalesce(b.workflow_contract->>'evidence_policy','declared_gaps_allowed') not in ('required','verified_evidence_required')
   and jsonb_array_length(coalesce(b.workflow_contract->'required_external_evidence','[]'::jsonb))=0
   and er.status in ('open','task_created');
 get diagnostics obsolete_evidence=row_count;

 for rec in
   select b.id,b.project_key,b.depends_on,b.workflow_contract
   from public.contentflow_build_backlog b
   where b.project_key=p_project_key
     and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'')
     and coalesce(b.workflow_contract->>'evidence_policy','declared_gaps_allowed') not in ('required','verified_evidence_required')
     and jsonb_array_length(coalesce(b.workflow_contract->'required_external_evidence','[]'::jsonb))=0
 loop
   update public.contentflow_build_backlog as t
      set depends_on=coalesce(t.depends_on,'[]'::jsonb)-e.task_key,updated_at=now()
     from public.contentflow_build_backlog as e
    where t.id=rec.id
      and e.project_key=rec.project_key
      and e.task_key in (select jsonb_array_elements_text(coalesce(rec.depends_on,'[]'::jsonb)))
      and (e.epic='evidence_first' or e.execution_lane in ('tool_executor','evidence_producer'))
      and e.status<>'completed';
   get diagnostics rc=row_count;
   deps_removed:=deps_removed+rc;
 end loop;

 update public.contentflow_build_backlog e
 set status='deferred',blocked_reason='OBSOLETE_BY_DURABLE_CONTRACT_V3',updated_at=now()
 where e.project_key=p_project_key
   and (e.epic='evidence_first' or e.execution_lane in ('tool_executor','evidence_producer'))
   and e.status in ('ready','planned','blocked')
   and exists(select 1 from public.contentflow_evidence_requirements er where er.evidence_task_key=e.task_key and er.status='obsolete');

 update public.contentflow_retry_state rs
 set circuit_state='closed',attempt_count=0,next_retry_at=null,circuit_open_until=null,updated_at=now()
 from public.contentflow_build_backlog b
 where rs.backlog_task_id=b.id and b.project_key=p_project_key
   and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'')
   and b.workflow_state in ('patch_required','artifact_patch_required')
   and rs.circuit_state='open';

 update public.contentflow_build_backlog b
 set status=case when not exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep)
       where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed')
     ) then 'ready' else 'planned' end,
     blocked_reason=null,next_eligible_at=now(),selected_model=null,updated_at=now()
 where b.project_key=p_project_key
   and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'')
   and b.workflow_state in ('patch_required','artifact_patch_required')
   and b.status in ('blocked','planned')
   and coalesce(b.blocked_reason,'')<>'REVIEW_PENDING';
 get diagnostics reopened=row_count;

 update public.director_repair_incidents i
 set status='resolved',requires_human=false,resolved_at=now(),updated_at=now(),outcome='superseded_by_durable_contract_v3',diagnosis='Legacy escalation contradicted explicit durable workflow contract',validation='contract_driven_reconciliation'
 where i.project_key=p_project_key
   and i.status in ('open','analyzing','repairing','validating','needs_help')
   and (i.error_class in ('progress_stall','durable_wait_unclassified','completion_evidence_unclassified')
        or (i.error_class='owner_required' and exists(
       select 1 from public.contentflow_build_backlog b
       where b.project_key=p_project_key
         and coalesce((b.workflow_contract->>'artifact_completion_independent_of_external_approval')::boolean,false)
   )));
 get diagnostics incidents_resolved=row_count;

 return jsonb_build_object('architecture','DURABLE_TASK_STATE_MACHINE_V3_REQUIRED_EVIDENCE_GUARD','reopened_patch_tasks',reopened,'obsolete_false_evidence',obsolete_evidence,'legacy_evidence_edges_removed',deps_removed,'legacy_incidents_resolved',incidents_resolved);
end $$;


--
-- Name: contentflow_enforce_active_builder_lease(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_active_builder_lease() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
 if new.status in ('claimed','running') and new.finished_at is null then
   new.heartbeat_at:=coalesce(new.heartbeat_at,now());
   new.lease_expires_at:=greatest(coalesce(new.lease_expires_at,now()),coalesce(new.heartbeat_at,now())+interval '15 minutes');
 end if;
 return new;
end $$;


--
-- Name: contentflow_enforce_autonomy_slo(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_autonomy_slo(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare p public.director_control_policy%rowtype; v_running int:=0; v_ready int:=0; v_dispatchable int:=0; v_open int:=0; v_help int:=0; v_last_progress timestamptz; v_no_progress boolean:=false; v_created int:=0; v_x int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  select * into p from public.director_control_policy where project_key=p_project_key and enabled=true;
  if not found then return jsonb_build_object('enabled',false); end if;
  select count(*) into v_running from public.director_worker_queue where status='running';
  select count(*) into v_ready from public.director_worker_queue where status='ready';
  begin v_dispatchable:=public.contentflow_dispatchable_count(p_project_key); exception when others then v_dispatchable:=0; end;
  select count(*) into v_open from public.director_repair_incidents where project_key=p_project_key and status in ('open','analyzing','repairing','validating','needs_help') and error_class not in ('help_slo_breach');
  select count(*) into v_help from public.director_repair_incidents where project_key=p_project_key and status='needs_help' and error_class not in ('help_slo_breach','autonomy_no_progress','progress_stall');
  select max(updated_at) into v_last_progress from public.contentflow_build_backlog where project_key=p_project_key and status='completed' and task_key not like 'gap_gap_%';
  v_no_progress := v_dispatchable>0 and v_ready>0 and v_running<p.desired_running and coalesce(v_last_progress,now()-interval '1 day') < now()-make_interval(mins=>p.no_progress_minutes);
  if v_no_progress then
    insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status)
    select p_project_key,'director_control','autonomy_no_progress','autonomy_no_progress','Dispatchable work and ready workers exist but accepted completion has not progressed inside SLO',jsonb_build_object('running',v_running,'ready',v_ready,'dispatchable',v_dispatchable,'last_progress',v_last_progress,'slo_minutes',p.no_progress_minutes),'low','open'
    where not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='autonomy_no_progress' and i.status in ('open','analyzing','repairing','validating','needs_help'));
    get diagnostics v_x=row_count; v_created:=v_created+v_x;
  end if;
  if v_help>p.max_needs_help then
    insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status)
    select p_project_key,'director_control','help_slo_breach','help_slo_breach','Human-help incidents exceed the autonomous operating target',jsonb_build_object('needs_help',v_help,'target',p.max_needs_help),'medium','open'
    where not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='help_slo_breach' and i.status in ('open','analyzing','repairing','validating','needs_help'));
    get diagnostics v_x=row_count; v_created:=v_created+v_x;
  end if;
  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'autonomy_slo_check','master_director_v3','desired_vs_actual',case when v_no_progress or v_help>p.max_needs_help then 'degraded' else 'healthy' end,false,jsonb_build_object('running',v_running,'desired_running',p.desired_running,'ready',v_ready,'dispatchable',v_dispatchable,'open_incidents',v_open,'needs_help',v_help,'new_incidents',v_created)::text,now());
  return jsonb_build_object('running',v_running,'desired_running',p.desired_running,'ready',v_ready,'dispatchable',v_dispatchable,'open_incidents',v_open,'needs_help',v_help,'no_progress',v_no_progress,'incidents_created',v_created);
end $$;


--
-- Name: contentflow_enforce_backlog_invariants_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_backlog_invariants_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_lane text;
begin
  if coalesce(new.epic,'')='evidence_first' or coalesce(new.task_key,'') like 'evidence_%' then
    v_lane:=public.contentflow_classify_execution_lane_fields(new.task_type,new.description,new.acceptance_criteria);
    if v_lane in ('evidence_producer','tool_executor','llm_artifact') then
      new.execution_lane:=v_lane;
    end if;
  end if;

  if coalesce(new.workflow_state,'')='superseded' or coalesce(new.blocked_reason,'') like 'SUPERSEDED_BY_%' then
    new.status:='deferred';
    new.next_eligible_at:=null;
    new.selected_model:=null;
  end if;
  return new;
end
$$;


--
-- Name: contentflow_enforce_dynamic_running_cap(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_dynamic_running_cap() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_cap int:=1;
  v_prod int:=1;
begin
  if new.project_key='contentflow'
     and new.status='running'
     and old.status is distinct from 'running'
     and coalesce(new.execution_lane,'llm_artifact')='llm_artifact' then
    perform pg_advisory_xact_lock(hashtext('contentflow:master-running-cap'));
    begin
      v_cap:=public.contentflow_recommended_parallelism('contentflow');
    exception when others then
      v_cap:=1;
    end;
    begin
      select greatest(1,coalesce(production_max,1)) into v_prod
      from public.contentflow_nexo_lane_status limit 1;
    exception when others then
      v_prod:=1;
    end;
    v_cap:=greatest(1,least(coalesce(v_cap,1),coalesce(v_prod,1)));
    if (
      select count(*)
      from public.contentflow_build_backlog b
      where b.project_key='contentflow'
        and b.status='running'
        and b.id<>new.id
        and coalesce(b.execution_lane,'llm_artifact')='llm_artifact'
    ) >= v_cap then
      raise exception 'contentflow_dynamic_running_cap_%',v_cap;
    end if;
  end if;
  return new;
end
$$;


--
-- Name: contentflow_enforce_learned_evidence_lane(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_learned_evidence_lane() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.project_key='contentflow'
     and new.epic='evidence_first'
     and new.task_key like 'evidence_%'
     and coalesce(new.description,'') like 'Produce REAL, persisted, correlated evidence%'
     and new.status <> 'completed' then
    new.execution_lane := 'evidence_producer';
  end if;
  return new;
end;
$$;


--
-- Name: contentflow_enforce_learned_preflight(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_learned_preflight(p_run_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare r public.contentflow_builder_runs%rowtype; b public.contentflow_build_backlog%rowtype; chk jsonb; cleaned text; target text;begin
 select * into r from public.contentflow_builder_runs where id=p_run_id for update;
 if not found then return jsonb_build_object('ok',false,'reason','run_missing'); end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update;
 chk:=public.contentflow_learned_identity_preflight(r.result);
 if coalesce((chk->>'ok')::boolean,false) then return jsonb_build_object('ok',true,'action','pass'); end if;
 cleaned:=regexp_replace(coalesce(r.result,''),'(?im)^\s*\|?\s*(Builder\s*Run\s*ID|builder_run_id|source_run_id|correlation\s*id|correlation_id|evidence\s*id|evidence_id)\s*\|?\s*[:=|]\s*[^\n|]+\|?\s*$','','g');
 chk:=public.contentflow_learned_identity_preflight(cleaned);
 if coalesce((chk->>'ok')::boolean,false) then
   update public.contentflow_builder_runs set result=cleaned where id=p_run_id;
   update public.contentflow_build_backlog set result=cleaned,updated_at=now() where id=b.id;
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'learned_preflight_repaired',coalesce(r.idempotency_key,'run:'||r.id)||':learned_preflight_repaired','rara_learning_enforcer',jsonb_build_object('fingerprint','rara_reject_hardcoded_execution_identity_v1','repair','removed_execution_identity_metadata'),r.trace_id) on conflict do nothing;
   return jsonb_build_object('ok',true,'action','repaired','fingerprint','rara_reject_hardcoded_execution_identity_v1');
 end if;
 target:=case when not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(v) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.v and x.status='completed')) then 'ready' else 'planned' end;
 update public.contentflow_builder_runs set status='failed',finished_at=now(),error='LEARNED_PREFLIGHT_BLOCK:rara_reject_hardcoded_execution_identity_v1' where id=r.id;
 update public.contentflow_build_backlog set status=target,selected_model=null,next_eligible_at=now(),updated_at=now() where id=b.id;
 return jsonb_build_object('ok',false,'action','requeue_before_judge','target_status',target,'fingerprint','rara_reject_hardcoded_execution_identity_v1');
end$_$;


--
-- Name: contentflow_enforce_material_claim_truth_preflight(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_material_claim_truth_preflight() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare chk jsonb; begin
  if new.status='review_required' then
    chk:=public.contentflow_material_claim_truth_preflight(new.task_key,new.result);
    if not coalesce((chk->>'ok')::boolean,true) then
      new.status:='failed';
      new.finished_at:=now();
      new.review_approved:=false;
      new.error:='MATERIAL_CLAIM_PREFLIGHT_REJECT:'||chk::text;
      update public.contentflow_build_backlog
         set status='ready',selected_model=null,blocked_reason=null,next_eligible_at=now(),quality_score=0,updated_at=now()
       where id=new.backlog_task_id;
      insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
      select project_key,'material_claim_preflight_rejected','material_claim_truth_guard','deterministic_pre_review','requeued',false,'run='||new.id||' task='||new.task_key||' check='||left(chk::text,1800),now()
      from public.contentflow_build_backlog where id=new.backlog_task_id;
    end if;
  end if;
  return new;
end$$;


--
-- Name: contentflow_enforce_research_deliverable_preflight(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enforce_research_deliverable_preflight() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare chk jsonb;begin
 if new.status='review_required' then
   chk:=public.contentflow_research_deliverable_preflight(new.task_key,new.result);
   if not coalesce((chk->>'ok')::boolean,true) then
     new.status:='failed';
     new.finished_at:=now();
     new.review_approved:=false;
     new.error:='STRUCTURAL_PREFLIGHT_REJECT:'||chk::text;
     update public.contentflow_build_backlog set status='ready',selected_model=null,blocked_reason=null,next_eligible_at=now(),updated_at=now() where id=new.backlog_task_id;
     insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
     select project_key,'research_schema_preflight_rejected','research_deliverable_gate','deterministic_pre_review','requeued',false,'run='||new.id||' task='||new.task_key||' check='||chk::text,now() from public.contentflow_build_backlog where id=new.backlog_task_id;
   end if;
 end if;
 return new;
end$$;


--
-- Name: contentflow_enrich_builder_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enrich_builder_identity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  new.workflow_version:=coalesce(new.workflow_version,public.contentflow_current_workflow_version(new.project_key));
  new.trace_id:=coalesce(new.trace_id,public.contentflow_make_trace_id('run'));
  return new;
end $$;


--
-- Name: contentflow_enrich_cycle_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enrich_cycle_identity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  new.workflow_version:=coalesce(new.workflow_version,public.contentflow_current_workflow_version(new.project_key));
  new.trace_id:=coalesce(new.trace_id,public.contentflow_make_trace_id('cycle'));
  return new;
end $$;


--
-- Name: contentflow_enrich_runtime_event_trace(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_enrich_runtime_event_trace() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; begin
 if new.builder_run_id is not null then
   select * into r from public.contentflow_builder_runs where id=new.builder_run_id;
   if new.trace_id is null then new.trace_id:=r.trace_id; end if;
   if new.span_id is null then new.span_id:=r.span_id; end if;
 end if;
 return new;
end $$;


--
-- Name: contentflow_escalate_unresolved_incidents(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_escalate_unresolved_incidents(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_help int:=0; v_alerts int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 update public.director_repair_incidents set status='needs_help',requires_human=true,updated_at=now(),outcome=coalesce(outcome,'')||case when coalesce(outcome,'')='' then '' else '|' end||'escalated_after_autonomous_repair_exhaustion'
 where project_key=p_project_key and status in ('open','analyzing') and attempts>=max_attempts and error_class not in ('help_slo_breach');
 get diagnostics v_help=row_count;
 insert into public.director_help_alerts(project_key,task_key,component,error_class,error_fingerprint,attempts,summary,last_error,status,created_at,updated_at)
 select i.project_key,i.task_key,i.component,i.error_class,i.error_fingerprint,i.attempts,'AUTONOMY HELP: '||i.error_class||' - '||coalesce(i.symptom,''),coalesce(i.root_cause,i.symptom),'open',now(),now()
 from public.director_repair_incidents i
 where i.project_key=p_project_key and i.status='needs_help' and i.requires_human=true and i.error_class not in ('help_slo_breach','autonomy_no_progress','progress_stall')
   and not exists(select 1 from public.director_help_alerts h where h.project_key=i.project_key and h.error_fingerprint=i.error_fingerprint and h.status='open');
 get diagnostics v_alerts=row_count;
 return jsonb_build_object('escalated_to_help',v_help,'alerts_created',v_alerts);
end $$;


--
-- Name: contentflow_evidence_coverage_plan(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_evidence_coverage_plan(p_project_key text DEFAULT 'contentflow'::text) RETURNS TABLE(requirement_id bigint, requirement_class text, task_key text, evidence_task_key text, prerequisite text, coverage_state text, priority_score integer, provider text, scope text)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select
    er.id as requirement_id,
    er.requirement_class,
    er.task_key,
    er.evidence_task_key,
    coalesce(m.prerequisite, 'other') as prerequisite,
    case
      when coalesce(m.evidence_already_verifiable, false) then 'ready_to_verify'
      when coalesce(m.producer_available, false) and coalesce(m.verifier_available, false) then 'producer_ready'
      when coalesce(m.verifier_available, false) then 'verifier_only'
      else 'missing_capability'
    end as coverage_state,
    (
      case er.requirement_class
        when 'runtime_test' then 60
        when 'persistence_integration' then 55
        when 'runtime_evidence' then 50
        when 'source_contract' then 45
        when 'static_analysis' then 40
        when 'external_approval' then 30
        else 25
      end
      +
      case
        when coalesce(m.evidence_already_verifiable, false) then 40
        when coalesce(m.producer_available, false) and coalesce(m.verifier_available, false) then 30
        when coalesce(m.verifier_available, false) then 20
        else 10
      end
    )::integer as priority_score,
    m.provider,
    m.scope
  from public.contentflow_evidence_requirements er
  left join public.contentflow_evidence_capability_matrix m
    on m.requirement_id = er.id
   and m.project_key = er.project_key
  where er.project_key = p_project_key
    and er.status = 'task_created'
  order by priority_score desc, er.id asc;
$$;


--
-- Name: contentflow_evidence_first_reconcile(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_evidence_first_reconcile(p_project_key text DEFAULT 'contentflow'::text, p_limit integer DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  x record;
  v_fp text;
  v_cls text;
  v_evidence_key text;
  v_existing_evidence_key text;
  v_created int:=0;
  v_held int:=0;
  v_verified int:=0;
  v_reopened int:=0;
  v_reused int:=0;
  v_existing bigint;
  v_existing_status text;
  v_dep jsonb;
  v_new_dep jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then raise exception 'privileged_channel_required'; end if;

  for x in
    select r.id run_id,r.backlog_task_id,r.task_key,r.error,r.created_at,b.title,b.depends_on,b.status,b.completion_phase
    from public.contentflow_builder_runs r
    join public.contentflow_build_backlog b on b.id=r.backlog_task_id
    where r.project_key=p_project_key
      and b.status<>'completed'
      and b.task_key not like 'evidence_%'
      and coalesce(b.epic,'') not in ('evidence_capability','evidence_capability_root','capability_bootstrap')
      and r.status in ('failed','deferred')
      and r.finished_at is not null
      and (
        coalesce(r.error,'') ilike '%RARA_REVIEW_REJECTED%'
        or coalesce(r.error,'') ilike '%NEEDS_EVIDENCE%'
        or coalesce(r.error,'') ilike '%missing evidence%'
        or coalesce(r.error,'') ilike '%no persisted runtime evidence%'
      )
      and r.id=(select max(z.id) from public.contentflow_builder_runs z where z.backlog_task_id=r.backlog_task_id and z.finished_at is not null)
    order by r.id asc
    limit greatest(1,least(coalesce(p_limit,50),200))
  loop
    v_cls:=public.contentflow_evidence_requirement_class(x.error);
    v_fp:=md5(lower(x.task_key)||'|'||v_cls);
    v_evidence_key:='evidence_'||left(regexp_replace(x.task_key,'[^a-zA-Z0-9_]+','','g'),70)||'_'||left(v_fp,10);
    v_existing:=null; v_existing_status:=null; v_existing_evidence_key:=null;

    select er.id,er.status,er.evidence_task_key
      into v_existing,v_existing_status,v_existing_evidence_key
      from public.contentflow_evidence_requirements er
     where er.project_key=p_project_key
       and er.backlog_task_id=x.backlog_task_id
       and er.requirement_class=v_cls
       and er.status<>'obsolete'
     order by case when er.status='verified' then 0 else 1 end,er.id
     limit 1;

    if v_existing is not null and v_existing_status='verified' then
      v_reused:=v_reused+1;
      continue;
    end if;

    if v_existing is not null then
      if coalesce(v_existing_evidence_key,'')<>'' then v_evidence_key:=v_existing_evidence_key; end if;
      update public.contentflow_evidence_requirements
         set requirement_fingerprint=v_fp,requirement_text=left(coalesce(x.error,'NEEDS_EVIDENCE'),6000),
             evidence_task_key=v_evidence_key,updated_at=now()
       where id=v_existing
         and (requirement_fingerprint is distinct from v_fp
              or requirement_text is distinct from left(coalesce(x.error,'NEEDS_EVIDENCE'),6000)
              or evidence_task_key is distinct from v_evidence_key);
    else
      insert into public.contentflow_evidence_requirements(project_key,backlog_task_id,source_run_id,task_key,requirement_class,requirement_fingerprint,requirement_text,evidence_task_key,status,updated_at)
      values(p_project_key,x.backlog_task_id,x.run_id,x.task_key,v_cls,v_fp,left(coalesce(x.error,'NEEDS_EVIDENCE'),6000),v_evidence_key,'task_created',now())
      returning id into v_existing;
    end if;

    if not exists(select 1 from public.contentflow_build_backlog e where e.project_key=p_project_key and e.task_key=v_evidence_key) then
      insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,quality_score,next_eligible_at,completion_phase,execution_lane)
      values(p_project_key,'evidence_first',v_evidence_key,'Evidence harness: '||left(coalesce(x.title,x.task_key),180),
             'Produce REAL, persisted, correlated evidence for source task '||x.task_key||' and source builder_run_id='||x.run_id||'. Requirement class='||v_cls||'. Do not fabricate evidence.',
             'code',1,coalesce(x.depends_on,'[]'::jsonb),'evidence-first','blocked',100,
             'Evidence must be produced by an actual deterministic test, static analysis, integration, persisted runtime record, or externally verifiable artifact; generic prose/placeholders do not satisfy acceptance.',
             0,now(),'evidence_required','tool_executor');
      v_created:=v_created+1;
    end if;

    select coalesce(depends_on,'[]'::jsonb) into v_dep from public.contentflow_build_backlog where id=x.backlog_task_id for update;
    v_new_dep:=v_dep;
    if not (v_new_dep ? v_evidence_key) then v_new_dep:=v_new_dep||to_jsonb(v_evidence_key); end if;

    update public.contentflow_build_backlog
       set depends_on=v_new_dep,status='blocked',selected_model=null,next_eligible_at=null,
           completion_phase='waiting_for_evidence',updated_at=now()
     where id=x.backlog_task_id and status<>'completed'
       and (depends_on is distinct from v_new_dep or status<>'blocked' or completion_phase<>'waiting_for_evidence');
    if found then v_held:=v_held+1; end if;

    delete from public.contentflow_retry_state where backlog_task_id=x.backlog_task_id;
  end loop;

  update public.contentflow_evidence_requirements er
     set status='verified',verified_at=now(),updated_at=now(),
         evidence_ref=jsonb_build_object('evidence_task_key',er.evidence_task_key,'evidence_task_id',e.id,'source_run_id',er.source_run_id,'runtime_evidence',coalesce(e.runtime_evidence,'{}'::jsonb))
    from public.contentflow_build_backlog e
   where er.project_key=p_project_key and er.status='task_created'
     and e.project_key=er.project_key and e.task_key=er.evidence_task_key
     and e.status='completed' and coalesce(e.runtime_verified,false)=true
     and coalesce(e.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb;
  get diagnostics v_verified=row_count;

  perform public.contentflow_gc_evidence_dependencies(p_project_key);
  select (public.contentflow_reconcile_ready_after_evidence(p_project_key)->>'reopened')::int into v_reopened;

  return jsonb_build_object('architecture','EVIDENCE_FIRST_EXECUTION_V2_3_BOOTSTRAP_FAMILY_SAFE','requirements_created',v_created,'verified_requirements_reused',v_reused,'originals_held',v_held,'requirements_verified',v_verified,'originals_reopened',coalesce(v_reopened,0));
end
$$;


--
-- Name: FUNCTION contentflow_evidence_first_reconcile(p_project_key text, p_limit integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.contentflow_evidence_first_reconcile(p_project_key text, p_limit integer) IS 'EVIDENCE_FIRST_EXECUTION_V1 with recursive evidence-of-evidence prevention: evidence_* tasks are terminal evidence producers and never generate child evidence requirements.';


--
-- Name: contentflow_evidence_prerequisite_class(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_evidence_prerequisite_class(p_requirement_class text, p_requirement_text text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
 select case
   when coalesce(p_requirement_class,'')='media_capture'
     or lower(coalesce(p_requirement_text,'')) ~ '(video|subtitle|keyframe|sha-256|sha256|screen recording|audiovisual|master premium|short variant|real screen|pantalla real)'
     then 'media_capture'
   when coalesce(p_requirement_class,'')='external_approval'
     or lower(coalesce(p_requirement_text,'')) ~ '(requires? (manual|human) approval|pending owner decision|(human|owner|security team|architecture team)[ -]?(approval|sign.?off|authorization))'
     then 'external_approval'
   when (lower(coalesce(p_requirement_text,'')) ~ '(commit hash|commit sha|repository|repo link|file path|merged into|published|version-controlled|version control)'
     and lower(coalesce(p_requirement_text,'')) ~ '(unit test|integration test|test suite|test corpus|test execution|coverage|executed|execution on|runtime report|runtime evidence|30 positive test|test cases|machine-readable report)') then 'repo_and_runtime_test'
   when coalesce(p_requirement_class,'')='static_analysis' then 'static_analysis'
   when coalesce(p_requirement_class,'')='runtime_test' then 'runtime_test'
   when coalesce(p_requirement_class,'')='source_contract' then 'source_contract'
   when coalesce(p_requirement_class,'') in ('runtime_evidence','persistence_integration') then 'runtime_persistence'
   when lower(coalesce(p_requirement_text,'')) ~ '(commit hash|commit sha|repository|repo link|file path|merged into|published|version-controlled|version control)' then 'repo_commit_or_file'
   when lower(coalesce(p_requirement_text,'')) ~ '(static analysis|lint|mypy|scanner|scan)' then 'static_analysis'
   when lower(coalesce(p_requirement_text,'')) ~ '(platformstore|record_evidence|evidence store|durable storage|database record|database query|persisted runtime|runtime evidence|runtime log|runtime trace)' then 'runtime_persistence'
   when lower(coalesce(p_requirement_text,'')) ~ '(unit test|integration test|test suite|test corpus|test execution|coverage|benchmark|http 400|http 200)' then 'runtime_test'
   when lower(coalesce(p_requirement_text,'')) ~ '(interface|contract|schema|missing method|field)' then 'source_contract'
   when lower(coalesce(p_requirement_text,'')) ~ '(deploy|deployment|staging|production)' then 'deployment_trace'
   else 'other'
 end;
$$;


--
-- Name: contentflow_evidence_requirement_class(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_evidence_requirement_class(p_error text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select case
    when coalesce(p_error,'') ~* 'static analysis|mypy|lint|scanner|entropy scanner' then 'static_analysis'
    when coalesce(p_error,'') ~* 'test corpus|test suite|integration test|unit test|test execution|false negative|end-to-end test|e2e test' then 'runtime_test'
    when coalesce(p_error,'') ~* 'PlatformStore|persisted evidence|record_evidence|evidence store|database record|durable storage|runtime log|persisted runtime' then 'persistence_integration'
    when coalesce(p_error,'') ~* 'missing method|interface|contract|schema|field|signature not verified|method signature' then 'source_contract'
    when coalesce(p_error,'') ~* '(human|owner|security team|architecture team|external)[ -]?(approval|sign.?off|authorization)|requires? (manual|human) approval|pending owner decision' then 'external_approval'
    when coalesce(p_error,'') ~* 'NEEDS_EVIDENCE|missing evidence|no persisted runtime evidence|RARA_REVIEW_REJECTED' then 'runtime_evidence'
    else 'unknown'
  end
$$;


--
-- Name: contentflow_evidence_verifier_preflight(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_evidence_verifier_preflight(p_project_key text, p_evidence_task_key text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare er record; st record; ev jsonb:='[]'::jsonb; rt text:=''; evt text:=''; non_generic int:=0; cls text; begin select * into er from public.contentflow_evidence_requirements where project_key=p_project_key and evidence_task_key=p_evidence_task_key order by id desc limit 1; if er.id is null then return false; end if; select runtime_verified,coalesce(runtime_evidence,'{}'::jsonb) runtime_evidence into st from public.contentflow_build_backlog where id=er.backlog_task_id; select coalesce(jsonb_agg(jsonb_build_object('event_type',l.event_type,'payload',l.payload)),'[]'::jsonb),count(*) filter(where l.event_type not in ('claimed','runner_started','runner_v2_started','runner_v4_started','runner_v5_started','artifact_generated','judge_completed','runner_completed','owner_finalized')) into ev,non_generic from public.contentflow_runtime_event_ledger l where l.builder_run_id=er.source_run_id; rt:=lower(coalesce(st.runtime_evidence,'{}'::jsonb)::text); evt:=lower(ev::text); cls:=coalesce(er.requirement_class,'unknown'); if cls in ('runtime_evidence','persistence_integration') then return coalesce(st.runtime_verified,false) and (coalesce(st.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb or non_generic>0); end if; if cls='runtime_test' then return (rt||evt) ~ '(test|assert|integration|ci_)'; end if; if cls='static_analysis' then return (rt||evt) ~ '(static|lint|mypy|scan)'; end if; if cls='external_approval' then return (rt||evt) ~ '(approval|approved_by)'; end if; if cls='source_contract' then return coalesce(st.runtime_verified,false) and (rt||evt) ~ 'source' and coalesce(st.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb; end if; return false; end; $$;


--
-- Name: contentflow_executable_tool_pending_count(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_executable_tool_pending_count(p_project_key text DEFAULT 'contentflow'::text) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
 select count(*)::int
 from public.contentflow_tool_execution_queue q join public.contentflow_build_backlog b on b.id=q.backlog_task_id
 where q.project_key=p_project_key and q.state='pending' and b.status in ('blocked','ready')
   and b.execution_lane in ('tool_executor','evidence_producer')
   and public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key)
   and (b.next_eligible_at is null or b.next_eligible_at<=now())
   and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required','verification_required') and r.finished_at is null)
   and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'));
$$;


--
-- Name: contentflow_external_executor_autorelease_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_external_executor_autorelease_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.status in ('configured','healthy') and nullif(new.endpoint,'') is not null then
    update public.contentflow_build_backlog b
       set status='ready',blocked_reason=null,next_eligible_at=now(),updated_at=now()
     where b.project_key=new.project_key
       and b.execution_lane='tool_executor'
       and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')=new.executor_key
       and b.status='blocked'
       and coalesce(b.blocked_reason,'')='EXECUTOR_ENDPOINT_REQUIRED';

    update public.contentflow_tool_execution_queue q
       set state='pending',last_error=null,claim_token=null,claimed_at=null,updated_at=now()
     where q.project_key=new.project_key
       and q.state in ('failed','blocked')
       and exists(
         select 1 from public.contentflow_build_backlog b
         where b.id=q.backlog_task_id
           and b.execution_lane='tool_executor'
           and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')=new.executor_key
       );
  end if;
  return new;
end;
$$;


--
-- Name: contentflow_external_executor_ready(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_external_executor_ready(p_project_key text, p_executor_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
select exists(
  select 1 from public.contentflow_external_executor_registry
  where project_key=p_project_key and executor_key=p_executor_key
    and status in ('configured','healthy')
    and nullif(endpoint,'') is not null
);
$$;


--
-- Name: contentflow_external_media_lane_guard_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_external_media_lane_guard_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.epic='external_handoff'
     and (coalesce(new.title,'')||' '||coalesce(new.description,'')||' '||coalesce(new.acceptance_criteria,'')) ~* '(video|render|master|pieza profesional)'
     and (coalesce(new.title,'')||' '||coalesce(new.description,'')||' '||coalesce(new.acceptance_criteria,'')) ~* '(sha-?256|keyframe|subt[ií]tul|evidencia aut[eé]ntica|evidencia real|artefact)' then
    new.execution_lane := 'evidence_producer';
  end if;
  return new;
end
$$;


--
-- Name: contentflow_finalize_run_v2(bigint, text, integer, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_finalize_run_v2(p_run_id bigint, p_lease_token text, p_http_status integer, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; b public.contentflow_build_backlog%rowtype; v_ok boolean; v_quality numeric; v_cost numeric; v_model text; v_result text; v_failure text; v_run_final text; v_backlog_final text; v_reason text; v_dep_incomplete int:=0; v_contract boolean:=false; v_retryable boolean:=false; v_patchable boolean:=false;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 select * into r from public.contentflow_builder_runs where id=p_run_id for update; if not found then return jsonb_build_object('ok',false,'reason','run_not_found'); end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update; if not found then return jsonb_build_object('ok',false,'reason','backlog_not_found'); end if;
 if r.lease_token is distinct from p_lease_token or r.lease_revoked_at is not null or r.status not in ('claimed','running') or b.status<>'running' or exists(select 1 from public.contentflow_builder_runs n where n.backlog_task_id=r.backlog_task_id and n.id>r.id) then update public.contentflow_builder_dispatches set status='superseded',collected_at=now(),http_status=p_http_status,error='fenced_out_or_commit_state_invalid' where builder_run_id=r.id and status='pending'; return jsonb_build_object('ok',false,'reason','commit_fenced','run_id',r.id); end if;
 if b.depends_on is not null then select count(*) into v_dep_incomplete from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed'); end if;
 v_ok:=coalesce((p_payload->>'ok')::boolean,false); v_quality:=coalesce((p_payload->>'quality_score')::numeric,0); v_cost:=coalesce((p_payload->>'cost_usd')::numeric,0); v_model:=nullif(p_payload->>'selected_model',''); v_result:=nullif(p_payload->>'result',''); v_failure:=upper(coalesce(p_payload->>'failure_class','')); v_reason:=coalesce(p_payload->>'quality_reason',p_payload->>'error','execution_failed'); v_contract:=coalesce(b.workflow_contract->>'contract_version','')<>'';
 -- Retry classification is only meaningful for unsuccessful executions. A successful
 -- judge reason may legitimately contain words such as "timeout", "rate limit", etc.
 -- and must never be reclassified as transport failure.
 v_retryable:=(not v_ok) and (v_failure='INFRA_FAIL' or p_http_status in (408,425,429,500,502,503,504) or lower(v_reason) ~ '(transport|timeout|capacity|rate.limit|upstream|network|fenced)');
 v_patchable:=v_contract and coalesce(b.workflow_contract->>'failure_policy','')='patch_stage_only';
 if v_cost<0 or v_cost>0.05 then v_ok:=false; v_reason:='cost_gate_failed'; v_retryable:=false; end if;
 if v_dep_incomplete>0 then v_ok:=false; v_reason:='dependency_commit_gate_failed'; v_retryable:=false; end if;
 if v_retryable then v_run_final:='deferred'; v_backlog_final:='ready';
 elsif v_failure='JUDGE_FAIL' and v_result is not null then v_run_final:='review_required'; v_backlog_final:='blocked';
 elsif v_ok and v_quality>=85 then v_run_final:='review_required'; v_backlog_final:='blocked';
 elsif v_patchable then v_run_final:='failed'; v_backlog_final:='ready';
 else v_run_final:='failed'; v_backlog_final:='failed'; end if;
 update public.contentflow_builder_runs set status=v_run_final,selected_model=coalesce(v_model,r.selected_model),quality_score=v_quality,cost_usd=least(greatest(v_cost,0),0.05),result=coalesce(v_result,r.result),error=case when v_run_final in ('failed','deferred') or (v_run_final='review_required' and v_failure='JUDGE_FAIL') then v_reason else null end,review_approved=false,finished_at=case when v_run_final in ('failed','deferred') then now() else null end,lease_revoked_at=now(),activity_phase=null,activity_deadline_at=null,heartbeat_deadline_at=null where id=r.id;
 update public.contentflow_build_backlog set status=v_backlog_final,blocked_reason=case when v_run_final='review_required' then 'REVIEW_PENDING' else null end,selected_model=case when v_backlog_final='ready' then null else coalesce(v_model,r.selected_model) end,quality_score=case when v_run_final='review_required' then v_quality else quality_score end,cost_usd=least(greatest(v_cost,0),0.05),result=coalesce(v_result,result),next_eligible_at=case when v_retryable then now()+interval '15 seconds' when v_patchable and v_run_final='failed' then now()+interval '10 seconds' else next_eligible_at end,workflow_state=case when v_patchable and v_run_final='failed' then 'patch_required' else workflow_state end,patch_feedback=case when v_patchable and v_run_final='failed' then left(v_reason,5000) else patch_feedback end,updated_at=now() where id=r.backlog_task_id and status='running';
 update public.director_worker_queue set status='ready',current_task_key=null,last_task_key=r.task_key,last_outcome=v_run_final,last_quality_score=v_quality,last_finished_at=now(),total_completions=total_completions+case when v_run_final='review_required' then 1 else 0 end,total_failures=total_failures+case when v_run_final='failed' and not v_patchable then 1 else 0 end,updated_at=now() where model_id=r.selected_model and current_task_key is not distinct from r.task_key;
 update public.contentflow_builder_dispatches set status='collected',collected_at=now(),http_status=p_http_status,error=case when v_run_final in ('failed','deferred') then v_reason else null end where builder_run_id=r.id and status='pending';
 perform public.contentflow_checkpoint_stage(b.id,case when v_run_final='review_required' then 'review' else 'artifact' end,case when v_run_final='review_required' then 'pending' when v_retryable then 'retry_wait' when v_patchable then 'patch_required' else 'failed' end,case when v_retryable then 'transient_infra' when v_patchable then 'artifact_defect' else 'fatal' end,v_reason,jsonb_build_object('run_id',r.id,'http_status',p_http_status,'failure_class',v_failure,'typed_retry',v_retryable));
 insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload) values(r.id,r.task_key,'owner_finalized',r.idempotency_key,'dispatch_executor_v2',jsonb_build_object('final_status',v_run_final,'backlog_status',v_backlog_final,'http_status',p_http_status,'quality_score',v_quality,'typed_retry',v_retryable,'dependency_commit_gate',v_dep_incomplete=0)) on conflict do nothing;
 return jsonb_build_object('ok',true,'run_id',r.id,'final_status',v_run_final,'backlog_status',v_backlog_final,'quality_score',v_quality,'typed_retry',v_retryable,'dependency_commit_gate',v_dep_incomplete=0);
end
$$;


--
-- Name: contentflow_finalize_runtime_verified_tool_tasks_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_finalize_runtime_verified_tool_tasks_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int:=0;
begin
 update public.contentflow_build_backlog b
    set status='completed', completion_phase='runtime_proven', workflow_state='completed', quality_score=100, blocked_reason=null, next_eligible_at=null, updated_at=now()
  where b.project_key=p_project_key and b.execution_lane='tool_executor' and b.runtime_verified=true and coalesce(b.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb and b.status in ('ready','blocked','verification_required')
    and exists(select 1 from public.contentflow_tool_execution_queue q where q.project_key=b.project_key and q.backlog_task_id=b.id and q.state='completed' and coalesce(q.evidence,'{}'::jsonb)<>'{}'::jsonb);
 get diagnostics n=row_count;
 return jsonb_build_object('architecture','DIRECT_TOOL_RUNTIME_FINALIZATION_V1','finalized',n);
end $$;


--
-- Name: contentflow_finish_tool_execution_task(bigint, uuid, boolean, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_finish_tool_execution_task(p_queue_id bigint, p_claim_token uuid, p_success boolean, p_evidence jsonb DEFAULT '{}'::jsonb, p_error text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare bid bigint; tkey text; pkey text; is_evidence boolean:=false;
begin
 select backlog_task_id,task_key,project_key into bid,tkey,pkey from public.contentflow_tool_execution_queue where id=p_queue_id and state='claimed' and claim_token=p_claim_token for update;
 if bid is null then return jsonb_build_object('ok',false,'reason','fenced_out'); end if;
 select (epic='evidence_first' or completion_phase='evidence_required' or execution_lane='evidence_producer') into is_evidence from public.contentflow_build_backlog where id=bid for update;
 update public.contentflow_tool_execution_queue set state=case when p_success then 'completed' else 'failed' end,completed_at=case when p_success then now() else null end,last_error=p_error,evidence=coalesce(p_evidence,'{}'::jsonb),updated_at=now() where id=p_queue_id and state='claimed' and claim_token=p_claim_token;
 if not found then return jsonb_build_object('ok',false,'reason','fenced_out'); end if;
 if p_success then
   perform public.contentflow_clear_retry_after_repair(tkey,pkey);
   update public.contentflow_build_backlog set runtime_verified=true,runtime_verified_at=now(),runtime_evidence=coalesce(runtime_evidence,'{}'::jsonb)||coalesce(p_evidence,'{}'::jsonb),status='completed',blocked_reason=null,quality_score=100,completion_phase=case when is_evidence then 'evidence_verified' else 'runtime_proven' end,workflow_state='completed',next_eligible_at=null,updated_at=now() where id=bid and status='running' and execution_lane in ('tool_executor','evidence_producer');
 else
   update public.contentflow_build_backlog set status='blocked',blocked_reason='EXECUTION_FAILED:'||coalesce(p_error,'UNSPECIFIED'),updated_at=now() where id=bid and status='running' and execution_lane in ('tool_executor','evidence_producer');
 end if;
 return jsonb_build_object('ok',true,'task_key',tkey,'success',p_success,'evidence_task',is_evidence,'project_key',pkey);
end $$;


--
-- Name: contentflow_gc_evidence_dependencies(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_gc_evidence_dependencies(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_removed int:=0;
  v_retired int:=0;
  v_reopened int:=0;
  v_false_tombstones_recovered int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;

  -- A dependency is removable only when it is genuine evidence, incomplete,
  -- has no active evidence requirement, AND is not referenced by any active consumer.
  with cleaned as (
    select b.id,
           coalesce((select jsonb_agg(d.value order by d.ord)
                     from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) with ordinality d(value,ord)
                     left join public.contentflow_build_backlog e
                       on e.project_key=b.project_key and e.task_key=d.value
                     where not (
                       e.id is not null
                       and (
                         coalesce(e.epic,'')='evidence_first'
                         or coalesce(e.execution_lane,'')='evidence_producer'
                         or exists(
                           select 1 from public.contentflow_evidence_requirements er0
                           where er0.project_key=e.project_key and er0.evidence_task_key=e.task_key
                         )
                       )
                       and coalesce(e.status,'missing')<>'completed'
                       and not exists (
                         select 1 from public.contentflow_evidence_requirements er
                         where er.project_key=b.project_key and er.evidence_task_key=d.value
                           and er.status in ('task_created','open','blocked')
                       )
                       and not exists (
                         select 1
                         from public.contentflow_build_backlog consumer
                         cross join lateral jsonb_array_elements_text(coalesce(consumer.depends_on,'[]'::jsonb)) dep(value)
                         where consumer.project_key=b.project_key
                           and consumer.status not in ('completed','deferred')
                           and dep.value=d.value
                       )
                     )),'[]'::jsonb) new_depends
    from public.contentflow_build_backlog b
    where b.project_key=p_project_key
  )
  update public.contentflow_build_backlog b
     set depends_on=c.new_depends,updated_at=now()
    from cleaned c
   where b.id=c.id and b.depends_on is distinct from c.new_depends;
  get diagnostics v_removed=row_count;

  -- Retire genuine evidence only when nothing active still consumes it.
  update public.contentflow_build_backlog e
     set status='deferred',completion_phase='orphan_evidence_retired',next_eligible_at=null,updated_at=now()
   where e.project_key=p_project_key
     and e.status<>'completed'
     and (
       coalesce(e.epic,'')='evidence_first'
       or coalesce(e.execution_lane,'')='evidence_producer'
       or exists(
         select 1 from public.contentflow_evidence_requirements er0
         where er0.project_key=e.project_key and er0.evidence_task_key=e.task_key
       )
     )
     and not exists(
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=e.project_key and er.evidence_task_key=e.task_key
         and er.status in ('task_created','open','blocked')
     )
     and not exists(
       select 1
       from public.contentflow_build_backlog consumer
       cross join lateral jsonb_array_elements_text(coalesce(consumer.depends_on,'[]'::jsonb)) dep(value)
       where consumer.project_key=e.project_key
         and consumer.task_key<>e.task_key
         and consumer.status not in ('completed','deferred')
         and dep.value=e.task_key
     );
  get diagnostics v_retired=row_count;

  update public.contentflow_build_backlog b
     set status='ready',completion_phase='artifact_pending',blocked_reason=null,next_eligible_at=now(),selected_model=null,updated_at=now()
   where b.project_key=p_project_key
     and b.status='deferred'
     and b.completion_phase='orphan_evidence_retired'
     and coalesce(b.execution_lane,'llm_artifact')='llm_artifact'
     and coalesce(b.epic,'')<>'evidence_first'
     and not exists(
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=b.project_key and er.evidence_task_key=b.task_key
     )
     and not exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
       where not exists(
         select 1 from public.contentflow_build_backlog dep
         where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'
       )
     );
  get diagnostics v_false_tombstones_recovered=row_count;

  update public.contentflow_build_backlog b
     set status='ready',next_eligible_at=now(),completion_phase='evidence_verified',updated_at=now()
   where b.project_key=p_project_key and b.status='blocked' and b.completion_phase='waiting_for_evidence'
     and not exists(select 1 from public.contentflow_evidence_requirements er where er.backlog_task_id=b.id and er.status not in ('verified','obsolete'))
     and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
                    where not exists(select 1 from public.contentflow_build_backlog dep where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'))
     and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required','verification_required') and r.finished_at is null);
  get diagnostics v_reopened=row_count;

  return jsonb_build_object(
    'architecture','EVIDENCE_DEPENDENCY_GC_V3_PRESERVE_ACTIVE_CONSUMERS',
    'tasks_dependencies_rewritten',v_removed,
    'orphan_evidence_tasks_retired',v_retired,
    'false_prefix_tombstones_recovered',v_false_tombstones_recovered,
    'originals_reopened',v_reopened
  );
end
$$;


--
-- Name: contentflow_guard_active_run_protocol(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_guard_active_run_protocol() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
 if new.project_key='contentflow' and new.status in ('claimed','running') and new.finished_at is null then
   if tg_op='INSERT' or (tg_op='UPDATE' and old.status not in ('claimed','running')) then
     if coalesce(new.control_protocol,'')<>'fenced-v2' or coalesce(new.lease_token,'')='' then
       raise exception 'single_writer_fenced_protocol_required';
     end if;
   end if;
 end if;
 return new;
end $$;


--
-- Name: contentflow_guard_backlog_completion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_guard_backlog_completion() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare need_runtime boolean;
begin
 need_runtime:=public.contentflow_contract_runtime_required(new.workflow_contract,new.task_type,new.title,new.description,new.acceptance_criteria);
 if new.status='completed' and need_runtime and not coalesce(new.runtime_verified,false) then
   new.status:='verification_required';
   new.workflow_state:='runtime_verification_wait';
   new.completion_phase:='verification_required';
   new.blocked_reason:=null;
   new.updated_at:=now();
 elsif new.status='completed' then
   new.workflow_state:='completed';
   new.completion_phase:=case when coalesce(new.runtime_verified,false) then 'runtime_proven' else 'artifact_approved' end;
   new.patch_feedback:=null;
   new.blocked_reason:=null;
   new.next_eligible_at:=null;
   new.updated_at:=now();
 end if;
 return new;
end
$$;


--
-- Name: contentflow_guard_builder_completion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_guard_builder_completion() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare b public.contentflow_build_backlog%rowtype; need_runtime boolean;
begin
 if new.status='completed' then
  select * into b from public.contentflow_build_backlog where id=new.backlog_task_id;
  if found then
   need_runtime:=public.contentflow_contract_runtime_required(b.workflow_contract,b.task_type,b.title,b.description,b.acceptance_criteria);
   if need_runtime and not coalesce(b.runtime_verified,false) then
    new.status:='verification_required'; new.finished_at:=null; new.error:='RUNTIME_VERIFICATION_REQUIRED';
   else
    new.error:=null; new.finished_at:=coalesce(new.finished_at,now());
   end if;
  end if;
 end if;
 return new;
end $$;


--
-- Name: contentflow_guard_dependency_graph(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_guard_dependency_graph() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare n int; d int;
begin
 if new.project_key='contentflow' then
   if exists(select 1 from jsonb_array_elements_text(coalesce(new.depends_on,'[]'::jsonb)) x(v) where x.v=new.task_key) then raise exception 'dependency_self_reference_forbidden'; end if;
   select count(*),count(distinct v) into n,d from jsonb_array_elements_text(coalesce(new.depends_on,'[]'::jsonb)) x(v);
   if n<>d then raise exception 'duplicate_dependencies_forbidden'; end if;
 end if;
 return new;
end $$;


--
-- Name: contentflow_guard_false_rara_evidence_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_guard_false_rara_evidence_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if coalesce(new.requirement_text,'') ilike '%RARA_ARTIFACT_REVIEW_REJECTED%'
     and coalesce(new.requirement_text,'') ilike '%class=NONE%'
     and coalesce(new.requirement_text,'') ilike '%action=COMPLETE%'
     and coalesce(new.requirement_text,'') ilike '%missing=[]%'
  then
    new.status:='obsolete';
  end if;
  return new;
end
$$;


--
-- Name: contentflow_guard_runtime_evidence_ledger_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_guard_runtime_evidence_ledger_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  raise exception 'runtime_evidence_ledger_is_append_only';
end $$;


--
-- Name: contentflow_incident_learning_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_incident_learning_trigger() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if current_setting('contentflow.learning_internal',true)='1' then return new; end if;
  perform public.contentflow_learn_incident(new.id);
  if new.status in ('resolved','resolved_repeat','resolved_transient') then
    perform public.contentflow_promote_safe_learnings(new.project_key);
  end if;
  return new;
end $$;


--
-- Name: contentflow_ingest_handoff_v1(text, text, text, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_ingest_handoff_v1(p_project_key text, p_handoff_id text, p_source text, p_actions jsonb, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_signal jsonb; v_action text; v_idx int:=0; v_created int:=0; v_stage int:=1; v_task_key text;
  v_source text:=coalesce(nullif(trim(p_source),''),'external_handoff');
  v_context text:=left(coalesce(p_metadata->>'handoff_context',''),24000);
  v_files text:=coalesce((p_metadata->'files')::text,'[]');
  v_lane text; v_workflow_state text; v_blocked_reason text;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
  if coalesce(trim(p_project_key),'')='' or coalesce(trim(p_handoff_id),'')='' then raise exception 'handoff_identity_required'; end if;
  if jsonb_typeof(coalesce(p_actions,'[]'::jsonb))<>'array' then raise exception 'handoff_actions_must_be_array'; end if;
  if jsonb_array_length(coalesce(p_actions,'[]'::jsonb))>20 then raise exception 'handoff_actions_limit_exceeded'; end if;
  v_signal:=public.contentflow_record_durable_signal_v1(p_project_key,'handoff:'||left(p_handoff_id,120),'worker_handoff',left(p_handoff_id,200),jsonb_build_object('actions',coalesce(p_actions,'[]'::jsonb),'metadata',coalesce(p_metadata,'{}'::jsonb)),v_source);
  if coalesce((v_signal->>'inserted')::boolean,false)=false then return jsonb_build_object('ok',true,'deduplicated',true,'created',0,'signal',v_signal); end if;
  select coalesce(max(stage),0)+1 into v_stage from public.contentflow_build_backlog where project_key=p_project_key;
  for v_action in select trim(value) from jsonb_array_elements_text(coalesce(p_actions,'[]'::jsonb)) loop
    v_idx:=v_idx+1; if v_action='' then continue; end if;
    v_task_key:='handoff_'||substr(md5(p_handoff_id),1,12)||'_'||lpad(v_idx::text,2,'0');
    if public.contentflow_evidence_prerequisite_class('other',v_action)='media_capture'
       or lower(v_action) ~ '(capture|render|mp4|keyframe|subtitle|sha-256|sha256|screen recording|qa receipt|lipsync|audiovisual|short variant|master premium|real screen)' then
      v_lane:='evidence_producer'; v_workflow_state:='evidence_pending'; v_blocked_reason:='MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE';
    else
      v_lane:='llm_artifact'; v_workflow_state:='artifact_pending'; v_blocked_reason:=null;
    end if;
    insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,execution_lane,workflow_state,blocked_reason)
    values(p_project_key,'external_handoff',v_task_key,left(v_action,180),
      v_action||E'\n\nSOURCE HANDOFF CONTEXT (authoritative):\n'||case when v_context<>'' then v_context else '[context_not_embedded]' end||E'\n\nSource files: '||v_files||E'\nHandoff: '||p_handoff_id||E'\nSource: '||v_source||E'\nMetadata: '||coalesce(p_metadata,'{}'::jsonb)::text,
      'general',v_stage,'[]'::jsonb,'social-ops:'||v_source,case when v_lane='evidence_producer' then 'blocked' else 'ready' end,least(30,10+v_idx),
      'Use the embedded handoff context as authoritative source. Return evidence-backed DONE/BLOCKED/PARTIAL, cite exact repo paths/IDs present in context, identify any human gate, and never invent external authorization or write evidence.',
      v_lane,v_workflow_state,v_blocked_reason) on conflict(project_key,task_key) do nothing;
    if found then v_created:=v_created+1; insert into public.director_project_task_scope(project_key,task_key,scope_class,counts_toward_progress,reason) values(p_project_key,v_task_key,'product',true,'durable Social Ops handoff continuation with embedded context') on conflict(project_key,task_key) do update set counts_toward_progress=true,reason=excluded.reason,updated_at=now(); end if;
  end loop;
  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at) values(p_project_key,'handoff_ingested',v_source,'durable_handoff_bridge_v3_media_lane',case when v_created>0 then 'work_released' else 'no_actions' end,false,jsonb_build_object('handoff_id',p_handoff_id,'created',v_created,'action_count',jsonb_array_length(coalesce(p_actions,'[]'::jsonb)),'context_bytes',length(v_context),'metadata',coalesce(p_metadata,'{}'::jsonb))::text,now());
  return jsonb_build_object('ok',true,'deduplicated',false,'created',v_created,'signal',v_signal,'context_bytes',length(v_context));
end$$;


--
-- Name: contentflow_learn_incident(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_learn_incident(p_incident_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare i public.director_repair_incidents%rowtype; v_class text; v_fp text; v_root text; v_correction text; v_prevention text; v_success int:=0; v_failure int:=0; begin select * into i from public.director_repair_incidents where id=p_incident_id; if not found then return jsonb_build_object('learned',false,'reason','incident_not_found'); end if; v_class:=case when i.error_class='zero_throughput_semantic_deadlock' then i.error_class else public.contentflow_canonical_error_class(i.project_key,i.task_key,i.error_class,i.symptom,i.evidence) end; v_fp:=coalesce(nullif(i.error_fingerprint,''),v_class||':'||coalesce(i.task_key,'project')); if v_class='zero_throughput_semantic_deadlock' then v_root:='Ready work and workers can coexist with zero throughput when producer and verifier responsibilities or execution lanes are semantically misrouted.'; v_prevention:='Detect ready+workers with zero dispatch/runs; inspect execution lanes and dependency contracts, separate evidence producers from deterministic verifiers, then run a bounded canary before scaling.'; elsif v_class='acceptance_evidence' then v_root:='Task requires verifiable persisted runtime/external evidence; artifact-only execution cannot satisfy the acceptance contract.'; v_prevention:='Route evidence-producing work to evidence_producer, deterministic verification to tool_executor, and require persisted verification before completion.'; elsif v_class='builder_timeout' then v_root:='Builder execution exceeded its allowed execution window or lease.'; v_prevention:='Use bounded retries/backoff, preserve lease fencing, and classify timeout separately from generic builder failure.'; elsif v_class='progress_stall' then v_root:='Eligible work existed while active throughput was below configured capacity.'; v_prevention:='Run deadlock detector, reconciler and adaptive dispatcher before escalating; persist outcome for recurrence detection.'; else v_root:=coalesce(nullif(i.root_cause,''),'Unclassified failure; retain evidence and do not auto-repair until a deterministic class is learned.'); v_prevention:='Preserve evidence and fingerprint; require deterministic classification before creating an automatic repair recipe.'; end if; v_correction:=coalesce(nullif(i.executed_action,''),nullif(i.proposed_action,''),'none_observed'); if i.status in ('resolved','resolved_repeat','resolved_transient') then v_success:=1; end if; if i.status='needs_help' then v_failure:=1; end if; perform set_config('contentflow.learning_internal','1',true); update public.director_repair_incidents set error_class=v_class,error_fingerprint=v_fp,root_cause=coalesce(root_cause,v_root),updated_at=now() where id=i.id; perform set_config('contentflow.learning_internal','0',true); insert into public.director_error_memory(project_key,error_class,error_fingerprint,component,symptom,root_cause,correction,prevention_rule,evidence,occurrences,correction_successes,correction_failures,confidence,status,last_seen_at,updated_at) values(i.project_key,v_class,v_fp,i.component,coalesce(i.symptom,'unknown symptom'),v_root,v_correction,v_prevention,left(coalesce(i.evidence::text,'{}'),8000),1,v_success,v_failure,case when v_success=1 then .70 when v_failure=1 then .35 else .50 end,'active',now(),now()) on conflict(project_key,error_fingerprint) do update set error_class=excluded.error_class,root_cause=excluded.root_cause,correction=case when excluded.correction<>'none_observed' then excluded.correction else director_error_memory.correction end,prevention_rule=excluded.prevention_rule,evidence=excluded.evidence,occurrences=director_error_memory.occurrences+1,correction_successes=director_error_memory.correction_successes+v_success,correction_failures=director_error_memory.correction_failures+v_failure,confidence=least(.99,greatest(.20,(director_error_memory.correction_successes+v_success+1.0)/(director_error_memory.correction_successes+v_success+director_error_memory.correction_failures+v_failure+2.0))),status='active',last_seen_at=now(),updated_at=now(); return jsonb_build_object('learned',true,'incident_id',i.id,'error_class',v_class,'fingerprint',v_fp,'success',v_success,'failure',v_failure); end $$;


--
-- Name: contentflow_learn_qa_health_degradation(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_learn_qa_health_degradation(p_project_key text, p_task_key text, p_evidence text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
 insert into public.director_error_memory(project_key,error_class,error_fingerprint,component,symptom,root_cause,correction,prevention_rule,evidence,occurrences,correction_successes,correction_failures,confidence,status,last_seen_at,updated_at)
 values(p_project_key,'qa_health_degradation','qa_health_pool_exhausted_v1','rara_qa','Reviewer pool exhausted while review work remained pending','QA transport/rate-limit saturation; concurrent review attempts amplify provider failures','Throttle review concurrency to one worker while QA health is degraded; rank models by health and use alternate API route before retrying','When QA semantic success is degraded, do not fan out review workers. Preserve REVIEW_PENDING, back off, retry with healthiest model/API route, and never escalate to human solely for provider health.',coalesce(p_evidence,''),1,0,0,0.85,'active',now(),now())
 on conflict(project_key,error_fingerprint) do update set occurrences=public.director_error_memory.occurrences+1,last_seen_at=now(),updated_at=now(),symptom=excluded.symptom,root_cause=excluded.root_cause,correction=excluded.correction,prevention_rule=excluded.prevention_rule,evidence=excluded.evidence,status='active',confidence=greatest(public.director_error_memory.confidence,0.85);
 update public.director_repair_incidents set status='resolved',requires_human=false,resolved_at=now(),updated_at=now(),diagnosis='Autonomously recoverable QA provider-health degradation',proposed_action='Throttle QA concurrency and retry through health-ranked reviewer routes',outcome='auto_recover_qa_health'
 where project_key=p_project_key and status='needs_help' and error_class in ('stale_dispatch','progress_stall') and (task_key is null or task_key=p_task_key) and risk_level='low';
 return jsonb_build_object('ok',true,'fingerprint','qa_health_pool_exhausted_v1','project_key',p_project_key,'task_key',p_task_key);
end$$;


--
-- Name: contentflow_learned_identity_preflight(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_learned_identity_preflight(p_result text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare m text[];begin
  select array_agg(x) into m from (
    select distinct z[1] x from regexp_matches(coalesce(p_result,''),'(?i)(?:builder\s*run\s*id|builder_run_id|source_run_id|correlation\s*id|correlation_id|evidence\s*id|evidence_id)\s*(?:\||:|=)\s*([0-9]{2,}|[0-9a-f]{8}-[0-9a-f-]{27,}|[A-Za-z]+-(?:run|correlation)-[A-Za-z0-9-]+)','g') z
  ) q;
  return jsonb_build_object('ok',coalesce(cardinality(m),0)=0,'fingerprint','rara_reject_hardcoded_execution_identity_v1','matches',coalesce(to_jsonb(m),'[]'::jsonb));
end$$;


--
-- Name: contentflow_legal_admission_decision(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_legal_admission_decision(p_project_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare p public.contentflow_legal_governance_profiles%rowtype; missing text[]:=array[]::text[];
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  select * into p from public.contentflow_legal_governance_profiles where project_key=p_project_key;
  if not found then return jsonb_build_object('decision','LEGAL_HOLD','reason','missing_legal_governance_profile'); end if;
  if nullif(trim(coalesce(p.operator_name,'')),'') is null then missing:=array_append(missing,'operator_name'); end if;
  if jsonb_array_length(p.jurisdictions)=0 then missing:=array_append(missing,'jurisdictions'); end if;
  if jsonb_array_length(p.user_categories)=0 then missing:=array_append(missing,'user_categories'); end if;
  if jsonb_typeof(p.data_inventory)<>'array' then missing:=array_append(missing,'data_inventory'); end if;
  if jsonb_typeof(p.vendor_inventory)<>'array' then missing:=array_append(missing,'vendor_inventory'); end if;
  if jsonb_typeof(p.ip_license_inventory)<>'array' then missing:=array_append(missing,'ip_license_inventory'); end if;
  if p.risk_tier='unclassified' then missing:=array_append(missing,'risk_tier'); end if;
  if jsonb_array_length(p.required_legal_docs)=0 then missing:=array_append(missing,'required_legal_docs'); end if;
  if cardinality(missing)>0 then return jsonb_build_object('decision','LEGAL_HOLD','missing',to_jsonb(missing)); end if;
  if p.risk_tier='high' and p.legal_review_status<>'counsel_approved' then return jsonb_build_object('decision','LEGAL_HOLD','reason','high_risk_requires_counsel_approval'); end if;
  if p.legal_review_status='draft' then return jsonb_build_object('decision','LEGAL_HOLD','reason','legal_profile_not_approved'); end if;
  return jsonb_build_object('decision','ADMIT','risk_tier',p.risk_tier,'legal_review_status',p.legal_review_status);
end $$;


--
-- Name: contentflow_log_backlog_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_log_backlog_transition() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_run public.contentflow_builder_runs%rowtype; v_trace text; v_ver text;
begin
  if old.status is distinct from new.status and new.project_key='contentflow' then
    select * into v_run from public.contentflow_builder_runs r where r.backlog_task_id=new.id order by r.id desc limit 1;
    v_trace:=coalesce(v_run.trace_id, public.contentflow_make_trace_id('task'));
    v_ver:=coalesce(v_run.workflow_version,public.contentflow_current_workflow_version(new.project_key));
    insert into public.director_state_transition_ledger(project_key,workflow_version,trace_id,entity_type,entity_key,from_state,to_state,actor,reason,metadata)
    values(new.project_key,v_ver,v_trace,'backlog_task',new.task_key,old.status,new.status,'db_transition_guard',null,jsonb_build_object('backlog_task_id',new.id,'selected_model',new.selected_model));
  end if;
  return new;
end $$;


--
-- Name: contentflow_log_builder_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_log_builder_transition() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
 if old.status is distinct from new.status then
   insert into public.director_state_transition_ledger(project_key,workflow_version,trace_id,entity_type,entity_key,from_state,to_state,actor,reason,metadata)
   values(new.project_key,coalesce(new.workflow_version,public.contentflow_current_workflow_version(new.project_key)),new.trace_id,'builder_run',new.id::text,old.status,new.status,'builder_state_guard',new.error,jsonb_build_object('task_key',new.task_key,'model',new.selected_model,'quality_score',new.quality_score));
 end if;
 return new;
end $$;


--
-- Name: contentflow_log_worker_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_log_worker_transition() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; v_trace text; v_ver text;
begin
 if old.status is distinct from new.status or old.current_task_key is distinct from new.current_task_key then
   if new.current_task_key is not null then select * into r from public.contentflow_builder_runs where task_key=new.current_task_key order by id desc limit 1; end if;
   v_trace:=coalesce(r.trace_id,public.contentflow_make_trace_id('worker'));
   v_ver:=coalesce(r.workflow_version,public.contentflow_current_workflow_version('contentflow'));
   insert into public.director_state_transition_ledger(project_key,workflow_version,trace_id,entity_type,entity_key,from_state,to_state,actor,reason,metadata)
   values('contentflow',v_ver,v_trace,'worker',new.model_id,old.status,new.status,'worker_state_guard',new.last_outcome,jsonb_build_object('from_task',old.current_task_key,'to_task',new.current_task_key));
 end if;
 return new;
end $$;


--
-- Name: contentflow_make_span_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_make_span_id() RETURNS text
    LANGUAGE sql
    SET search_path TO 'public', 'pg_temp'
    AS $$
 select substr(md5(random()::text||clock_timestamp()::text||pg_backend_pid()::text),1,16);
$$;


--
-- Name: contentflow_make_trace_id(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_make_trace_id(p_prefix text DEFAULT 'cf'::text) RETURNS text
    LANGUAGE sql
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(nullif(p_prefix,''),'cf')||'-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||'-'||substr(md5(random()::text||clock_timestamp()::text||pg_backend_pid()::text),1,16);
$$;


--
-- Name: contentflow_mark_persistent_change_applied_v1(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_mark_persistent_change_applied_v1(p_change_id uuid, p_evidence jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
 perform public.contentflow_assert_persistent_change_admission_v1(p_change_id);
 update public.contentflow_persistent_change_provenance set status='applied',evidence=coalesce(evidence,'{}'::jsonb)||coalesce(p_evidence,'{}'::jsonb),applied_at=now(),updated_at=now() where change_id=p_change_id;
 return jsonb_build_object('applied',true,'change_id',p_change_id);
end $$;


--
-- Name: contentflow_master_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_master_reconcile(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
 v_durable1 jsonb:='{}'::jsonb;
 v_graph jsonb:='{}'::jsonb; v_orphans jsonb:='{}'::jsonb; v_state jsonb:='{}'::jsonb; v_reviews jsonb:='{}'::jsonb;
 v_retry jsonb:='{}'::jsonb; v_progress jsonb:='{}'::jsonb; v_known1 jsonb:='{}'::jsonb; v_known2 jsonb:='{}'::jsonb;
 v_slo jsonb:='{}'::jsonb; v_test jsonb:='{}'::jsonb; v_obsolete jsonb:='{}'::jsonb; v_help jsonb:='{}'::jsonb;
 v_tools jsonb:='{}'::jsonb; v_durable2 jsonb:='{}'::jsonb; v_leases int:=0; v_detected int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;

 -- PRE-REPAIR: apply explicit durable contracts before legacy detectors can misclassify WAIT as FAIL.
 begin v_durable1:=public.contentflow_durable_contract_reconcile(p_project_key); exception when others then v_durable1:=jsonb_build_object('error',sqlerrm); end;
 begin v_graph:=public.contentflow_sanitize_dependency_graph(p_project_key); exception when others then v_graph:=jsonb_build_object('error',sqlerrm); end;
 begin v_orphans:=public.contentflow_recover_orphan_claims(p_project_key,45); exception when others then v_orphans:=jsonb_build_object('error',sqlerrm); end;
 begin v_state:=public.contentflow_reconcile_runtime_state(p_project_key); exception when others then v_state:=jsonb_build_object('error',sqlerrm); end;
 begin v_leases:=public.contentflow_recover_expired_leases(p_project_key); exception when others then v_leases:=-1; end;
 begin v_reviews:=public.contentflow_review_gate_reconcile(p_project_key); exception when others then v_reviews:=jsonb_build_object('error',sqlerrm); end;
 begin v_retry:=public.contentflow_reconcile_retry_policies(p_project_key,50); exception when others then v_retry:=jsonb_build_object('error',sqlerrm); end;
 begin v_progress:=public.contentflow_progress_stall_reconcile(p_project_key); exception when others then v_progress:=jsonb_build_object('error',sqlerrm); end;
 begin v_tools:=public.contentflow_sync_tool_execution_queue(p_project_key); exception when others then v_tools:=jsonb_build_object('error',sqlerrm); end;

 -- REPAIR PASS 1
 begin v_detected:=public.rara_detect_incidents(p_project_key); exception when others then v_detected:=-1; end;
 begin v_known1:=public.rara_apply_known_repairs(p_project_key,50); exception when others then v_known1:=jsonb_build_object('error',sqlerrm); end;

 -- REPAIR PASS 2: reconcile changed contracts/states, then retry recipes before human escalation.
 begin v_durable2:=public.contentflow_durable_contract_reconcile(p_project_key); exception when others then v_durable2:=jsonb_build_object('error',sqlerrm); end;
 begin v_known2:=public.rara_apply_known_repairs(p_project_key,50); exception when others then v_known2:=jsonb_build_object('error',sqlerrm); end;
 begin v_obsolete:=public.contentflow_resolve_obsolete_incidents(p_project_key); exception when others then v_obsolete:=jsonb_build_object('error',sqlerrm); end;

 -- HUMAN HELP IS LAST, only after both autonomous passes.
 begin v_help:=public.contentflow_escalate_unresolved_incidents(p_project_key); exception when others then v_help:=jsonb_build_object('error',sqlerrm); end;
 begin v_slo:=public.contentflow_enforce_autonomy_slo(p_project_key); exception when others then v_slo:=jsonb_build_object('error',sqlerrm); end;
 begin v_test:=public.contentflow_resilience_self_test(p_project_key); exception when others then v_test:=jsonb_build_object('error',sqlerrm); end;
 return jsonb_build_object(
   'architecture','MASTER_DIRECTOR_CONTROL_PLANE_V4',
   'durable_pre_repair',v_durable1,'dependency_graph',v_graph,'orphans',v_orphans,'runtime_state',v_state,
   'leases_recovered',v_leases,'review_gate',v_reviews,'retry',v_retry,'progress',v_progress,'tool_queue',v_tools,
   'incidents_detected',v_detected,'known_repairs_pass1',v_known1,'durable_second_pass',v_durable2,
   'known_repairs_pass2',v_known2,'obsolete_resolved',v_obsolete,'help_escalation',v_help,'slo',v_slo,'resilience',v_test
 );
end;
$$;


--
-- Name: contentflow_material_claim_truth_preflight(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_material_claim_truth_preflight(p_task_key text, p_result text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  ln text;
  low text;
  trimmed text;
  violations jsonb:='[]'::jsonb;
  n int:=0;
  in_source_appendix boolean:=false;
  separator_candidate text;
begin
  if p_task_key<>'avatar_research_routes_abc_v1' then
    return jsonb_build_object('ok',true,'architecture','MATERIAL_CLAIM_TRUTH_GUARD_V3_NO_REGEX','violations','[]'::jsonb);
  end if;
  foreach ln in array regexp_split_to_array(coalesce(p_result,''), E'\\n') loop
    low:=lower(ln);
    trimmed:=btrim(low);
    if low like '%[verified primary source appendix]%' then in_source_appendix:=true; continue; end if;
    if in_source_appendix then continue; end if;
    if trimmed='' then continue; end if;

    if low like '| route | technology/component |%' then continue; end if;
    if left(trimmed,1)='|' then
      separator_candidate:=replace(replace(replace(replace(replace(trimmed,'|',''),'-',''),':',''),' ',''),E'\t','');
      if separator_candidate='' then continue; end if;
    end if;

    if left(trimmed,1)<>'|' and low not like '%evidence gap%' and low not like '%pending evidence%' then continue; end if;

    if low like '%vendor_claim%' and low like '%officially_verified%' then
      violations:=violations||jsonb_build_object('type','vendor_claim_marked_officially_verified','line',left(ln,500)); n:=n+1;
    end if;

    if low like '%vendor_claim%' and (
       low like '%latency%' or low like '%latencia%' or low like '%hardware%' or low like '%vram%' or low like '%fps%' or low like '%concurr%' or low like '%cost%' or low like '%price%' or low like '%pricing%' or low like '%quality%' or low like '%calidad%') then
      if low not like '%pending_benchmark%' and low not like '%not publicly verified%' and low not like '%unknown%' then
        violations:=violations||jsonb_build_object('type','vendor_metric_not_pending_or_unknown','line',left(ln,500)); n:=n+1;
      end if;
    end if;

    if (low like '%license%' or low like '%licence%') and low not like '%unknown%' and low not like '%not publicly verified%' and low not like '%pending evidence%' then
      if position('http://' in low)=0 and position('https://' in low)=0 then
        violations:=violations||jsonb_build_object('type','license_claim_without_inline_primary_source','line',left(ln,500)); n:=n+1;
      end if;
    end if;

    if (low like '%inferred%' or low like '%inference%' or low like '%implies%' or low like '%appears to%' or low like '%suggests that%')
       and (low like '%license%' or low like '%latency%' or low like '%hardware%' or low like '%vram%' or low like '%fps%' or low like '%cost%' or low like '%pricing%' or low like '%capability%')
       and low not like '%unknown%' and low not like '%pending%' then
      violations:=violations||jsonb_build_object('type','unsupported_material_inference','line',left(ln,500)); n:=n+1;
    end if;
  end loop;
  return jsonb_build_object('ok',n=0,'architecture','MATERIAL_CLAIM_TRUTH_GUARD_V3_NO_REGEX','violations',violations,'violation_count',n);
end $$;


--
-- Name: contentflow_materialize_verified_sources_on_review(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_materialize_verified_sources_on_review() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare ctx text;begin
  if new.status='review_required' then
    if exists(select 1 from public.contentflow_build_backlog b where b.id=new.backlog_task_id and upper(coalesce(b.acceptance_criteria,'')) like '%OFFICIAL PRIMARY SOURCES%') then
      ctx:=public.contentflow_primary_source_context(new.project_key,new.task_key);
      if ctx<>'NO_VERIFIED_PRIMARY_SOURCES' then
        if position('[VERIFIED PRIMARY SOURCE APPENDIX]' in coalesce(new.result,''))=0 then
          new.result:=coalesce(new.result,'')||E'\n\n[VERIFIED PRIMARY SOURCE APPENDIX]\n'||ctx;
        end if;
      end if;
    end if;
  end if;
  return new;
end$$;


--
-- Name: contentflow_normalize_dispatchability(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_normalize_dispatchability(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare to_ready int:=0; to_planned int:=0; to_blocked_tool int:=0; to_blocked_evidence int:=0; retry_state jsonb; cap_plan jsonb; durable jsonb;
begin
 durable:=public.contentflow_durable_contract_reconcile(p_project_key);
 cap_plan:=public.contentflow_capability_first_plan(p_project_key);
 retry_state:=public.contentflow_reconcile_retry_policies(p_project_key,200);
 update public.contentflow_build_backlog b set status='ready',updated_at=now() where b.project_key=p_project_key and b.status='planned' and (b.next_eligible_at is null or b.next_eligible_at<=now()) and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open') and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value) where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed')) and (coalesce(b.execution_lane,'llm_artifact') not in ('tool_executor','evidence_producer') or public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key)); get diagnostics to_ready=row_count;
 update public.contentflow_build_backlog b set status='planned',updated_at=now() where b.project_key=p_project_key and b.status='ready' and exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value) where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed')); get diagnostics to_planned=row_count;
 update public.contentflow_build_backlog b set status='blocked',updated_at=now() where b.project_key=p_project_key and b.status='ready' and b.execution_lane='tool_executor' and not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key); get diagnostics to_blocked_tool=row_count;
 update public.contentflow_build_backlog b set status='blocked',updated_at=now() where b.project_key=p_project_key and b.status='ready' and b.execution_lane='evidence_producer' and not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key); get diagnostics to_blocked_evidence=row_count;
 return jsonb_build_object('architecture','DURABLE_TASK_STATE_MACHINE_V2','durable_contract',durable,'capability_plan',cap_plan,'to_ready',to_ready,'to_planned',to_planned,'to_blocked_tool',to_blocked_tool,'to_blocked_evidence',to_blocked_evidence,'retry_policy',retry_state);
end $$;


--
-- Name: contentflow_normalize_fractional_judge_score(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_normalize_fractional_judge_score() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare q numeric; begin if new.event_type='judge_completed' and coalesce((new.payload->>'pass')::boolean,false)=true then q:=nullif(new.payload->>'quality_score','')::numeric; if q is not null and q>=0 and q<=1 then new.payload:=jsonb_set(new.payload,'{quality_score}',to_jsonb(round(q*100))); end if; end if; return new; end $$;


--
-- Name: contentflow_obsolete_evidence_tombstone_guard_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_obsolete_evidence_tombstone_guard_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.project_key='contentflow'
     and new.task_key like 'repair_evidence_req_%'
     and not exists(
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=new.project_key
         and (er.backlog_task_id=new.id or er.evidence_task_key=new.task_key)
         and er.status<>'obsolete'
     ) then
    new.status:='deferred';
    new.workflow_state:='obsolete';
    new.completion_phase:='obsolete';
    new.blocked_reason:='OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT';
    new.next_eligible_at:=null;
    new.selected_model:=null;
  end if;
  return new;
end $$;


--
-- Name: contentflow_persistent_change_admission_status_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_persistent_change_admission_status_v1() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 select jsonb_build_object('architecture','AUTONOMOUS_REPAIR_PROVENANCE_CONTRACT_V1','fail_closed',true,'open_intents',count(*) filter(where status='intent_registered'),'admitted',count(*) filter(where status='admitted'),'applied_unverified',count(*) filter(where status='applied'),'quarantined',count(*) filter(where status='quarantined'),'verified',count(*) filter(where status='verified')) from public.contentflow_persistent_change_provenance;
$$;


--
-- Name: contentflow_pg_net_stall_reconcile_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_pg_net_stall_reconcile_v1() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'net'
    AS $$
declare q int:=0; vmin bigint; vmax bigint; st private.contentflow_pg_net_watchdog_state%rowtype; same_oldest boolean:=false; restarted boolean:=false;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
 select count(*),min(id),max(id) into q,vmin,vmax from net.http_request_queue;
 select * into st from private.contentflow_pg_net_watchdog_state where id=1 for update;
 if q=0 then
   update private.contentflow_pg_net_watchdog_state set queue_count=0,min_request_id=null,max_request_id=null,first_seen_at=null,last_seen_at=now() where id=1;
   return jsonb_build_object('ok',true,'queue_count',0,'stalled',false,'restarted',false,'architecture','PG_NET_HEAD_OF_LINE_WATCHDOG_V2');
 end if;
 same_oldest := st.min_request_id is not null and st.min_request_id=vmin;
 if same_oldest and st.first_seen_at is not null and st.first_seen_at<=now()-interval '75 seconds' and (st.last_restart_at is null or st.last_restart_at<=now()-interval '90 seconds') then
   perform net.worker_restart();
   perform net.wait_until_running();
   perform net.wake();
   restarted:=true;
   update private.contentflow_pg_net_watchdog_state set queue_count=q,min_request_id=vmin,max_request_id=vmax,last_seen_at=now(),last_restart_at=now(),restart_count=restart_count+1 where id=1;
 else
   update private.contentflow_pg_net_watchdog_state set queue_count=q,min_request_id=vmin,max_request_id=vmax,first_seen_at=case when same_oldest then coalesce(first_seen_at,now()) else now() end,last_seen_at=now() where id=1;
 end if;
 return jsonb_build_object('ok',true,'queue_count',q,'min_request_id',vmin,'max_request_id',vmax,'oldest_unchanged',same_oldest,'first_seen_at',(select first_seen_at from private.contentflow_pg_net_watchdog_state where id=1),'stalled',same_oldest and st.first_seen_at is not null and st.first_seen_at<=now()-interval '75 seconds','restarted',restarted,'architecture','PG_NET_HEAD_OF_LINE_WATCHDOG_V2');
end $$;


--
-- Name: contentflow_pgnet_recover_if_queued(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_pgnet_recover_if_queued() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$ declare v_count integer; begin select count(*) into v_count from net.http_request_queue; if v_count>0 then perform net.worker_restart(); perform net.wait_until_running(); perform net.wake(); end if; return v_count; end $$;


--
-- Name: contentflow_plan_capability_certification_block(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_plan_capability_certification_block(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ begin if p_project_key<>'contentflow' then return jsonb_build_object('ok',true,'architecture','INFRASTRUCTURE_PLANNER_SCOPE_GUARD_V1','scope','contentflow_only','project_key',p_project_key,'skipped',true); end if; return public.contentflow_plan_capability_certification_block_internal_v1(p_project_key); end $$;


--
-- Name: contentflow_plan_capability_certification_block_internal_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_plan_capability_certification_block_internal_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_created int:=0; v_ready int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
 insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,quality_score,cost_usd,execution_lane,completion_phase,runtime_verified,updated_at)
 values
 (p_project_key,'evidence_capability','capability_certify_runtime_persistence_v1','Certify runtime persistence producer integration','Build the bounded certification harness/spec for the completed runtime-persistence producer integration. It must define the exact persisted-record positive/negative cases, correlation fields, fail-closed assertions, and the trusted runtime hook required before capability activation. Do not claim certification until runtime evidence exists.','code',3,'["capability_integrate_runtime_persistence_producer_v1"]'::jsonb,'director_buffer:block_c_certification','planned',98,'Certification artifact defines executable positive/negative persistence cases, correlation assertions, fail-closed assertions and trusted-runtime evidence contract; no fabricated runtime pass is allowed.',0,0,'llm_artifact','artifact_only',false,now()),
 (p_project_key,'evidence_capability','capability_certify_runtime_test_v1','Certify runtime test producer integration','Build the bounded certification harness/spec for the completed runtime-test producer integration. It must define executed-pass, executed-fail and unexecuted-claim rejection cases plus persisted correlation requirements. Do not claim certification until runtime evidence exists.','code',3,'["capability_integrate_runtime_test_producer_v1"]'::jsonb,'director_buffer:block_c_certification','planned',98,'Certification artifact defines executable pass/fail/unexecuted cases, persisted correlation assertions and trusted-runtime evidence contract; no fabricated runtime pass is allowed.',0,0,'llm_artifact','artifact_only',false,now()),
 (p_project_key,'evidence_capability','capability_certify_source_contract_v1','Certify source contract producer integration','Build the bounded certification harness/spec for immutable source-contract verification, including valid artifact/hash, missing artifact, hash mismatch and parse failure cases. Do not claim certification until trusted evidence exists.','code',3,'["capability_integrate_source_contract_producer_v1"]'::jsonb,'director_buffer:block_c_certification','planned',98,'Certification artifact defines executable immutable-source positive/negative cases, hash/parse assertions and trusted evidence contract; no fabricated pass is allowed.',0,0,'llm_artifact','artifact_only',false,now()),
 (p_project_key,'evidence_capability','capability_certify_registry_bridge_v1','Certify producer registry routing bridge','Build the bounded certification harness/spec proving routing precedence, producer isolation, missing-capability fail-closed behavior, and activation state transitions for all producer families. Do not mark the registry active without trusted runtime evidence.','architecture',3,'["capability_integrate_registry_bridge_v1","capability_integrate_runtime_persistence_producer_v1","capability_integrate_runtime_test_producer_v1","capability_integrate_source_contract_producer_v1"]'::jsonb,'director_buffer:block_c_certification','planned',98,'Certification artifact defines routing/isolation/activation tests and trusted runtime evidence required to turn producer_available on; no activation claim is allowed without evidence.',0,0,'llm_artifact','artifact_only',false,now())
 on conflict(project_key,task_key) do nothing;
 get diagnostics v_created=row_count;
 perform public.contentflow_normalize_dispatchability(p_project_key);
 select count(*) into v_ready from public.contentflow_build_backlog where project_key=p_project_key and team='director_buffer:block_c_certification' and status in ('planned','ready');
 insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
 values(p_project_key,'capability_certification_plan','director_buffer_planner_v3','three_block_lookahead',case when v_created>0 then 'block_c_created' when v_ready>0 then 'block_c_available' else 'block_c_waiting_dependencies' end,false,format('created=%s available=%s',v_created,v_ready),now());
 return jsonb_build_object('architecture','CAPABILITY_CERTIFICATION_BLOCK_V1','created',v_created,'available',v_ready);
end $$;


--
-- Name: contentflow_plan_execution_buffer(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_plan_execution_buffer(p_project_key text DEFAULT 'contentflow'::text, p_target integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if p_project_key='agent-academy-platform-v1' then
    return public.academy_plan_execution_buffer_v1(p_project_key,p_target);
  end if;
  if p_project_key<>'contentflow' then
    return jsonb_build_object('ok',true,'architecture','INFRASTRUCTURE_PLANNER_SCOPE_GUARD_V2','scope','unsupported_project','project_key',p_project_key,'skipped',true);
  end if;
  return public.contentflow_plan_execution_buffer_internal_v1(p_project_key,p_target);
end
$$;


--
-- Name: contentflow_plan_execution_buffer_internal_v1(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_plan_execution_buffer_internal_v1(p_project_key text DEFAULT 'contentflow'::text, p_target integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_target int:=greatest(1,least(coalesce(p_target,10),20));
  v_before int:=0;
  v_after int:=0;
  v_created_root int:=0;
  v_created_next int:=0;
  v_verifier_only int:=0;
  v_ready_workers int:=0;
  v_prepared int:=0;
  v_next_ready int:=0;
  v_norm jsonb:='{}'::jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'privileged_channel_required';
  end if;

  begin v_norm:=public.contentflow_normalize_dispatchability(p_project_key); exception when others then v_norm:=jsonb_build_object('error',sqlerrm); end;
  select count(*) into v_ready_workers from public.director_worker_queue where status='ready';
  select public.contentflow_dispatchable_count(p_project_key) into v_before;
  select count(*) into v_verifier_only from public.contentflow_evidence_coverage_plan(p_project_key) where coverage_state='verifier_only';

  -- BLOCK A: root producer capabilities. These are source/bootstrap artifacts, not claims of deployment.
  if v_verifier_only>0 then
    insert into public.contentflow_build_backlog(
      project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,
      acceptance_criteria,quality_score,cost_usd,execution_lane,updated_at
    ) values
    (p_project_key,'evidence_capability','capability_producer_runtime_persistence_v1',
     'Implement deterministic runtime persistence evidence producer',
     'Implement the reusable source artifact for a producer that reads real persisted platform/runtime records and emits correlated evidence. It must fail closed when source records are absent. This bootstrap task does not claim deployment.',
     'code',1,'[]'::jsonb,'director_buffer:block_a_root','planned',100,
     'Source artifact defines deterministic runtime-persistence producer interfaces, correlation contract, fail-closed behavior, and deterministic present/absent-record test fixtures. No deployment claim is required in this bootstrap task.',0,0,'llm_artifact',now()),
    (p_project_key,'evidence_capability','capability_producer_runtime_test_v1',
     'Implement deterministic runtime test evidence producer',
     'Implement the reusable source artifact for deterministic test-result production and persistence. It must reject prose-only or unexecuted test claims. This bootstrap task does not claim deployment.',
     'code',1,'[]'::jsonb,'director_buffer:block_a_root','planned',100,
     'Source artifact defines deterministic test producer interfaces, pass/fail contract, correlation fields, fail-closed behavior, and fixtures showing unexecuted claims are rejected. No deployment claim is required.',0,0,'llm_artifact',now()),
    (p_project_key,'evidence_capability','capability_producer_source_contract_v1',
     'Implement deterministic source contract evidence producer',
     'Implement the reusable source artifact for repository/source-contract verification by immutable path/hash. It must fail closed if the artifact cannot be fetched or parsed. This bootstrap task does not claim deployment.',
     'code',1,'[]'::jsonb,'director_buffer:block_a_root','planned',100,
     'Source artifact defines immutable artifact identity, parse/validation rules, correlation fields, fail-closed behavior and deterministic fixtures. No deployment claim is required.',0,0,'llm_artifact',now()),
    (p_project_key,'evidence_capability','capability_producer_registry_bridge_v1',
     'Implement producer capability registry and routing bridge',
     'Implement the source artifact for a single producer registry/bridge mapping evidence prerequisites to producers and keeping evidence-producer work isolated from the LLM builder. This bootstrap task does not claim deployment.',
     'architecture',1,'[]'::jsonb,'director_buffer:block_a_root','planned',100,
     'Source artifact defines one producer capability registry, prerequisite routing, lane isolation, fail-closed semantics and deterministic contract tests. No deployment claim is required.',0,0,'llm_artifact',now())
    on conflict(project_key,task_key) do nothing;
    get diagnostics v_created_root=row_count;
  end if;

  -- BLOCK B: pre-plan the next integration block immediately. It remains planned until Block A dependencies complete.
  insert into public.contentflow_build_backlog(
    project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,
    acceptance_criteria,quality_score,cost_usd,execution_lane,updated_at
  ) values
  (p_project_key,'evidence_capability','capability_integrate_runtime_persistence_producer_v1',
   'Integrate runtime persistence producer into evidence pipeline',
   'Produce the integration source artifact connecting the approved runtime-persistence producer contract to ContentFlow evidence routing and persistence interfaces. Keep activation/deployment proof as a later validation boundary.',
   'code',2,'["capability_producer_runtime_persistence_v1"]'::jsonb,'director_buffer:block_b_integration','planned',99,
   'Integration source artifact wires the producer contract into the evidence pipeline, preserves correlation/fail-closed semantics, and contains deterministic contract tests. This task does not claim live deployment.',0,0,'llm_artifact',now()),
  (p_project_key,'evidence_capability','capability_integrate_runtime_test_producer_v1',
   'Integrate runtime test producer into evidence pipeline',
   'Produce the integration source artifact connecting the approved runtime-test producer contract to ContentFlow evidence routing. Keep activation/deployment proof as a later validation boundary.',
   'code',2,'["capability_producer_runtime_test_v1"]'::jsonb,'director_buffer:block_b_integration','planned',99,
   'Integration source artifact wires deterministic test production into evidence routing, preserves correlation/fail-closed semantics, and contains deterministic contract tests. This task does not claim live deployment.',0,0,'llm_artifact',now()),
  (p_project_key,'evidence_capability','capability_integrate_source_contract_producer_v1',
   'Integrate source contract producer into evidence pipeline',
   'Produce the integration source artifact connecting the approved source-contract producer contract to ContentFlow evidence routing. Keep activation/deployment proof as a later validation boundary.',
   'code',2,'["capability_producer_source_contract_v1"]'::jsonb,'director_buffer:block_b_integration','planned',99,
   'Integration source artifact wires immutable source-contract verification into evidence routing, preserves fail-closed semantics, and contains deterministic contract tests. This task does not claim live deployment.',0,0,'llm_artifact',now()),
  (p_project_key,'evidence_capability','capability_integrate_registry_bridge_v1',
   'Integrate producer registry bridge with all producer families',
   'Produce the integration source artifact joining the approved registry/bridge with runtime-persistence, runtime-test and source-contract producer interfaces. Keep activation/deployment proof as a later validation boundary.',
   'architecture',2,'["capability_producer_registry_bridge_v1","capability_producer_runtime_persistence_v1","capability_producer_runtime_test_v1","capability_producer_source_contract_v1"]'::jsonb,'director_buffer:block_b_integration','planned',99,
   'Integration artifact defines one coherent producer registry, routing precedence, capability state transitions, lane isolation, fail-closed behavior and contract tests. This task does not claim live deployment.',0,0,'llm_artifact',now())
  on conflict(project_key,task_key) do nothing;
  get diagnostics v_created_next=row_count;

  begin v_norm:=public.contentflow_normalize_dispatchability(p_project_key); exception when others then v_norm:=coalesce(v_norm,'{}'::jsonb)||jsonb_build_object('post_error',sqlerrm); end;
  select public.contentflow_dispatchable_count(p_project_key) into v_after;
  select count(*) into v_prepared from public.contentflow_build_backlog
    where project_key=p_project_key and team in ('director_buffer:block_a_root','director_buffer:block_b_integration') and status in ('planned','ready','running','blocked','review_required','verification_required');
  select count(*) into v_next_ready from public.contentflow_build_backlog
    where project_key=p_project_key and team='director_buffer:block_b_integration' and status='ready';

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'execution_buffer_plan','director_buffer_planner_v2','deterministic_two_block_lookahead',
         case when v_created_root+v_created_next>0 then 'tasks_created' when v_after>0 then 'buffer_executable' else 'next_block_prepared_waiting_dependencies' end,
         false,
         format('target=%s ready_workers=%s dispatchable_before=%s dispatchable_after=%s verifier_only=%s root_created=%s next_created=%s prepared=%s next_ready=%s',v_target,v_ready_workers,v_before,v_after,v_verifier_only,v_created_root,v_created_next,v_prepared,v_next_ready),now());

  return jsonb_build_object(
    'architecture','DETERMINISTIC_EXECUTION_BUFFER_PLANNER_V2_TWO_BLOCK_LOOKAHEAD',
    'target',v_target,'ready_workers',v_ready_workers,
    'dispatchable_before',v_before,'dispatchable_after',v_after,
    'verifier_only_requirements',v_verifier_only,
    'root_created',v_created_root,'next_block_created',v_created_next,
    'prepared_block_tasks',v_prepared,'next_block_ready',v_next_ready,
    'normalize',v_norm
  );
end
$$;


--
-- Name: contentflow_platform_get_active_evidence(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_platform_get_active_evidence(p_builder_run_id bigint, p_resource_id text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select l.payload
  from public.contentflow_runtime_evidence_ledger l
  where l.builder_run_id=p_builder_run_id
    and (
      l.payload->>'resource'=p_resource_id
      or l.payload->>'resource_id'=p_resource_id
      or l.payload->>'review_id'=p_resource_id
      or l.payload->>'workflow_id'=p_resource_id
    )
    and coalesce(l.payload->>'event','') not in ('review_evidence_missing')
    and coalesce(l.payload->>'event_type','') not in ('review_evidence_missing')
  order by l.id desc limit 1;
$$;


--
-- Name: contentflow_platform_record_evidence(bigint, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_platform_record_evidence(p_builder_run_id bigint, p_event jsonb, p_evidence_key text DEFAULT NULL::text, p_producer text DEFAULT 'contentflow-platform-store'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_event_type text;
  v_key text;
  v_result jsonb;
  v_id bigint;
  v_hash text;
  v_uri text;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;
  if p_builder_run_id is null or p_builder_run_id<=0 then raise exception 'builder_run_required'; end if;
  if p_event is null or p_event='{}'::jsonb or jsonb_typeof(p_event)<>'object' then raise exception 'nonempty_event_object_required'; end if;
  v_event_type:=coalesce(nullif(trim(p_event->>'event'),''),'runtime_evidence');
  v_key:=coalesce(nullif(trim(p_evidence_key),''),format('platform:%s:%s:%s',p_builder_run_id,v_event_type,left(md5(p_event::text),16)));
  v_result:=public.contentflow_record_runtime_evidence(
    p_builder_run_id,
    'runtime_evidence',
    v_key,
    p_event,
    coalesce(nullif(trim(p_producer),''),'contentflow-platform-store'),
    now()
  );
  v_id:=(v_result->>'evidence_id')::bigint;
  v_hash:=v_result->>'sha256';
  if v_id is null or coalesce(v_hash,'')='' then raise exception 'runtime_evidence_write_failed'; end if;
  v_uri:=format('supabase://contentflow_runtime_evidence_ledger/%s?sha256=%s',v_id,v_hash);
  return v_result||jsonb_build_object('storage_uri',v_uri,'event_type',v_event_type,'evidence_key',v_key,'append_only',true);
end $$;


--
-- Name: contentflow_precycle_evidence_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_precycle_evidence_reconcile(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_first jsonb:='{}'::jsonb;
  v_ci jsonb:='{}'::jsonb;
  v_cap jsonb:='{}'::jsonb;
  v_accept jsonb:='{}'::jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;
  begin v_first:=public.contentflow_evidence_first_reconcile(p_project_key,100); exception when others then v_first:=jsonb_build_object('error',sqlerrm); end;
  begin v_ci:=public.contentflow_reconcile_ci_requirement_evidence(p_project_key); exception when others then v_ci:=jsonb_build_object('error',sqlerrm); end;
  begin v_cap:=public.contentflow_reconcile_evidence_capability_queue(p_project_key); exception when others then v_cap:=jsonb_build_object('error',sqlerrm); end;
  begin v_accept:=public.contentflow_reconcile_acceptance_evidence_incidents(p_project_key); exception when others then v_accept:=jsonb_build_object('error',sqlerrm); end;
  return jsonb_build_object('architecture','LEARNED_EVIDENCE_PRE_CYCLE_V1','evidence_first',v_first,'ci_bridge',v_ci,'capability_queue',v_cap,'incident_reconcile',v_accept);
end;
$$;


--
-- Name: contentflow_preroute_acceptance_work(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_preroute_acceptance_work(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_tool int:=0; v_producer int:=0; v_blocked int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;

  update public.contentflow_build_backlog b
     set execution_lane='tool_executor', updated_at=now()
   where b.project_key=p_project_key
     and b.status in ('planned','ready','blocked')
     and exists (
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=b.project_key and er.evidence_task_key=b.task_key
         and public.contentflow_evidence_verifier_preflight(p_project_key,b.task_key)
     )
     and b.execution_lane is distinct from 'tool_executor';
  get diagnostics v_tool=row_count;

  update public.contentflow_build_backlog b
     set execution_lane='evidence_producer', updated_at=now()
   where b.project_key=p_project_key
     and b.status in ('planned','ready','blocked')
     and exists (
       select 1 from public.contentflow_evidence_requirements er
       join public.contentflow_evidence_capability_registry cr
         on cr.prerequisite=public.contentflow_evidence_prerequisite_class(er.requirement_class,er.requirement_text)
       where er.project_key=b.project_key and er.evidence_task_key=b.task_key
         and not public.contentflow_evidence_verifier_preflight(p_project_key,b.task_key)
         and coalesce(cr.producer_available,false)
     )
     and b.execution_lane is distinct from 'evidence_producer';
  get diagnostics v_producer=row_count;

  update public.contentflow_build_backlog b
     set status='blocked', blocked_reason='CAPABILITY_NOT_AVAILABLE', updated_at=now()
   where b.project_key=p_project_key
     and b.status in ('planned','ready')
     and exists (
       select 1 from public.contentflow_evidence_requirements er
       left join public.contentflow_evidence_capability_registry cr
         on cr.prerequisite=public.contentflow_evidence_prerequisite_class(er.requirement_class,er.requirement_text)
       where er.project_key=b.project_key and er.evidence_task_key=b.task_key
         and not public.contentflow_evidence_verifier_preflight(p_project_key,b.task_key)
         and not coalesce(cr.producer_available,false)
     );
  get diagnostics v_blocked=row_count;

  return jsonb_build_object('architecture','PRE_ROUTING_ACCEPTANCE_CLASSIFIER_V1','to_tool_executor',v_tool,'to_evidence_producer',v_producer,'blocked_missing_capability',v_blocked);
end $$;


--
-- Name: contentflow_primary_source_context(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_primary_source_context(p_project_key text, p_task_key text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
 select coalesce(string_agg(format('[VERIFIED_PRIMARY_SOURCE] provider=%s | title=%s | url=%s | date=%s | scope=%s',provider,source_title,source_url,coalesce(publication_or_update_date,'UNKNOWN'),coalesce(claim_scope,'UNSPECIFIED')),E'\n' order by id),'NO_VERIFIED_PRIMARY_SOURCES')
 from public.contentflow_primary_source_evidence
 where project_key=p_project_key and task_key=p_task_key and verification_status='verified' and source_type='official_primary'
$$;


--
-- Name: contentflow_primary_source_gate(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_primary_source_gate(p_project_key text, p_task_key text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare c int; domains int;begin
 select count(*),count(distinct source_domain) into c,domains
 from public.contentflow_primary_source_evidence
 where project_key=p_project_key and task_key=p_task_key and verification_status='verified' and source_type='official_primary';
 return jsonb_build_object('ok',c>=5 and domains>=4,'verified_primary_sources',c,'distinct_official_domains',domains,'minimum_sources',5,'minimum_domains',4,'architecture','PRIMARY_SOURCE_EVIDENCE_GATE_V1');
end$$;


--
-- Name: contentflow_progress_stall_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_progress_stall_reconcile(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_ready int:=0; v_ready_total int:=0; v_workers int:=0; v_running int:=0; v_before int:=0; v_after int:=0; v_retry_cleaned int:=0; v_dep_fixed int:=0; v_created int:=0; v_resolved int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 select count(*) into v_ready_total from public.contentflow_build_backlog where project_key=p_project_key and status='ready';
 select count(*) into v_ready from public.contentflow_build_backlog where project_key=p_project_key and status='ready' and (next_eligible_at is null or next_eligible_at<=now());
 select count(*) into v_workers from public.director_worker_queue where status='ready';
 select count(*) into v_running from public.director_worker_queue where status='running';
 begin v_before:=public.contentflow_dispatchable_count(p_project_key); exception when others then v_before:=0; end;

 delete from public.contentflow_retry_state s using public.contentflow_build_backlog b
 where s.backlog_task_id=b.id and s.project_key=p_project_key and b.project_key=p_project_key
   and s.circuit_state='open' and b.status='ready' and (b.next_eligible_at is null or b.next_eligible_at<=now()) and b.updated_at>s.updated_at
   and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.id>s.last_run_id and r.status in ('failed','deferred'));
 get diagnostics v_retry_cleaned=row_count;

 with fixed as (
   select b.id, coalesce(jsonb_agg(to_jsonb(x.dep) order by x.ord) filter(where x.dep is not null),'[]'::jsonb) deps
   from public.contentflow_build_backlog b
   left join lateral (
     select dep, min(ord) ord from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) with ordinality d(dep,ord)
     where dep<>b.task_key group by dep
   ) x on true
   where b.project_key=p_project_key and b.status in ('planned','ready','blocked','verification_required')
   group by b.id
 )
 update public.contentflow_build_backlog b set depends_on=f.deps,updated_at=case when b.depends_on is distinct from f.deps then now() else b.updated_at end
 from fixed f where b.id=f.id and b.depends_on is distinct from f.deps;
 get diagnostics v_dep_fixed=row_count;

 begin v_after:=public.contentflow_dispatchable_count(p_project_key); exception when others then v_after:=0; end;
 select count(*) into v_ready_total from public.contentflow_build_backlog where project_key=p_project_key and status='ready';
 select count(*) into v_ready from public.contentflow_build_backlog where project_key=p_project_key and status='ready' and (next_eligible_at is null or next_eligible_at<=now());
 select count(*) into v_workers from public.director_worker_queue where status='ready';
 select count(*) into v_running from public.director_worker_queue where status='running';

 if v_ready>0 and v_workers>0 and v_running=0 and v_after=0 then
   insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status,max_attempts,requires_human)
   select p_project_key,'director_control','progress_stall','progress_stall','Eligible ready work and ready workers exist but no task is dispatchable and no worker is running',jsonb_build_object('ready_eligible',v_ready,'ready_total',v_ready_total,'workers_ready',v_workers,'workers_running',v_running,'dispatchable_before',v_before,'dispatchable_after',v_after,'retry_state_cleaned',v_retry_cleaned,'dependency_rows_fixed',v_dep_fixed),'medium','open',3,false
   where not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='progress_stall' and i.status in ('open','analyzing','repairing','validating','needs_help'));
   get diagnostics v_created=row_count;
 else
   update public.director_repair_incidents
      set status='resolved',resolved_at=now(),updated_at=now(),outcome='progress_state_truthfully_healthy_v3',requires_human=false,
          validation=format('healthy_state: running=%s dispatchable=%s ready_eligible=%s ready_total=%s workers_ready=%s',v_running,v_after,v_ready,v_ready_total,v_workers)
    where project_key=p_project_key and error_fingerprint='progress_stall'
      and status in ('open','analyzing','repairing','validating','needs_help')
      and (v_running>0 or v_after>0 or v_ready=0 or v_workers=0);
   get diagnostics v_resolved=row_count;
 end if;

 insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
 values(p_project_key,'progress_stall_reconcile','master_director_v3','eligible_desired_vs_actual',case when v_after>0 or v_ready=0 or v_workers=0 or v_running>0 then 'healthy_or_repaired' else 'stalled' end,false,jsonb_build_object('ready_eligible',v_ready,'ready_total',v_ready_total,'workers_ready',v_workers,'running',v_running,'dispatchable_before',v_before,'dispatchable_after',v_after,'retry_cleaned',v_retry_cleaned,'deps_fixed',v_dep_fixed,'incident_created',v_created,'incidents_resolved',v_resolved)::text,now());
 return jsonb_build_object('ready_eligible',v_ready,'ready_total',v_ready_total,'workers_ready',v_workers,'running',v_running,'dispatchable_before',v_before,'dispatchable_after',v_after,'retry_cleaned',v_retry_cleaned,'deps_fixed',v_dep_fixed,'incident_created',v_created,'incidents_resolved',v_resolved);
end $$;


--
-- Name: contentflow_promote_safe_learnings(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_promote_safe_learnings(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_promoted int:=0;
begin
  insert into public.director_repair_recipes(
    project_key,recipe_key,error_class,component,fingerprint_prefix,action_type,action_payload,risk_level,
    min_confidence,confidence,successes,failures,max_consecutive_failures,validation_type,enabled,notes,updated_at
  )
  select m.project_key,
         'learned:'||md5(m.error_fingerprint||':'||m.correction),
         m.error_class,m.component,m.error_fingerprint,m.correction,'{}'::jsonb,'low',
         0.80,m.confidence,m.correction_successes,0,2,'learned_incident_recurrence',true,
         'Auto-promoted only after >=3 verified successful corrections and zero recorded correction failures.',now()
  from public.director_error_memory m
  where m.project_key=p_project_key and m.status='active'
    and m.correction in ('collect_dispatches','restart_pg_net','requeue_failed_task','review_gate_reconcile','runtime_state_reconcile','progress_stall_reconcile')
    and m.correction_successes>=3 and m.correction_failures=0 and m.confidence>=0.80
  on conflict(project_key,recipe_key) do update set
    confidence=greatest(director_repair_recipes.confidence,excluded.confidence),
    successes=greatest(director_repair_recipes.successes,excluded.successes),
    enabled=true,updated_at=now();
  get diagnostics v_promoted=row_count;
  return jsonb_build_object('promoted_or_refreshed',v_promoted);
end $$;


--
-- Name: contentflow_quarantine_cross_lane_builder_runs(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_quarantine_cross_lane_builder_runs(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_runs int:=0; v_workers int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;

  with bad as (
    select r.id,r.selected_model,r.task_key
    from public.contentflow_builder_runs r
    join public.contentflow_build_backlog b on b.id=r.backlog_task_id
    where r.project_key=p_project_key
      and r.status in ('claimed','running','review_required')
      and r.finished_at is null
      and (coalesce(b.execution_lane,'llm_artifact')<>'llm_artifact' or b.task_key like 'evidence_%')
    for update of r
  ), released as (
    update public.director_worker_queue w
       set status='ready',current_task_key=null,updated_at=now()
      from bad
     where bad.selected_model is not null
       and w.model_id=bad.selected_model
       and w.current_task_key=bad.task_key
    returning w.model_id
  )
  select count(*) into v_workers from released;

  update public.contentflow_builder_runs r
     set status='deferred',
         finished_at=now(),
         error=coalesce(r.error||' | ','')||'TOOL_LANE_BUILDER_RUN_QUARANTINED',
         lease_revoked_at=now(),
         lease_expires_at=least(coalesce(r.lease_expires_at,now()),now())
   where r.project_key=p_project_key
     and r.status in ('claimed','running','review_required')
     and r.finished_at is null
     and exists(
       select 1 from public.contentflow_build_backlog b
       where b.id=r.backlog_task_id
         and (coalesce(b.execution_lane,'llm_artifact')<>'llm_artifact' or b.task_key like 'evidence_%')
     );
  get diagnostics v_runs=row_count;

  return jsonb_build_object(
    'architecture','LANE_ISOLATION_QUARANTINE_V1',
    'builder_runs_quarantined',v_runs,
    'workers_released',v_workers
  );
end $$;


--
-- Name: contentflow_quarantine_model_for_task(text, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_quarantine_model_for_task(p_project_key text, p_task_key text, p_model_id text, p_reason text, p_seconds integer DEFAULT 1800) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
 if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
 insert into public.contentflow_model_task_quarantine(project_key,task_key,model_id,reason,failures,first_seen_at,last_seen_at,expires_at)
 values(coalesce(p_project_key,'contentflow'),p_task_key,p_model_id,left(coalesce(p_reason,'semantic_invalid_response'),300),1,now(),now(),now()+make_interval(secs=>greatest(60,least(coalesce(p_seconds,1800),21600))))
 on conflict(project_key,task_key,model_id) do update set reason=excluded.reason,failures=contentflow_model_task_quarantine.failures+1,last_seen_at=now(),expires_at=greatest(contentflow_model_task_quarantine.expires_at,excluded.expires_at);
end $$;


--
-- Name: contentflow_queue_aging_reconcile(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_queue_aging_reconcile(p_project_key text DEFAULT 'contentflow'::text, p_attempt_budget integer DEFAULT 12) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_stale int:=0; v_budget int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;

  update public.contentflow_tool_execution_queue
     set state='blocked',claim_token=null,claimed_at=null,last_error='STALE_CLAIM_RECOVERED',updated_at=now()
   where project_key=p_project_key and state='claimed' and claimed_at<now()-interval '10 minutes';
  get diagnostics v_stale=row_count;

  update public.contentflow_tool_execution_queue
     set state='blocked',last_error='RETRY_BUDGET_EXHAUSTED',updated_at=now()
   where project_key=p_project_key and state='pending' and attempts>=greatest(1,p_attempt_budget);
  get diagnostics v_budget=row_count;

  update public.contentflow_build_backlog b set status='blocked',blocked_reason='RETRY_BUDGET_EXHAUSTED',updated_at=now()
   where b.project_key=p_project_key and exists(select 1 from public.contentflow_tool_execution_queue q where q.backlog_task_id=b.id and q.project_key=p_project_key and q.state='blocked' and q.last_error='RETRY_BUDGET_EXHAUSTED') and b.status<>'completed';

  return jsonb_build_object('architecture','QUEUE_AGING_RETRY_BUDGET_V1','stale_claims_recovered',v_stale,'retry_budget_blocked',v_budget,'attempt_budget',p_attempt_budget);
end $$;


--
-- Name: contentflow_rara_evidence_complete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_rara_evidence_complete(p_run_id bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select
    exists(select 1 from public.contentflow_runtime_event_ledger e where e.builder_run_id=p_run_id and e.event_type='claimed')
    and exists(select 1 from public.contentflow_runtime_event_ledger e where e.builder_run_id=p_run_id and e.event_type in ('runner_started','runner_v2_started','runner_v4_started','runner_v5_started'))
    and exists(select 1 from public.contentflow_runtime_event_ledger e where e.builder_run_id=p_run_id and e.event_type='artifact_generated')
    and exists(select 1 from public.contentflow_runtime_event_ledger e where e.builder_run_id=p_run_id and e.event_type='judge_completed')
    and exists(select 1 from public.contentflow_runtime_event_ledger e where e.builder_run_id=p_run_id and e.event_type='runner_completed')
    and exists(select 1 from public.contentflow_runtime_event_ledger e where e.builder_run_id=p_run_id and e.event_type='owner_finalized');
$$;


--
-- Name: contentflow_recommended_parallelism(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_recommended_parallelism(p_project_key text DEFAULT 'contentflow'::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare p public.director_canary_policy%rowtype; prod_max int:=1; clean int:=0; bad int:=0; runs int:=0; fails int:=0; total int:=0; rate numeric:=0;
begin
  select * into p from public.director_canary_policy where id=1;
  select greatest(1,coalesce(production_max,1)) into prod_max from public.contentflow_nexo_lane_status limit 1;
  if not coalesce(p.enabled,true) then return prod_max; end if;
  select count(*), count(*) filter(where status='failed' or coalesce((post_state->>'active_state_mismatches')::int,0)>0)
    into runs,bad from (select * from public.director_cycle_runs where project_key=p_project_key order by id desc limit greatest(1,p.required_clean_cycles)) x;
  clean:=runs-bad;
  select count(*) filter(where r.status='failed'),count(*)
    into fails,total
  from public.contentflow_builder_runs r
  join public.contentflow_build_backlog b on b.id=r.backlog_task_id
  where r.project_key=p_project_key
    and r.created_at>now()-interval '60 minutes'
    and coalesce(b.execution_lane,'llm_artifact')='llm_artifact';
  if total>0 then rate:=fails::numeric/total::numeric; end if;
  if runs<p.required_clean_cycles or bad>0 or rate>p.max_recent_failure_rate then
    return least(prod_max,greatest(1,p.bootstrap_parallelism));
  end if;
  return least(prod_max,greatest(1,p.stable_parallelism));
end $$;


--
-- Name: contentflow_reconcile_acceptance_evidence_incidents(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_acceptance_evidence_incidents(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_verified int:=0;
  v_routed int:=0;
  v_obsolete_evidence_incidents int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;

  update public.director_repair_incidents i
     set status='resolved_obsolete',resolved_at=coalesce(i.resolved_at,now()),updated_at=now(),requires_human=false,
         executed_action='suppressed_recursive_evidence_incident',
         validation='evidence tasks are handled by the evidence pipeline and must not recursively create acceptance-evidence repair incidents',
         outcome='resolved_recursive_evidence_incident'
   where i.project_key=p_project_key and i.error_class='acceptance_evidence' and i.status in ('open','analyzing','needs_help')
     and i.task_key like 'evidence_%';
  get diagnostics v_obsolete_evidence_incidents=row_count;

  update public.director_repair_incidents i
     set status='resolved',resolved_at=coalesce(i.resolved_at,now()),updated_at=now(),requires_human=false,
         validation='all persisted evidence requirements verified',outcome='resolved_by_evidence_reconciliation',
         executed_action=coalesce(i.executed_action,'evidence requirements reconciled automatically')
   where i.project_key=p_project_key and i.error_class='acceptance_evidence' and i.status in ('open','analyzing','needs_help')
     and exists(
       select 1 from public.contentflow_build_backlog b
       where b.project_key=i.project_key and b.task_key=i.task_key and b.runtime_verified=true
         and exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and er.backlog_task_id=b.id)
         and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and er.backlog_task_id=b.id and er.status<>'verified')
     );
  get diagnostics v_verified=row_count;

  update public.director_repair_incidents i
     set status='resolved',resolved_at=coalesce(i.resolved_at,now()),updated_at=now(),requires_human=false,
         executed_action='routed_to_evidence_pipeline',
         validation='repair incident resolved by deterministic routing; source task remains blocked until persisted evidence verifies',
         outcome='resolved_by_evidence_pipeline_routing'
   where i.project_key=p_project_key and i.error_class='acceptance_evidence' and i.status in ('open','analyzing','needs_help')
     and exists(
       select 1 from public.contentflow_build_backlog b
       join public.contentflow_evidence_requirements er on er.project_key=b.project_key and er.backlog_task_id=b.id and er.status='task_created'
       join public.contentflow_build_backlog e on e.project_key=er.project_key and e.task_key=er.evidence_task_key
       where b.project_key=i.project_key and b.task_key=i.task_key
         and b.status='blocked' and b.completion_phase='waiting_for_evidence'
         and e.status in ('blocked','ready','deferred','completed') and e.execution_lane='evidence_producer'
     );
  get diagnostics v_routed=row_count;

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'acceptance_evidence_incident_reconcile','master_director_v3','deterministic_reconcile',
         case when v_verified+v_routed+v_obsolete_evidence_incidents>0 then 'resolved' else 'no_change' end,false,
         format('verified_resolved=%s routed_resolved=%s recursive_suppressed=%s',v_verified,v_routed,v_obsolete_evidence_incidents),now());

  return jsonb_build_object('architecture','ACCEPTANCE_EVIDENCE_RECONCILE_V3','verified_resolved',v_verified,'routed_resolved',v_routed,'recursive_suppressed',v_obsolete_evidence_incidents);
end
$$;


--
-- Name: contentflow_reconcile_capability_certifications(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_capability_certifications(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare cap text; cert_task_key text; v record; activated int:=0; pending int:=0; failed int:=0; ev_id bigint;
begin
  for cap,cert_task_key in select * from (values
    ('runtime_persistence','capability_certify_runtime_persistence_v1'),
    ('runtime_test','capability_certify_runtime_test_v1'),
    ('source_contract','capability_certify_source_contract_v1')
  ) x(capability,cert_task) loop
    v:=null;
    select rv.id verification_id,rv.builder_run_id,rv.evidence,rv.verifier,br.review_approved,br.status run_status,br.quality_score,b.status task_status,b.quality_score task_quality
      into v
    from public.contentflow_runtime_verifications rv
    join public.contentflow_builder_runs br on br.id=rv.builder_run_id
    join public.contentflow_build_backlog b on b.id=br.backlog_task_id
    where b.project_key=p_project_key and b.task_key=cert_task_key
      and rv.verification_type='capability_'||cap||'_e2e' and rv.passed=true
    order by rv.id desc limit 1;

    if v.verification_id is null and cap in ('runtime_persistence','source_contract') then
      select rv.id verification_id,rv.builder_run_id,rv.evidence,rv.verifier,br.review_approved,br.status run_status,br.quality_score,b.status task_status,b.quality_score task_quality
        into v
      from public.contentflow_runtime_verifications rv
      join public.contentflow_builder_runs br on br.id=rv.builder_run_id
      join public.contentflow_build_backlog b on b.id=br.backlog_task_id
      where b.project_key=p_project_key
        and b.task_key=case cap when 'runtime_persistence' then 'capability_runtime_persistence_producer_v1' else 'capability_source_contract_producer_v1' end
        and rv.verification_type='capability_'||cap||'_e2e' and rv.passed=true
      order by rv.id desc limit 1;
    end if;

    if v.verification_id is null then
      insert into public.contentflow_capability_certifications(prerequisite,project_key,status,certification_task_key,last_error,updated_at)
      values(cap,p_project_key,'pending',cert_task_key,'runtime_verification_missing',now())
      on conflict(prerequisite) do update set status='pending',last_error='runtime_verification_missing',updated_at=now();
      pending:=pending+1; continue;
    end if;

    ev_id:=null; begin ev_id:=nullif(v.evidence->>'evidence_id','')::bigint; exception when others then ev_id:=null; end;

    if coalesce(v.review_approved,false)=true and v.run_status='completed' and coalesce(v.task_quality,v.quality_score,0)>=85 then
      insert into public.contentflow_capability_certifications(prerequisite,project_key,status,certification_task_key,certification_run_id,verification_id,evidence_id,verifier,quality_score,certified_at,last_error,evidence,updated_at)
      values(cap,p_project_key,'certified',cert_task_key,v.builder_run_id,v.verification_id,ev_id,v.verifier,coalesce(v.task_quality,v.quality_score),now(),null,v.evidence,now())
      on conflict(prerequisite) do update set status='certified',certification_task_key=excluded.certification_task_key,certification_run_id=excluded.certification_run_id,verification_id=excluded.verification_id,evidence_id=excluded.evidence_id,verifier=excluded.verifier,quality_score=excluded.quality_score,certified_at=coalesce(contentflow_capability_certifications.certified_at,now()),last_error=null,evidence=excluded.evidence,updated_at=now();
      update public.contentflow_evidence_capability_registry
         set producer_available=true,
             provider='contentflow-capability-e2e-certifier',
             scope='certified bounded producer; activation requires persisted E2E verification plus RARA-approved run',
             updated_at=now()
       where prerequisite=cap;
      activated:=activated+1;
    else
      insert into public.contentflow_capability_certifications(prerequisite,project_key,status,certification_task_key,certification_run_id,verification_id,evidence_id,verifier,quality_score,last_error,evidence,updated_at)
      values(cap,p_project_key,'runtime_passed',cert_task_key,v.builder_run_id,v.verification_id,ev_id,v.verifier,coalesce(v.task_quality,v.quality_score),'awaiting_rara_approval_or_completed_run',v.evidence,now())
      on conflict(prerequisite) do update set status='runtime_passed',certification_task_key=excluded.certification_task_key,certification_run_id=excluded.certification_run_id,verification_id=excluded.verification_id,evidence_id=excluded.evidence_id,verifier=excluded.verifier,quality_score=excluded.quality_score,last_error=excluded.last_error,evidence=excluded.evidence,updated_at=now();
      update public.contentflow_evidence_capability_registry set producer_available=false,updated_at=now() where prerequisite=cap;
      pending:=pending+1;
    end if;
  end loop;
  perform public.contentflow_normalize_dispatchability(p_project_key);
  return jsonb_build_object('architecture','CAPABILITY_CERTIFICATION_PIPELINE_V1','certified',activated,'pending',pending,'failed',failed);
end $$;


--
-- Name: contentflow_reconcile_ci_requirement_evidence(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_ci_requirement_evidence(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_verified int:=0; v_completed int:=0; v_reopened int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then raise exception 'privileged_channel_required'; end if;
  with eligible as (
    select er.id,er.evidence_task_key,l.id evidence_id,l.evidence_type,l.evidence_key,l.payload,l.payload_sha256,l.producer,l.observed_at
    from public.contentflow_evidence_requirements er
    join lateral (
      select x.* from public.contentflow_runtime_evidence_ledger x
      where x.project_key=er.project_key and x.requirement_id=er.id and x.builder_run_id=er.source_run_id and x.task_key=er.task_key
        and x.producer in ('github-actions-ci','supabase-edge-runtime')
        and coalesce((x.payload->>'passed')::boolean,false)=true
        and (
          (er.requirement_class='runtime_test' and x.evidence_type='runtime_test') or
          (er.requirement_class='static_analysis' and x.evidence_type='static_analysis') or
          (er.requirement_class='source_contract' and x.evidence_type in ('source_contract','runtime_test')) or
          (er.requirement_class in ('runtime_evidence','persistence_integration') and x.evidence_type in ('runtime_test','runtime_evidence'))
        )
      order by x.id desc limit 1
    ) l on true
    where er.project_key=p_project_key and er.status='task_created'
  )
  update public.contentflow_evidence_requirements er set status='verified',verified_at=now(),updated_at=now(),
    evidence_ref=jsonb_build_object('architecture','TRUSTED_RUNTIME_EVIDENCE_BRIDGE_V3','evidence_id',e.evidence_id,'evidence_type',e.evidence_type,'evidence_key',e.evidence_key,'sha256',e.payload_sha256,'producer',e.producer,'observed_at',e.observed_at,'payload',e.payload)
  from eligible e where er.id=e.id;
  get diagnostics v_verified=row_count;

  update public.contentflow_build_backlog b set status='completed',runtime_verified=true,
    runtime_evidence=coalesce(er.evidence_ref,'{}'::jsonb),quality_score=greatest(coalesce(b.quality_score,0),100),completion_phase='evidence_verified',updated_at=now()
  from public.contentflow_evidence_requirements er
  where er.project_key=p_project_key and er.status='verified' and b.project_key=er.project_key and b.task_key=er.evidence_task_key and b.status<>'completed';
  get diagnostics v_completed=row_count;

  update public.contentflow_build_backlog b set status='ready',next_eligible_at=now(),completion_phase='evidence_verified',updated_at=now()
  where b.project_key=p_project_key and b.status='blocked' and b.completion_phase='waiting_for_evidence'
    and not exists(select 1 from public.contentflow_evidence_requirements er where er.backlog_task_id=b.id and er.status<>'verified')
    and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required','verification_required') and r.finished_at is null)
    and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog dep where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'));
  get diagnostics v_reopened=row_count;
  return jsonb_build_object('architecture','TRUSTED_RUNTIME_EVIDENCE_BRIDGE_V3','requirements_verified',v_verified,'evidence_tasks_completed',v_completed,'originals_reopened',v_reopened);
end $$;


--
-- Name: contentflow_reconcile_completion_evidence_v3(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_completion_evidence_v3(p_project_key text DEFAULT 'contentflow'::text, p_limit integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare x record; v_mode text; v_req_class text; v_fp text; v_evidence_key text; v_req_id bigint; v_created int:=0; v_rerouted int:=0; v_artifact_completed int:=0; v_promoted int:=0; v_unclassified int:=0; v_incidents int:=0; v_child record; v_v jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;

  update public.contentflow_build_backlog b set execution_lane='evidence_producer',completion_phase='evidence_required',status='ready',selected_model=null,next_eligible_at=now(),blocked_reason=null,
         workflow_contract=coalesce(b.workflow_contract,'{}'::jsonb)||jsonb_build_object('contract_version','3','artifact_kind','evidence_activity','runtime_required',true,'evidence_policy','required','completion_gate','runtime_evidence_verified','retry_policy','typed_transient_only'),updated_at=now()
  where b.project_key=p_project_key and b.status='verification_required' and (b.task_key like 'repair_evidence_req_%' or lower(b.title) like 'produce real evidence%')
    and exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and er.evidence_task_key=b.task_key and er.status<>'obsolete');
  get diagnostics v_rerouted=row_count;

  for x in
    select b.*,r.id run_id,r.quality_score run_quality,r.review_approved,r.result run_result
    from public.contentflow_build_backlog b
    join lateral (select z.* from public.contentflow_builder_runs z where z.backlog_task_id=b.id order by z.id desc limit 1) r on true
    where b.project_key=p_project_key and b.status='verification_required'
      and b.task_key not like 'repair_evidence_req_%' and lower(b.title) not like 'produce real evidence%'
      and coalesce(r.review_approved,false)=true and r.result is not null and length(trim(r.result))>=40
    order by b.priority desc,b.id asc
    limit greatest(1,least(coalesce(p_limit,100),300))
  loop
    v_mode:=public.contentflow_completion_evidence_mode_v3(x.task_key,x.title,x.description,x.acceptance_criteria);
    if v_mode='artifact_review_only' then
      update public.contentflow_build_backlog set workflow_contract=coalesce(workflow_contract,'{}'::jsonb)||jsonb_build_object('contract_version','3','artifact_kind','reviewed_artifact','evidence_mode',v_mode,'runtime_required',false,'evidence_policy','rara_review','completion_gate','rara_approved'),updated_at=now() where id=x.id;
      update public.contentflow_builder_runs set status='completed',finished_at=coalesce(finished_at,now()),error=null where id=x.run_id and status='verification_required' and review_approved=true;
      update public.contentflow_build_backlog set status='completed',quality_score=greatest(coalesce(quality_score,0),coalesce(x.run_quality,0)),result=coalesce(result,x.run_result),completion_phase='artifact_approved',blocked_reason=null,next_eligible_at=null,updated_at=now() where id=x.id and status='verification_required';
      if found then v_artifact_completed:=v_artifact_completed+1; end if;
      continue;
    elsif v_mode='unclassified' or v_mode in ('external_approval','repo_and_runtime_test','deployment_trace') then
      v_unclassified:=v_unclassified+1;
      continue;
    end if;

    v_req_class:=case v_mode when 'repo_commit_or_file' then 'repo_artifact' when 'runtime_test' then 'runtime_test' when 'runtime_persistence' then 'runtime_evidence' when 'static_analysis' then 'static_analysis' else 'source_contract' end;
    v_fp:=md5(x.project_key||'|'||x.task_key||'|'||x.run_id::text||'|'||x.artifact_version::text||'|'||v_mode);
    v_evidence_key:='verify_'||left(regexp_replace(x.task_key,'[^a-zA-Z0-9_]+','','g'),64)||'_'||left(v_fp,10);
    select er.id into v_req_id from public.contentflow_evidence_requirements er where er.project_key=x.project_key and er.backlog_task_id=x.id and er.requirement_fingerprint=v_fp and er.status<>'obsolete' order by er.id desc limit 1;
    if v_req_id is null then
      insert into public.contentflow_evidence_requirements(project_key,backlog_task_id,source_run_id,task_key,requirement_class,requirement_fingerprint,requirement_text,evidence_task_key,status,updated_at)
      values(x.project_key,x.id,x.run_id,x.task_key,v_req_class,v_fp,'Completion evidence mode='||v_mode||'. Verify acceptance criteria with real evidence: '||left(coalesce(x.acceptance_criteria,''),5000),v_evidence_key,'task_created',now()) returning id into v_req_id;
      v_created:=v_created+1;
    end if;
    if not exists(select 1 from public.contentflow_build_backlog e where e.project_key=x.project_key and e.task_key=v_evidence_key) then
      insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,quality_score,next_eligible_at,completion_phase,execution_lane,source_run_id,workflow_contract,workflow_state)
      values(x.project_key,'evidence_first',v_evidence_key,'Verification activity: '||left(x.title,160),'Produce deterministic, persisted evidence for source task '||x.task_key||' and source run '||x.run_id||'. Evidence mode='||v_mode||'. Do not substitute prose for execution evidence.','code',x.stage,'[]'::jsonb,'evidence-first','ready',greatest(coalesce(x.priority,0),100),'Evidence must be real, correlated to source_run_id='||x.run_id||', persisted, independently checkable, and satisfy: '||left(coalesce(x.acceptance_criteria,''),4000),0,now(),'evidence_required','evidence_producer',x.run_id,jsonb_build_object('contract_version','3','artifact_kind','verification_activity','source_task_key',x.task_key,'source_builder_run_id',x.run_id,'evidence_mode',v_mode,'runtime_required',true,'evidence_policy','required','completion_gate','runtime_evidence_verified','retry_policy','typed_transient_only'),'artifact_pending');
    end if;
    update public.contentflow_build_backlog set workflow_contract=coalesce(workflow_contract,'{}'::jsonb)||jsonb_build_object('contract_version','3','evidence_mode',v_mode,'runtime_required',v_mode not in ('repo_commit_or_file','static_analysis'),'evidence_policy','required','verification_requirement_id',v_req_id,'verification_task_key',v_evidence_key,'completion_gate','verified_evidence'),workflow_state='runtime_verification_wait',completion_phase='verification_required',updated_at=now() where id=x.id;

    select e.* into v_child from public.contentflow_build_backlog e where e.project_key=x.project_key and e.task_key=v_evidence_key order by e.id desc limit 1;
    if exists(select 1 from public.contentflow_evidence_requirements er where er.id=v_req_id and er.status='verified') and v_child.status='completed' and coalesce(v_child.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb then
      if v_mode in ('repo_commit_or_file','static_analysis') then
        update public.contentflow_builder_runs set status='completed',finished_at=coalesce(finished_at,now()),error=null where id=x.run_id and status='verification_required' and review_approved=true;
        update public.contentflow_build_backlog set status='completed',completion_phase='artifact_verified',quality_score=greatest(coalesce(quality_score,0),coalesce(x.run_quality,0)),result=coalesce(result,x.run_result),runtime_evidence=coalesce(runtime_evidence,'{}'::jsonb)||jsonb_build_object('completion_verification',v_child.runtime_evidence),blocked_reason=null,next_eligible_at=null,updated_at=now() where id=x.id and status='verification_required';
        if found then v_promoted:=v_promoted+1; end if;
      else
        v_v:=public.contentflow_record_runtime_verification(x.run_id,'completion_evidence_v3_'||v_mode,true,v_child.runtime_evidence,'completion_evidence_controller_v3');
        if coalesce((v_v->>'promoted_completed')::boolean,false) then v_promoted:=v_promoted+1; end if;
      end if;
    end if;
  end loop;

  perform public.contentflow_sync_tool_execution_queue(p_project_key);
  if v_unclassified>0 and not exists(select 1 from public.director_repair_incidents where project_key=p_project_key and error_fingerprint='completion_evidence_unclassified:v3' and status in ('open','analyzing','repairing','validating','needs_help')) then
    insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status,max_attempts,requires_human,root_cause,proposed_action)
    values(p_project_key,'completion_control','completion_evidence_unclassified','completion_evidence_unclassified:v3','Reviewed artifacts require verification but their evidence modality is composite, deployment-bound, external-authority, or unclassified',jsonb_build_object('count',v_unclassified),'medium','open',3,false,'Completion contract lacks a single deterministic evidence modality','Decompose composite verification into explicit activities or register a task-specific producer');
    get diagnostics v_incidents=row_count;
  end if;
  return jsonb_build_object('architecture','COMPLETION_EVIDENCE_CONTRACT_V3','evidence_tasks_rerouted',v_rerouted,'requirements_created',v_created,'artifact_review_only_completed',v_artifact_completed,'verified_promoted',v_promoted,'unclassified_or_composite',v_unclassified,'incident_created',v_incidents);
end $$;


--
-- Name: contentflow_reconcile_durable_waits_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_durable_waits_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  x record;
  v_kind text;
  v_key text;
  v_wake timestamptz;
  v_terminal text;
  v_state text;
  v_classified int:=0;
  v_released int:=0;
  v_unclassified int:=0;
  v_incidents int:=0;
  v_terminal_classified int:=0;
  v_satisfied_dependencies int:=0;
  v_existing_incident bigint;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;

  for x in
    select b.*,
      (select min(rs.next_retry_at) from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.next_retry_at is not null) retry_at,
      (select min(rs.circuit_open_until) from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open' and rs.circuit_open_until is not null) circuit_until
    from public.contentflow_build_backlog b
    where b.project_key=p_project_key and b.status='deferred'
  loop
    v_kind:=null; v_key:=null; v_wake:=null; v_terminal:=null; v_state:='waiting';

    -- Structural terminal states are not waits and must never generate recovery incidents.
    if coalesce(x.blocked_reason,'') ilike 'OBSOLETE%'
       or coalesce(x.workflow_state,'')='obsolete'
       or coalesce(x.team,'') in ('invalid_recursive_gap','bootstrap_recursive_evidence_obsolete') then
      v_kind:='terminal';
      v_terminal:=case
        when coalesce(x.blocked_reason,'') ilike 'OBSOLETE%' then x.blocked_reason
        when coalesce(x.workflow_state,'')='obsolete' then 'OBSOLETE_WORKFLOW_STATE'
        when coalesce(x.team,'')='invalid_recursive_gap' then 'INVALID_RECURSIVE_GAP_TERMINAL'
        else 'BOOTSTRAP_RECURSIVE_EVIDENCE_OBSOLETE'
      end;
      v_key:=lower(v_terminal);
      v_state:='terminal';
      v_terminal_classified:=v_terminal_classified+1;

    elsif x.next_eligible_at is not null and x.next_eligible_at>now() then
      v_kind:=case when x.retry_at is not null or x.circuit_until is not null then 'retry' else 'timer' end;
      v_wake:=greatest(x.next_eligible_at,coalesce(x.retry_at,x.next_eligible_at),coalesce(x.circuit_until,x.next_eligible_at));
      v_key:=coalesce(x.blocked_reason,'scheduled_wakeup');

    -- A deferred task whose declared dependencies are all completed is releasable now.
    elsif jsonb_array_length(coalesce(x.depends_on,'[]'::jsonb))>0
      and not exists(
        select 1
        from jsonb_array_elements_text(coalesce(x.depends_on,'[]'::jsonb)) d(dep)
        where not exists(
          select 1 from public.contentflow_build_backlog z
          where z.project_key=x.project_key and z.task_key=d.dep and z.status='completed'
        )
      ) then
      v_kind:='dependency';
      v_key:='all_dependencies_satisfied';
      v_state:='released';
      v_satisfied_dependencies:=v_satisfied_dependencies+1;

    elsif exists(
      select 1 from jsonb_array_elements_text(coalesce(x.depends_on,'[]'::jsonb)) d(dep)
      where not exists(
        select 1 from public.contentflow_build_backlog z
        where z.project_key=x.project_key and z.task_key=d.dep and z.status='completed'
      )
    ) then
      v_kind:='dependency';
      select d.dep into v_key
      from jsonb_array_elements_text(coalesce(x.depends_on,'[]'::jsonb)) d(dep)
      where not exists(
        select 1 from public.contentflow_build_backlog z
        where z.project_key=x.project_key and z.task_key=d.dep and z.status='completed'
      )
      order by d.dep limit 1;

    elsif x.retry_at is not null or x.circuit_until is not null then
      v_kind:='retry';
      v_wake:=greatest(coalesce(x.retry_at,'-infinity'::timestamptz),coalesce(x.circuit_until,'-infinity'::timestamptz));
      v_key:='retry_policy';

    elsif coalesce(x.execution_lane,'llm_artifact') in ('tool_executor','evidence_producer')
      and not public.contentflow_tool_execution_capability_ready(x.project_key,x.task_key) then
      v_kind:='capability';
      v_key:=coalesce(x.execution_lane,'evidence_producer');

    elsif exists(
      select 1 from public.contentflow_review_work_queue q
      join public.contentflow_builder_runs r on r.id=q.builder_run_id
      where r.backlog_task_id=x.id and q.state in ('pending','claimed')
    ) then
      v_kind:='review';
      v_key:='rara_review';

    else
      v_kind:='unclassified';
      v_state:='unclassified';
      v_key:='missing_causal_wakeup';
      v_unclassified:=v_unclassified+1;
    end if;

    insert into public.contentflow_wait_registry(
      backlog_task_id,project_key,task_key,wait_kind,wait_key,wake_at,terminal_reason,state,
      evidence,released_at,updated_at
    ) values(
      x.id,x.project_key,x.task_key,v_kind,v_key,v_wake,v_terminal,v_state,
      jsonb_build_object(
        'status',x.status,'workflow_state',x.workflow_state,'blocked_reason',x.blocked_reason,
        'team',x.team,'classified_from','durable_wait_signal_contract_v2'
      ),
      case when v_state='released' then now() else null end,
      now()
    )
    on conflict(backlog_task_id) do update set
      wait_kind=excluded.wait_kind,
      wait_key=excluded.wait_key,
      wake_at=excluded.wake_at,
      terminal_reason=excluded.terminal_reason,
      generation=case
        when public.contentflow_wait_registry.wait_kind is distinct from excluded.wait_kind
          or public.contentflow_wait_registry.wait_key is distinct from excluded.wait_key
          or public.contentflow_wait_registry.wake_at is distinct from excluded.wake_at
        then public.contentflow_wait_registry.generation+1
        else public.contentflow_wait_registry.generation
      end,
      state=excluded.state,
      classified_at=case
        when public.contentflow_wait_registry.wait_kind is distinct from excluded.wait_kind then now()
        else public.contentflow_wait_registry.classified_at
      end,
      released_at=excluded.released_at,
      evidence=public.contentflow_wait_registry.evidence||excluded.evidence,
      updated_at=now();
    v_classified:=v_classified+1;
  end loop;

  update public.contentflow_wait_registry w
  set state='released',released_at=now(),updated_at=now()
  where w.project_key=p_project_key and w.state='waiting' and exists(
    select 1 from public.contentflow_build_backlog b
    where b.id=w.backlog_task_id and b.status='deferred' and (
      (w.wait_kind in ('timer','retry') and w.wake_at is not null and w.wake_at<=now()
       and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open' and coalesce(rs.circuit_open_until,now()+interval '1 day')>now()))
      or (w.wait_kind='dependency' and not exists(
        select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep)
        where not exists(select 1 from public.contentflow_build_backlog z where z.project_key=b.project_key and z.task_key=d.dep and z.status='completed')
      ))
      or (w.wait_kind='capability' and public.contentflow_tool_execution_capability_ready(b.project_key,b.task_key))
      or (w.wait_kind='external_signal' and exists(select 1 from public.contentflow_durable_signal_ledger s where s.project_key=b.project_key and s.task_key=b.task_key and s.signal_key=w.wait_key))
    )
  );
  get diagnostics v_released=row_count;

  update public.contentflow_build_backlog b
  set status='ready',blocked_reason=null,next_eligible_at=now(),updated_at=now()
  where b.project_key=p_project_key and b.status='deferred'
    and exists(
      select 1 from public.contentflow_wait_registry w
      where w.backlog_task_id=b.id and w.state='released' and w.released_at>=now()-interval '2 minutes'
    );

  -- Keep one canonical incident row. Never create one incident per control-loop cycle.
  select id into v_existing_incident
  from public.director_repair_incidents
  where project_key=p_project_key and error_fingerprint='durable_wait_unclassified:v2'
  order by id desc limit 1;

  if v_unclassified>0 then
    if v_existing_incident is null then
      insert into public.director_repair_incidents(
        project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status,
        max_attempts,requires_human,root_cause,proposed_action
      ) values(
        p_project_key,'director_control','durable_wait_unclassified','durable_wait_unclassified:v2',
        'Deferred work remains without a durable exit contract after terminal/dependency normalization',
        jsonb_build_object('unclassified',v_unclassified,'architecture','DURABLE_WAIT_SIGNAL_CONTRACT_V2'),
        'medium','open',3,false,
        'Planner emitted deferred work without timer, unresolved dependency, retry, capability, review, external signal, or structural terminal marker',
        'Classify the originating planner contract; do not redispatch blindly'
      );
      v_incidents:=1;
    else
      update public.director_repair_incidents
      set evidence=jsonb_build_object('unclassified',v_unclassified,'architecture','DURABLE_WAIT_SIGNAL_CONTRACT_V2'),
          symptom='Deferred work remains without a durable exit contract after terminal/dependency normalization',
          updated_at=now(),
          requires_human=false
      where id=v_existing_incident;
    end if;
  elsif v_existing_incident is not null then
    update public.director_repair_incidents
    set status='resolved',resolved_at=coalesce(resolved_at,now()),updated_at=now(),requires_human=false,
        outcome='all_deferred_work_has_durable_exit_contract'
    where id=v_existing_incident and status<>'resolved';
  end if;

  update public.contentflow_wait_registry w
  set state='released',released_at=coalesce(released_at,now()),updated_at=now()
  where w.project_key=p_project_key and w.state in ('waiting','unclassified')
    and exists(select 1 from public.contentflow_build_backlog b where b.id=w.backlog_task_id and b.status<>'deferred');

  return jsonb_build_object(
    'architecture','DURABLE_WAIT_SIGNAL_CONTRACT_V2',
    'classified',v_classified,
    'terminal_classified',v_terminal_classified,
    'satisfied_dependency_releases',v_satisfied_dependencies,
    'released',v_released,
    'unclassified',v_unclassified,
    'incident_created',v_incidents,
    'waiting',(select count(*) from public.contentflow_wait_registry where project_key=p_project_key and state='waiting'),
    'terminal',(select count(*) from public.contentflow_wait_registry where project_key=p_project_key and state='terminal')
  );
end
$$;


--
-- Name: contentflow_reconcile_evidence_capability_queue(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_evidence_capability_queue(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare held int:=0; released int:=0;
begin
 if coalesce(auth.role(),'') <> 'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;
 update public.contentflow_tool_execution_queue q
 set state='blocked',claim_token=null,claimed_at=null,updated_at=now(),last_error='CAPABILITY_WAIT:'||coalesce(m.prerequisite,'unknown')
 from public.contentflow_build_backlog b
 left join public.contentflow_evidence_requirements er on er.project_key=b.project_key and er.evidence_task_key=b.task_key and er.status<>'obsolete'
 left join public.contentflow_evidence_capability_matrix m on m.requirement_id=er.id
 where q.project_key=p_project_key and q.backlog_task_id=b.id and q.state='pending'
   and (b.epic='evidence_first' or b.completion_phase='evidence_required')
   and not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key);
 get diagnostics held=row_count;
 update public.contentflow_tool_execution_queue q
 set state='pending',last_error=null,claim_token=null,claimed_at=null,updated_at=now()
 from public.contentflow_build_backlog b
 where q.project_key=p_project_key and q.backlog_task_id=b.id and q.state='blocked'
   and q.last_error like 'CAPABILITY_WAIT:%'
   and public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key);
 get diagnostics released=row_count;
 return jsonb_build_object('architecture','EVIDENCE_CAPABILITY_ADMISSION_V2','held',held,'released',released,'pending',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='pending'),'capability_wait',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='blocked' and last_error like 'CAPABILITY_WAIT:%'));
end $$;


--
-- Name: contentflow_reconcile_external_executor_waits_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_external_executor_waits_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_blocked int:=0; v_released int:=0;
begin
  update public.contentflow_build_backlog b
     set status='blocked',blocked_reason='EXECUTOR_ENDPOINT_REQUIRED',next_eligible_at=null,updated_at=now()
   where b.project_key=p_project_key
     and b.execution_lane='tool_executor'
     and coalesce((b.workflow_contract->>'runtime_required')::boolean,false)=true
     and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')<>''
     and not public.contentflow_external_executor_ready(b.project_key,b.workflow_contract->'execution_recipe'->>'executor_key')
     and b.status in ('ready','planned');
  get diagnostics v_blocked=row_count;

  update public.contentflow_build_backlog b
     set status='ready',blocked_reason=null,next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key
     and b.execution_lane='tool_executor'
     and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')<>''
     and public.contentflow_external_executor_ready(b.project_key,b.workflow_contract->'execution_recipe'->>'executor_key')
     and b.status='blocked' and b.blocked_reason='EXECUTOR_ENDPOINT_REQUIRED';
  get diagnostics v_released=row_count;

  perform public.contentflow_sync_tool_execution_queue(p_project_key);
  return jsonb_build_object('architecture','EXTERNAL_EXECUTOR_DURABLE_WAIT_V1','blocked_missing_executor',v_blocked,'released_executor_ready',v_released);
end;
$$;


--
-- Name: contentflow_reconcile_ready_after_evidence(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_ready_after_evidence(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_ready int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then raise exception 'privileged_channel_required'; end if;
  update public.contentflow_build_backlog b
     set status='ready',next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key and b.status='blocked' and b.completion_phase='evidence_verified'
     and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required','verification_required') and r.finished_at is null)
     and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
                    where not exists(select 1 from public.contentflow_build_backlog dep where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'));
  get diagnostics v_ready=row_count;
  return jsonb_build_object('architecture','READY_AFTER_EVIDENCE_V1','reopened',v_ready);
end
$$;


--
-- Name: contentflow_reconcile_retry_policies(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_retry_policies(p_project_key text DEFAULT 'contentflow'::text, p_limit integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare x record; n int:=0; scheduled int:=0; blocked int:=0; a jsonb; cleaned int:=0; stale_runtime_closed int:=0;
begin
  with obsolete as (
    select s.backlog_task_id
    from public.contentflow_retry_state s
    join public.contentflow_build_backlog b on b.id=s.backlog_task_id
    left join public.contentflow_builder_runs lr on lr.id=s.last_run_id
    where s.project_key=p_project_key
      and (
        b.status='completed'
        or coalesce(b.workflow_state,'')='superseded'
        or coalesce(b.blocked_reason,'') like 'SUPERSEDED_BY_%'
        or lr.id is null
        or lr.status not in ('failed','deferred')
        or exists(select 1 from public.contentflow_builder_runs newer where newer.backlog_task_id=s.backlog_task_id and newer.id>s.last_run_id)
        or (
          coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
          and b.status in ('ready','planned')
          and lr.finished_at is not null
          and b.updated_at>lr.finished_at
        )
      )
  )
  delete from public.contentflow_retry_state s using obsolete o where s.backlog_task_id=o.backlog_task_id;
  get diagnostics cleaned=row_count;

  update public.contentflow_build_backlog
     set status='deferred', next_eligible_at=null, updated_at=now()
   where project_key=p_project_key
     and (coalesce(workflow_state,'')='superseded' or coalesce(blocked_reason,'') like 'SUPERSEDED_BY_%')
     and status<>'deferred';

  /* A failed LLM task may open a circuit because required runtime evidence did not yet exist.
     Once dependencies are complete and newer verified runtime evidence has arrived, that
     circuit is stale and must not permanently suppress an otherwise dispatchable task. */
  update public.contentflow_retry_state s
     set circuit_state='closed', circuit_open_until=null, next_retry_at=now(), updated_at=now()
    from public.contentflow_build_backlog b,
         public.contentflow_builder_runs lr
   where s.project_key=p_project_key
     and s.backlog_task_id=b.id
     and lr.id=s.last_run_id
     and s.circuit_state='open'
     and b.status in ('ready','planned')
     and lr.status in ('failed','deferred')
     and lr.finished_at is not null
     and b.updated_at>lr.finished_at
     and coalesce(s.last_error,'') ilike 'Missing verified runtime evidence%'
     and not exists (
       select 1
       from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists (
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     )
     and exists (
       select 1
       from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       join public.contentflow_build_backlog d
         on d.project_key=b.project_key and d.task_key=dep.value
       where d.status='completed' and d.runtime_verified=true and d.updated_at>lr.finished_at
     );
  get diagnostics stale_runtime_closed=row_count;

  for x in
    select r.id
    from public.contentflow_builder_runs r
    join public.contentflow_build_backlog b on b.id=r.backlog_task_id
    left join public.contentflow_retry_state s on s.backlog_task_id=b.id
    where r.project_key=p_project_key
      and b.status<>'completed'
      and coalesce(b.workflow_state,'')<>'superseded'
      and coalesce(b.blocked_reason,'') not like 'SUPERSEDED_BY_%'
      and r.status in ('failed','deferred') and r.finished_at is not null
      and s.last_run_id is distinct from r.id
      and r.id=(select max(z.id) from public.contentflow_builder_runs z where z.backlog_task_id=r.backlog_task_id and z.finished_at is not null)
      and not exists(
        select 1 from public.contentflow_builder_runs active
        where active.backlog_task_id=b.id and active.status in ('claimed','running','review_required','verification_required') and active.finished_at is null
      )
      and not (
        coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
        and b.status in ('ready','planned')
        and b.updated_at>r.finished_at
      )
    order by r.id asc limit greatest(1,least(coalesce(p_limit,100),500))
  loop
    a:=public.contentflow_apply_retry_policy(x.id); n:=n+1;
    if a->>'action'='retry_scheduled' then scheduled:=scheduled+1; elsif a->>'action'='blocked_for_repair' then blocked:=blocked+1; end if;
  end loop;
  update public.contentflow_retry_state set circuit_state='closed',circuit_open_until=null where project_key=p_project_key and circuit_state='cooldown' and next_retry_at<=now();
  return jsonb_build_object('examined',n,'scheduled',scheduled,'blocked',blocked,'obsolete_cleaned',cleaned,'stale_runtime_evidence_circuits_closed',stale_runtime_closed,'superseded_guard',true,'active_run_protected',true,'bootstrap_repair_protected',true);
end
$$;


--
-- Name: contentflow_reconcile_runtime_state(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_reconcile_runtime_state(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_review_fixed int:=0;
  v_verify_fixed int:=0;
  v_workers_synced int:=0;
  v_workers_released int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;

  -- Canonical backlog state follows any active post-execution gate.
  update public.contentflow_build_backlog b
     set status='blocked',selected_model=null,updated_at=now()
   where b.project_key=p_project_key and b.status<>'completed'
     and exists(
       select 1 from public.contentflow_builder_runs r
       where r.backlog_task_id=b.id and r.status='review_required' and r.finished_at is null
     )
     and b.status<>'blocked';
  get diagnostics v_review_fixed=row_count;

  update public.contentflow_build_backlog b
     set status='verification_required',selected_model=null,completion_phase='verification_required',updated_at=now()
   where b.project_key=p_project_key and b.status<>'completed'
     and exists(
       select 1 from public.contentflow_builder_runs r
       where r.backlog_task_id=b.id and r.status='verification_required' and r.finished_at is null
     )
     and b.status<>'verification_required';
  get diagnostics v_verify_fixed=row_count;

  -- Compute-running runs own workers.
  update public.director_worker_queue q
     set status='running',current_task_key=r.task_key,updated_at=now()
    from public.contentflow_builder_runs r
   where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null
     and r.selected_model=q.model_id
     and (q.status is distinct from 'running' or q.current_task_key is distinct from r.task_key);
  get diagnostics v_workers_synced=row_count;

  -- Review/verification does not consume a production worker.
  update public.director_worker_queue q
     set status='ready',current_task_key=null,updated_at=now()
   where q.status='running'
     and not exists(
       select 1 from public.contentflow_builder_runs r
       where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null
         and r.selected_model=q.model_id and r.task_key=q.current_task_key
     );
  get diagnostics v_workers_released=row_count;

  return jsonb_build_object('architecture','CANONICAL_RUNTIME_STATE_V2','review_backlogs_fixed',v_review_fixed,'verification_backlogs_fixed',v_verify_fixed,'workers_synced_running',v_workers_synced,'workers_released',v_workers_released);
end
$$;


--
-- Name: contentflow_record_ci_requirement_evidence(bigint, bigint, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_record_ci_requirement_evidence(p_requirement_id bigint, p_builder_run_id bigint, p_task_key text, p_test_profile text, p_commit_sha text, p_workflow_run_id text, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare er public.contentflow_evidence_requirements%rowtype; v_hash text; v_id bigint; v_key text; v_type text;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then raise exception 'privileged_ci_channel_required'; end if;
  if p_payload is null or p_payload='{}'::jsonb or coalesce((p_payload->>'passed')::boolean,false) is not true then raise exception 'passing_nonempty_payload_required'; end if;
  if coalesce(trim(p_test_profile),'')='' or coalesce(trim(p_commit_sha),'')='' or coalesce(trim(p_workflow_run_id),'')='' then raise exception 'ci_identity_required'; end if;
  select * into er from public.contentflow_evidence_requirements where id=p_requirement_id for update;
  if not found then raise exception 'requirement_not_found'; end if;
  if er.project_key<>'contentflow' then raise exception 'wrong_project'; end if;
  if er.source_run_id is distinct from p_builder_run_id or er.task_key is distinct from p_task_key then raise exception 'requirement_correlation_mismatch'; end if;
  if er.status='verified' then return jsonb_build_object('ok',true,'already_verified',true,'requirement_id',er.id); end if;
  if p_test_profile not in ('evidence-persistence','runtime-test','static-analysis','source-contract') then raise exception 'unsupported_test_profile'; end if;
  v_type:=case when p_test_profile='static-analysis' then 'static_analysis' when p_test_profile='source-contract' then 'source_contract' else 'runtime_test' end;
  v_key:='ci:'||p_test_profile||':requirement:'||er.id::text||':run:'||p_workflow_run_id;
  v_hash:=encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'::text),'hex');
  insert into public.contentflow_runtime_evidence_ledger(project_key,backlog_task_id,builder_run_id,task_key,evidence_type,evidence_key,payload,payload_sha256,producer,observed_at,requirement_id)
  values(er.project_key,er.backlog_task_id,er.source_run_id,er.task_key,v_type,
    v_key,
    p_payload||jsonb_build_object('requirement_id',er.id,'test_profile',p_test_profile,'commit_sha',p_commit_sha,'workflow_run_id',p_workflow_run_id,'source_run_id',er.source_run_id,'source_task_key',er.task_key),
    v_hash,'github-actions-ci',now(),er.id)
  on conflict(project_key,builder_run_id,evidence_key,payload_sha256) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from public.contentflow_runtime_evidence_ledger where project_key=er.project_key and builder_run_id=er.source_run_id and evidence_key=v_key order by id desc limit 1; end if;
  return jsonb_build_object('ok',true,'evidence_id',v_id,'requirement_id',er.id,'sha256',v_hash);
end $$;


--
-- Name: contentflow_record_durable_signal_v1(text, text, text, text, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_record_durable_signal_v1(p_project_key text, p_task_key text, p_signal_key text, p_signal_id text, p_payload jsonb DEFAULT '{}'::jsonb, p_producer text DEFAULT 'control_plane'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_id bigint; v_inserted boolean:=false;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;
  insert into public.contentflow_durable_signal_ledger(project_key,task_key,signal_key,signal_id,payload,producer)
  values(p_project_key,p_task_key,p_signal_key,p_signal_id,coalesce(p_payload,'{}'::jsonb),coalesce(nullif(p_producer,''),'control_plane'))
  on conflict(project_key,task_key,signal_key,signal_id) do nothing returning id into v_id;
  v_inserted:=v_id is not null;
  if v_id is null then select id into v_id from public.contentflow_durable_signal_ledger where project_key=p_project_key and task_key=p_task_key and signal_key=p_signal_key and signal_id=p_signal_id; end if;
  return jsonb_build_object('ok',true,'signal_id',v_id,'inserted',v_inserted,'deduplicated',not v_inserted);
end $$;


--
-- Name: contentflow_record_runtime_event(bigint, text, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_record_runtime_event(p_run_id bigint, p_event_type text, p_payload jsonb DEFAULT '{}'::jsonb, p_actor text DEFAULT 'runtime'::text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare r public.contentflow_builder_runs%rowtype; v_id bigint; begin if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if; select * into r from public.contentflow_builder_runs where id=p_run_id; if not found then raise exception 'run_not_found'; end if; insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload) values(p_run_id,r.task_key,p_event_type,r.idempotency_key,p_actor,coalesce(p_payload,'{}'::jsonb)) on conflict(idempotency_key,event_type) where idempotency_key is not null do update set payload=excluded.payload,actor=excluded.actor,created_at=now() returning id into v_id; return v_id; end $$;


--
-- Name: contentflow_record_runtime_evidence(bigint, text, text, jsonb, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_record_runtime_evidence(p_builder_run_id bigint, p_evidence_type text, p_evidence_key text, p_payload jsonb, p_producer text, p_observed_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r public.contentflow_builder_runs%rowtype;
  b public.contentflow_build_backlog%rowtype;
  v_hash text;
  v_id bigint;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  if p_builder_run_id is null then raise exception 'builder_run_required'; end if;
  if coalesce(trim(p_evidence_type),'')='' then raise exception 'evidence_type_required'; end if;
  if coalesce(trim(p_evidence_key),'')='' then raise exception 'evidence_key_required'; end if;
  if coalesce(trim(p_producer),'')='' then raise exception 'producer_required'; end if;
  if p_payload is null or p_payload='{}'::jsonb or p_payload='[]'::jsonb then raise exception 'nonempty_payload_required'; end if;

  select * into r from public.contentflow_builder_runs where id=p_builder_run_id;
  if not found then raise exception 'builder_run_not_found'; end if;
  select * into b from public.contentflow_build_backlog where id=r.backlog_task_id;
  if not found then raise exception 'backlog_task_not_found'; end if;
  if b.project_key is distinct from r.project_key or b.task_key is distinct from r.task_key then raise exception 'run_task_correlation_mismatch'; end if;

  v_hash:=encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'::text),'hex');
  insert into public.contentflow_runtime_evidence_ledger(project_key,backlog_task_id,builder_run_id,task_key,evidence_type,evidence_key,payload,payload_sha256,producer,observed_at)
  values(b.project_key,b.id,r.id,b.task_key,trim(p_evidence_type),trim(p_evidence_key),p_payload,v_hash,trim(p_producer),coalesce(p_observed_at,now()))
  on conflict(project_key,builder_run_id,evidence_key,payload_sha256) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.contentflow_runtime_evidence_ledger
    where project_key=b.project_key and builder_run_id=r.id and evidence_key=trim(p_evidence_key) and payload_sha256=v_hash;
  end if;

  insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
  values(r.id,b.task_key,'evidence_recorded',coalesce(r.idempotency_key,'run:'||r.id::text),trim(p_producer),jsonb_build_object('evidence_id',v_id,'evidence_type',trim(p_evidence_type),'evidence_key',trim(p_evidence_key),'sha256',v_hash,'observed_at',coalesce(p_observed_at,now())))
  on conflict do nothing;

  return jsonb_build_object('ok',true,'evidence_id',v_id,'task_key',b.task_key,'builder_run_id',r.id,'sha256',v_hash);
end $$;


--
-- Name: contentflow_record_runtime_requirement_evidence(bigint, bigint, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_record_runtime_requirement_evidence(p_requirement_id bigint, p_builder_run_id bigint, p_task_key text, p_commit_sha text, p_execution_id text, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare er public.contentflow_evidence_requirements%rowtype; v_hash text; v_id bigint; v_key text;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then raise exception 'privileged_runtime_channel_required'; end if;
  if p_payload is null or p_payload='{}'::jsonb or coalesce((p_payload->>'passed')::boolean,false) is not true then raise exception 'passing_nonempty_payload_required'; end if;
  if coalesce(trim(p_commit_sha),'')='' or coalesce(trim(p_execution_id),'')='' then raise exception 'runtime_identity_required'; end if;
  select * into er from public.contentflow_evidence_requirements where id=p_requirement_id for update;
  if not found then raise exception 'requirement_not_found'; end if;
  if er.project_key<>'contentflow' then raise exception 'wrong_project'; end if;
  if er.source_run_id is distinct from p_builder_run_id or er.task_key is distinct from p_task_key then raise exception 'requirement_correlation_mismatch'; end if;
  if er.status='verified' then return jsonb_build_object('ok',true,'already_verified',true,'requirement_id',er.id); end if;
  v_key:='runtime:requirement:'||er.id::text||':execution:'||p_execution_id;
  v_hash:=encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'::text),'hex');
  insert into public.contentflow_runtime_evidence_ledger(project_key,backlog_task_id,builder_run_id,task_key,evidence_type,evidence_key,payload,payload_sha256,producer,observed_at,requirement_id)
  values(er.project_key,er.backlog_task_id,er.source_run_id,er.task_key,'runtime_test',v_key,
    p_payload||jsonb_build_object('requirement_id',er.id,'commit_sha',p_commit_sha,'execution_id',p_execution_id,'source_run_id',er.source_run_id,'source_task_key',er.task_key),
    v_hash,'supabase-edge-runtime',now(),er.id)
  on conflict(project_key,builder_run_id,evidence_key,payload_sha256) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from public.contentflow_runtime_evidence_ledger where project_key=er.project_key and builder_run_id=er.source_run_id and evidence_key=v_key order by id desc limit 1; end if;
  return jsonb_build_object('ok',true,'evidence_id',v_id,'requirement_id',er.id,'sha256',v_hash);
end $$;


--
-- Name: contentflow_record_runtime_verification(bigint, text, boolean, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_record_runtime_verification(p_builder_run_id bigint, p_verification_type text, p_passed boolean, p_evidence jsonb DEFAULT '{}'::jsonb, p_verifier text DEFAULT 'runtime_verifier'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r public.contentflow_builder_runs%rowtype;
  b public.contentflow_build_backlog%rowtype;
  promoted boolean:=false;
  v_record jsonb:=null;
  v_evidence_key text;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  select * into r from public.contentflow_builder_runs where id=p_builder_run_id for update;
  if not found then raise exception 'builder_run_not_found'; end if;
  select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update;
  if not found then raise exception 'backlog_task_not_found'; end if;

  if p_passed and (p_evidence is null or p_evidence='{}'::jsonb or p_evidence='[]'::jsonb) then
    raise exception 'verified_pass_requires_nonempty_evidence';
  end if;

  if p_evidence is not null and p_evidence<>'{}'::jsonb and p_evidence<>'[]'::jsonb then
    v_evidence_key:='verification:'||coalesce(nullif(trim(p_verification_type),''),'runtime_check')||':run:'||r.id::text;
    v_record:=public.contentflow_record_runtime_evidence(
      r.id,
      case when p_passed then 'runtime_verification_pass' else 'runtime_verification_fail' end,
      v_evidence_key,
      p_evidence,
      coalesce(nullif(trim(p_verifier),''),'runtime_verifier'),
      now()
    );
  end if;

  insert into public.contentflow_runtime_verifications(project_key,backlog_task_id,builder_run_id,task_key,verification_type,passed,evidence,verifier)
  values(b.project_key,b.id,r.id,b.task_key,coalesce(nullif(p_verification_type,''),'runtime_check'),p_passed,coalesce(p_evidence,'{}'::jsonb),coalesce(nullif(p_verifier,''),'runtime_verifier'));

  if p_passed then
    update public.contentflow_build_backlog
      set runtime_verified=true,runtime_verified_at=now(),runtime_evidence=coalesce(p_evidence,'{}'::jsonb),completion_phase='runtime_proven',updated_at=now()
      where id=b.id;
    if coalesce(r.quality_score,0)>=85 and coalesce(r.review_approved,false)=true and r.result is not null and length(trim(r.result))>=40 then
      update public.contentflow_builder_runs set status='completed',finished_at=coalesce(finished_at,now()),error=null where id=r.id and status='verification_required';
      update public.contentflow_build_backlog set status='completed',quality_score=greatest(coalesce(quality_score,0),coalesce(r.quality_score,0)),result=coalesce(result,r.result),completion_phase='runtime_proven',updated_at=now() where id=b.id;
      promoted:=true;
    end if;
  else
    update public.contentflow_build_backlog set runtime_verified=false,runtime_verified_at=null,runtime_evidence=coalesce(p_evidence,'{}'::jsonb),completion_phase='verification_required',status=case when status='completed' then 'verification_required' else status end,updated_at=now() where id=b.id;
    update public.contentflow_builder_runs set status=case when status='completed' then 'verification_required' else status end,finished_at=case when status='completed' then null else finished_at end,error=case when status='completed' then 'RUNTIME_VERIFICATION_FAILED' else error end where id=r.id;
  end if;

  insert into public.director_autonomy_events(project_key,event_type,task_key,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(b.project_key,'runtime_verification_recorded',b.task_key,'runtime_verifier','completion_boundary',case when p_passed then case when promoted then 'pass_promoted_completed' else 'pass_waiting_review' end else 'fail' end,false,jsonb_build_object('run',r.id,'type',coalesce(p_verification_type,'runtime_check'),'verifier',coalesce(p_verifier,'runtime_verifier'),'canonical_evidence',v_record)::text,now());

  return jsonb_build_object('ok',true,'task_key',b.task_key,'passed',p_passed,'review_approved',coalesce(r.review_approved,false),'promoted_completed',promoted,'completion_phase',case when p_passed then 'runtime_proven' else 'verification_required' end,'canonical_evidence',v_record);
end $$;


--
-- Name: contentflow_recover_expired_leases(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_recover_expired_leases(p_project_key text DEFAULT 'contentflow'::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ begin return 0; end $$;


--
-- Name: contentflow_recover_orphan_claims(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_recover_orphan_claims(p_project_key text DEFAULT 'contentflow'::text, p_grace_seconds integer DEFAULT 45) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ begin return public.contentflow_recover_stalled_activities(p_project_key); end $$;


--
-- Name: contentflow_recover_stalled_activities(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_recover_stalled_activities(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_now timestamptz:=now(); v_count int:=0; v_workers int:=0; v_slots int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 if not pg_try_advisory_xact_lock(hashtext('contentflow:activity-recovery:'||p_project_key)) then
   return jsonb_build_object('recovered_runs',0,'skipped','recovery_lock_busy','ownership_model','durable_execution_v3');
 end if;
 with stalled as (
   select r.id,r.backlog_task_id,r.task_key,r.selected_model,r.idempotency_key,r.activity_phase,
          case when r.activity_deadline_at is not null and r.activity_deadline_at<=v_now then 'activity_timeout'
               when r.activity_deadline_at is null and r.heartbeat_deadline_at is not null and r.heartbeat_deadline_at<=v_now then 'heartbeat_timeout'
               else null end as cause
   from public.contentflow_builder_runs r
   where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null and r.lease_revoked_at is null
     and ((r.activity_deadline_at is not null and r.activity_deadline_at<=v_now)
       or (r.activity_deadline_at is null and r.heartbeat_deadline_at is not null and r.heartbeat_deadline_at<=v_now))
   order by r.id
   for update skip locked
 ), revoked as (
   update public.contentflow_builder_runs r set status='deferred',finished_at=v_now,error=upper(s.cause)||':'||coalesce(s.activity_phase,'unknown'),lease_revoked_at=v_now,lease_generation=lease_generation+1
   from stalled s where r.id=s.id returning s.*
 ), backlog as (
   update public.contentflow_build_backlog b set status='ready',selected_model=null,next_eligible_at=v_now,updated_at=v_now
   from revoked s where b.id=s.backlog_task_id and b.status='running' returning s.*
 ) select count(*) into v_count from backlog;
 update public.director_worker_queue q set status='ready',current_task_key=null,last_outcome='durable_activity_recovered_v3',updated_at=v_now
 where q.status='running' and exists(select 1 from public.contentflow_builder_runs r where r.selected_model=q.model_id and r.finished_at=v_now and (r.error like 'ACTIVITY_TIMEOUT:%' or r.error like 'HEARTBEAT_TIMEOUT:%'));
 get diagnostics v_workers=row_count;
 update public.contentflow_nexo_slots s set released_at=coalesce(s.released_at,v_now),release_reason=coalesce(s.release_reason,'durable_activity_recovered_v3')
 where s.released_at is null and exists(select 1 from public.contentflow_builder_runs r where r.task_key=s.task_key and r.finished_at=v_now and (r.error like 'ACTIVITY_TIMEOUT:%' or r.error like 'HEARTBEAT_TIMEOUT:%'));
 get diagnostics v_slots=row_count;
 return jsonb_build_object('recovered_runs',v_count,'workers_released',v_workers,'slots_released',v_slots,'ownership_model','durable_execution_v3');
end $$;


--
-- Name: contentflow_recovery_watchdog_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_recovery_watchdog_v1() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$
declare rec record; recovered int:=0; owner_wait int:=0; action jsonb; req bigint; pgnet jsonb;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
 pgnet:=public.contentflow_pg_net_stall_reconcile_v1();
 for rec in
   select b.id backlog_id,b.project_key,b.task_key,b.updated_at,rs.last_run_id,r.error,r.finished_at,
          public.contentflow_classify_run_error(r.error) err_class,
          public.rara_classify_rejection(r.error) rara_class
   from public.contentflow_build_backlog b
   join public.contentflow_retry_state rs on rs.backlog_task_id=b.id
   left join public.contentflow_builder_runs r on r.id=rs.last_run_id
   where b.status='blocked' and b.blocked_reason='CIRCUIT_OPEN' and rs.circuit_state='open'
     and coalesce(r.finished_at,b.updated_at) <= now()-interval '7 minutes'
     and not exists(select 1 from public.contentflow_builder_runs ar where ar.backlog_task_id=b.id and ar.status in ('claimed','running','review_required','verification_required') and ar.finished_at is null)
 loop
   if rec.rara_class='owner_required' then
     owner_wait:=owner_wait+1;
     update public.director_repair_incidents set requires_human=true,updated_at=now() where project_key=rec.project_key and status in ('open','analyzing','needs_help') and coalesce(requires_human,false)=false;
   elsif coalesce(rec.error,'') ilike '%RARA_REVIEW_REJECTED%' then
     action:=public.rara_learn_and_replan_rejection(rec.last_run_id,rec.error);
     if coalesce((action->>'ok')::boolean,false) then recovered:=recovered+1; end if;
   elsif rec.err_class in ('capacity','judge','provider','timeout','state_recovery') then
     update public.contentflow_retry_state set circuit_state='closed',attempt_count=0,next_retry_at=now(),circuit_open_until=null,updated_at=now() where backlog_task_id=rec.backlog_id;
     update public.contentflow_build_backlog set status='ready',blocked_reason=null,next_eligible_at=now(),selected_model=null,updated_at=now() where id=rec.backlog_id;
     recovered:=recovered+1;
   else
     update public.contentflow_retry_state set circuit_state='closed',attempt_count=0,next_retry_at=now(),circuit_open_until=null,updated_at=now() where backlog_task_id=rec.backlog_id;
     update public.contentflow_build_backlog set status='ready',blocked_reason=null,next_eligible_at=now(),selected_model=null,description=coalesce(description,'')||E'\n\n[AUTO-WATCHDOG] Previous recoverable failure stalled >=7m. Re-evaluate root cause before resubmission; do not repeat prior rejected structure.',updated_at=now() where id=rec.backlog_id;
     recovered:=recovered+1;
   end if;
 end loop;
 if recovered>0 then
   select net.http_post(url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-auto-loop',headers:='{"Content-Type":"application/json"}'::jsonb,body:='{}'::jsonb,timeout_milliseconds:=30000) into req;
 end if;
 return jsonb_build_object('architecture','AUTONOMOUS_RECOVERY_WATCHDOG_V2_PGNET_SECURE','pg_net',pgnet,'recovered',recovered,'owner_wait',owner_wait,'wake_request_id',req);
end $$;


--
-- Name: contentflow_register_persistent_change_intent_v1(text, text, bigint, text, text, text, bigint, text, text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_register_persistent_change_intent_v1(p_project_key text, p_change_class text, p_incident_id bigint DEFAULT NULL::bigint, p_repair_recipe text DEFAULT NULL::text, p_migration_name text DEFAULT NULL::text, p_git_commit_sha text DEFAULT NULL::text, p_git_pr_number bigint DEFAULT NULL::bigint, p_causal_state_version text DEFAULT NULL::text, p_evidence_id text DEFAULT NULL::text, p_evidence jsonb DEFAULT '{}'::jsonb, p_break_glass boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_id uuid; v_status text;
begin
 if p_change_class not in ('schema','function','policy','trigger','extension','persistent_control','other') then raise exception 'unsupported_persistent_change_class:%',p_change_class; end if;
 if p_git_commit_sha is not null and p_git_commit_sha !~ '^[0-9a-f]{40}$' then raise exception 'invalid_git_commit_sha'; end if;
 v_status:=case when p_break_glass then 'quarantined' else 'intent_registered' end;
 insert into public.contentflow_persistent_change_provenance(project_key,change_class,incident_id,repair_recipe,migration_name,git_commit_sha,git_pr_number,causal_state_version,evidence_id,evidence,break_glass,status)
 values(coalesce(nullif(p_project_key,''),'contentflow'),p_change_class,p_incident_id,p_repair_recipe,nullif(p_migration_name,''),nullif(lower(p_git_commit_sha),''),p_git_pr_number,nullif(p_causal_state_version,''),nullif(p_evidence_id,''),coalesce(p_evidence,'{}'::jsonb),coalesce(p_break_glass,false),v_status) returning change_id into v_id;
 return jsonb_build_object('architecture','AUTONOMOUS_REPAIR_PROVENANCE_CONTRACT_V1','change_id',v_id,'status',v_status,'break_glass',coalesce(p_break_glass,false));
end $_$;


--
-- Name: contentflow_release_nexo_slot(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_release_nexo_slot(p_slot uuid, p_reason text DEFAULT 'completed'::text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ update contentflow_nexo_slots set released_at=coalesce(released_at,now()),release_reason=coalesce(release_reason,p_reason) where slot_id=p_slot; $$;


--
-- Name: contentflow_replan_failed_evidence(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_replan_failed_evidence(p_project_key text DEFAULT 'contentflow'::text, p_limit integer DEFAULT 20) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare x record; v_created int:=0; v_examined int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
 for x in
   select q.id queue_id,q.task_key evidence_task_key,q.last_error,er.id req_id,er.requirement_class,er.requirement_text,er.source_run_id,b.task_key source_task,b.title source_title
   from public.contentflow_tool_execution_queue q
   join public.contentflow_evidence_requirements er on er.project_key=q.project_key and er.evidence_task_key=q.task_key
   join public.contentflow_build_backlog b on b.id=er.backlog_task_id
   where q.project_key=p_project_key and q.state='failed' and q.last_error like 'EVIDENCE_NOT_AVAILABLE:%'
   order by q.updated_at asc limit greatest(1,least(coalesce(p_limit,20),100))
 loop
   v_examined:=v_examined+1;
   insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,quality_score,cost_usd,execution_lane,completion_phase,runtime_verified,updated_at)
   values(p_project_key,'evidence_recovery','repair_evidence_req_'||x.req_id::text,'Produce real evidence for '||x.source_task,
     'RARA recovery. The source task/run identifiers shown in metadata are correlation context ONLY. Any implementation or harness MUST accept task_id/run_id dynamically from runtime input/environment and MUST NOT hardcode them. Execute the smallest real bounded test/integration needed for the exact requirement. Persist correlated evidence through the platform evidence interface. Never use mock authentication, fabricated CI output, simulated external service success, invented SHA, or static prose as runtime proof. If a real dependency is unavailable, fail closed and report the dependency so the Director can plan it. Requirement: '||left(coalesce(x.requirement_text,''),3000),
     'code',4,'[]'::jsonb,'rara:evidence_recovery','planned',100,
     'Real task-specific evidence is executed and persisted; task/run IDs are runtime inputs not literals; verifier independently validates evidence; mocks/fabricated CI/auth/runtime are rejected.',0,0,'llm_artifact','artifact_only',false,now())
   on conflict(project_key,task_key) do update set description=excluded.description,acceptance_criteria=excluded.acceptance_criteria,updated_at=now();
   if found then v_created:=v_created+1; end if;
   update public.contentflow_tool_execution_queue set state='blocked',last_error='REPLANNED_TASK_SPECIFIC_EVIDENCE',updated_at=now() where id=x.queue_id;
   update public.contentflow_build_backlog set status='blocked',blocked_reason='WAITING_TASK_SPECIFIC_EVIDENCE_REPAIR',updated_at=now() where project_key=p_project_key and task_key=x.evidence_task_key and status<>'completed';
 end loop;
 update public.director_repair_incidents set status='resolved',resolved_at=now(),updated_at=now(),requires_human=false,outcome='replanned_task_specific_evidence',executed_action='contentflow_replan_failed_evidence_v2' where project_key=p_project_key and error_fingerprint='evidence_attempts_without_verified_progress_v1' and status in ('open','analyzing','repairing','validating','needs_help');
 perform public.contentflow_normalize_dispatchability(p_project_key);
 return jsonb_build_object('architecture','RARA_TASK_SPECIFIC_EVIDENCE_REPLAN_V2','examined',v_examined,'created_or_updated',v_created);
end $$;


--
-- Name: contentflow_requires_runtime_evidence(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_requires_runtime_evidence(p_task_type text, p_title text, p_description text, p_acceptance_criteria text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
with s as (
  select lower(coalesce(p_title,'')||' '||coalesce(p_description,'')||' '||coalesce(p_acceptance_criteria,'')) as txt,
         lower(coalesce(p_task_type,'')) as task_type
), f as (
  select *,
    txt ~ '(must .*runtime|runtime verification required|verified by .*runtime|live execution required|actual execution required|deploy(ed|ment)? required|integration test required|runtime test required|runtime evidence required|executed in .*sandbox|runtime canary|sandbox deploy)' as explicit_runtime,
    txt ~ '(blueprint|strategy|warm[- ]up|plan\b|document(ed|ation)?|define\b|specif(y|ication)|architecture blueprint|information architecture|no production deployment claim|external service boundary)' as design_only,
    txt ~ '(implementation[- ]ready .*artifact|instrumentation spec|do not claim live telemetry|not a confirmation of (its )?deployment|no production deployment claim|source artifact .*does not claim deployment)' as artifact_only
  from s
)
select case
  when txt ~ '(official primary sources|source-only|source only|claim-to-source|evidence gaps|pending_benchmark|pending evidence)'
       and not explicit_runtime then false
  when explicit_runtime then true
  when artifact_only then false
  when task_type='code' then true
  when design_only then false
  when task_type='architecture' then
    txt ~ '(runtime|deploy|deployment|integration|endpoint|database|sql|migration|rollback|restore|trigger|rls|secret|vault|cron|worker|lease|claim|idempot|api)'
  else
    txt ~ '(runtime|deploy|deployment|integration|endpoint|database|sql|migration|rollback|restore|trigger|rls|secret|vault|cron|worker|lease|claim|idempot|api)'
end from f;
$$;


--
-- Name: contentflow_research_deliverable_preflight(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_research_deliverable_preflight(p_task_key text, p_result text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare t text:=lower(coalesce(p_result,'')); missing jsonb:='[]'::jsonb; ok boolean:=true;begin
 if p_task_key='avatar_research_routes_abc_v1' then
   if position('| route |' in t)=0 then missing:=missing||'"matrix_route_column"'::jsonb; end if;
   if position('license' in t)=0 then missing:=missing||'"license_field"'::jsonb; end if;
   if position('latency' in t)=0 and position('latencia' in t)=0 then missing:=missing||'"latency_field"'::jsonb; end if;
   if position('hardware' in t)=0 and position('vram' in t)=0 then missing:=missing||'"hardware_field"'::jsonb; end if;
   if position('vendor_claim' in t)=0 then missing:=missing||'"claim_classification"'::jsonb; end if;
   if position('http://' in t)=0 and position('https://' in t)=0 then missing:=missing||'"source_urls"'::jsonb; end if;
   if position('route a' in t)=0 and position('| a |' in t)=0 then missing:=missing||'"route_a"'::jsonb; end if;
   if position('route b' in t)=0 and position('| b |' in t)=0 then missing:=missing||'"route_b"'::jsonb; end if;
   if position('route c' in t)=0 and position('| c |' in t)=0 then missing:=missing||'"route_c"'::jsonb; end if;
   if position('evidence gap' in t)=0 and position('brecha' in t)=0 and position('pending evidence' in t)=0 then missing:=missing||'"evidence_gaps"'::jsonb; end if;
 end if;
 ok:=jsonb_array_length(missing)=0;
 return jsonb_build_object('ok',ok,'architecture','RESEARCH_DELIVERABLE_SCHEMA_GATE_V1','missing',missing);
end$$;


--
-- Name: contentflow_research_submission_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_research_submission_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare g jsonb; verified_urls int; cited_urls int;begin
 if new.status='review_required' and exists(
   select 1 from public.contentflow_build_backlog b where b.id=new.backlog_task_id and upper(coalesce(b.acceptance_criteria,'')) like '%OFFICIAL PRIMARY SOURCES%'
 ) then
   g:=public.contentflow_primary_source_gate(new.project_key,new.task_key);
   if not coalesce((g->>'ok')::boolean,false) then raise exception 'PRIMARY_SOURCE_GATE_FAILED:%',g::text; end if;
   select count(*) into verified_urls from public.contentflow_primary_source_evidence e where e.project_key=new.project_key and e.task_key=new.task_key and e.verification_status='verified' and e.source_type='official_primary';
   select count(*) into cited_urls from public.contentflow_primary_source_evidence e where e.project_key=new.project_key and e.task_key=new.task_key and e.verification_status='verified' and e.source_type='official_primary' and position(e.source_url in coalesce(new.result,''))>0;
   if cited_urls < least(5,verified_urls) then raise exception 'PRIMARY_SOURCE_CITATION_GATE_FAILED: cited=% verified=%',cited_urls,verified_urls; end if;
 end if;
 return new;
end$$;


--
-- Name: contentflow_resilience_self_test(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_resilience_self_test(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_duplicate_active int:=0;
  v_orphan_workers int:=0;
  v_expired_leases int:=0;
  v_state_mismatch int:=0;
  v_needs_help int:=0;
  v_open_incidents int:=0;
  v_failed int:=0;
  v_total int:=0;
  v_trace text:=public.contentflow_make_trace_id();
  v_status text:='pass';
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;

  select count(*) into v_duplicate_active from (
    select backlog_task_id from public.contentflow_builder_runs
    where project_key=p_project_key and status in ('claimed','running','review_required','verification_required') and finished_at is null
    group by backlog_task_id having count(*)>1
  ) x;

  select count(*) into v_expired_leases from public.contentflow_builder_runs
  where project_key=p_project_key and status in ('claimed','running') and finished_at is null
    and (lease_expires_at is null or lease_expires_at<=now());

  select count(*) into v_orphan_workers from public.director_worker_queue q
  where q.status='running' and not exists(
    select 1 from public.contentflow_builder_runs r
    where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null
      and r.selected_model=q.model_id and r.task_key=q.current_task_key
  );

  select count(*) into v_state_mismatch
  from public.contentflow_builder_runs r
  left join public.contentflow_build_backlog b on b.id=r.backlog_task_id
  left join public.director_worker_queue q on q.model_id=r.selected_model
  where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null
    and (b.status<>'running' or b.selected_model is distinct from r.selected_model or q.status<>'running' or q.current_task_key is distinct from r.task_key);

  select count(*) into v_needs_help from public.director_repair_incidents where project_key=p_project_key and status='needs_help';
  select count(*) into v_open_incidents from public.director_repair_incidents where project_key=p_project_key and status in ('open','analyzing','repairing','validating','needs_help');

  insert into public.director_resilience_checks(project_key,check_name,status,observed,expected,trace_id)
  values
    (p_project_key,'single_active_owner',case when v_duplicate_active=0 then 'pass' else 'fail' end,jsonb_build_object('duplicates',v_duplicate_active),jsonb_build_object('duplicates',0),v_trace),
    (p_project_key,'lease_health',case when v_expired_leases=0 then 'pass' else 'fail' end,jsonb_build_object('expired',v_expired_leases),jsonb_build_object('expired',0),v_trace),
    (p_project_key,'worker_run_consistency',case when v_orphan_workers=0 then 'pass' else 'fail' end,jsonb_build_object('orphan_workers',v_orphan_workers),jsonb_build_object('orphan_workers',0),v_trace),
    (p_project_key,'active_state_consistency',case when v_state_mismatch=0 then 'pass' else 'fail' end,jsonb_build_object('mismatches',v_state_mismatch),jsonb_build_object('mismatches',0),v_trace),
    (p_project_key,'human_help_boundary',case when v_needs_help=0 then 'pass' else 'warn' end,jsonb_build_object('needs_help',v_needs_help),jsonb_build_object('needs_help',0),v_trace);

  select count(*),count(*) filter(where status='fail') into v_total,v_failed
  from public.director_resilience_checks where project_key=p_project_key and trace_id=v_trace;
  if v_failed>0 then v_status:='fail'; elsif v_needs_help>0 then v_status:='warn'; end if;

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'resilience_self_test','master_director_v3','invariant_probe',v_status,v_needs_help>0,
    jsonb_build_object('trace_id',v_trace,'checks',v_total,'failed',v_failed,'open_incidents',v_open_incidents,'needs_help',v_needs_help)::text,now());

  return jsonb_build_object('status',v_status,'trace_id',v_trace,'checks',v_total,'failed',v_failed,'duplicate_active',v_duplicate_active,'expired_leases',v_expired_leases,'orphan_workers',v_orphan_workers,'state_mismatches',v_state_mismatch,'open_incidents',v_open_incidents,'needs_help',v_needs_help);
end
$$;


--
-- Name: contentflow_resolve_obsolete_incidents(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_resolve_obsolete_incidents(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n_completed int:=0; n_transient int:=0; n_help int:=0; begin
  update public.director_repair_incidents i
  set status='resolved_obsolete',resolved_at=coalesce(resolved_at,now()),updated_at=now(),outcome='resolved_by_completed_task',requires_human=false
  where i.project_key=p_project_key and i.status in ('open','analyzing','repairing','needs_help') and i.task_key is not null
    and exists(select 1 from public.contentflow_build_backlog b where b.project_key=i.project_key and b.task_key=i.task_key and b.status='completed');
  get diagnostics n_completed=row_count;

  update public.director_repair_incidents i
  set status='resolved_transient',resolved_at=coalesce(resolved_at,now()),updated_at=now(),outcome='transient_failure_reopened_under_canonical_retry_policy',requires_human=false
  where i.project_key=p_project_key and i.status='needs_help' and i.task_key is not null
    and public.contentflow_classify_run_error(i.symptom) in ('capacity','judge','provider','timeout','state_recovery');
  get diagnostics n_transient=row_count;

  update public.director_help_alerts h
  set status='resolved',resolved_at=coalesce(resolved_at,now()),updated_at=now(),summary=coalesce(summary,'')||' | AUTO_RESOLVED_CANONICAL_CLASSIFIER'
  where h.project_key=p_project_key and h.status='open' and (
    exists(select 1 from public.director_repair_incidents i where i.project_key=h.project_key and i.error_fingerprint=h.error_fingerprint and i.status not in ('needs_help'))
    or exists(select 1 from public.contentflow_build_backlog b where b.project_key=h.project_key and b.task_key=h.task_key and b.status='completed')
  );
  get diagnostics n_help=row_count;
  return jsonb_build_object('completed_incidents',n_completed,'transient_incidents',n_transient,'help_alerts_resolved',n_help);
end $$;


--
-- Name: contentflow_retire_obsolete_evidence_tombstones_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_retire_obsolete_evidence_tombstones_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_runs int:=0; v_tasks int:=0; v_workers int:=0; v_slots int:=0; v_reviews int:=0; v_retry int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;

  update public.contentflow_builder_runs r
     set status='deferred',finished_at=coalesce(r.finished_at,now()),error='OBSOLETE_REPAIR_EVIDENCE_TOMBSTONED',
         lease_revoked_at=coalesce(r.lease_revoked_at,now()),lease_generation=r.lease_generation+1,
         activity_phase=null,activity_deadline_at=null,heartbeat_deadline_at=null
   where r.project_key=p_project_key and r.status in ('claimed','running','review_required','verification_required')
     and exists(
       select 1 from public.contentflow_build_backlog b
       where b.id=r.backlog_task_id and b.task_key like 'repair_evidence_req_%'
         and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
     );
  get diagnostics v_runs=row_count;

  update public.contentflow_review_work_queue q
     set state='done',claim_token=null,claimed_at=null,last_error='OBSOLETE_REPAIR_EVIDENCE_TOMBSTONED',updated_at=now()
   where q.state in ('pending','claimed') and exists(
     select 1 from public.contentflow_builder_runs r join public.contentflow_build_backlog b on b.id=r.backlog_task_id
     where r.id=q.builder_run_id and b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
       and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
   );
  get diagnostics v_reviews=row_count;

  update public.contentflow_retry_state rs set circuit_state='closed',attempt_count=0,next_retry_at=null,circuit_open_until=null,updated_at=now()
  from public.contentflow_build_backlog b
  where rs.backlog_task_id=b.id and b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
    and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete');
  get diagnostics v_retry=row_count;

  update public.director_worker_queue q set status='ready',current_task_key=null,last_outcome='obsolete_evidence_tombstoned',updated_at=now()
  where q.current_task_key in (
    select b.task_key from public.contentflow_build_backlog b where b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
      and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
  );
  get diagnostics v_workers=row_count;

  update public.contentflow_nexo_slots s set released_at=coalesce(s.released_at,now()),release_reason=coalesce(s.release_reason,'obsolete_evidence_tombstoned')
  where s.released_at is null and s.task_key in (
    select b.task_key from public.contentflow_build_backlog b where b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
      and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
  );
  get diagnostics v_slots=row_count;

  update public.contentflow_build_backlog b
     set status='deferred',workflow_state='obsolete',completion_phase='obsolete',blocked_reason='OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT',next_eligible_at=null,selected_model=null,updated_at=now()
   where b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
     and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
     and (b.status<>'deferred' or b.workflow_state<>'obsolete' or b.completion_phase<>'obsolete' or coalesce(b.blocked_reason,'')<>'OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT' or b.next_eligible_at is not null or b.selected_model is not null);
  get diagnostics v_tasks=row_count;

  return jsonb_build_object('architecture','OBSOLETE_EVIDENCE_TOMBSTONE_GUARD_V1','runs_revoked',v_runs,'tasks_tombstoned',v_tasks,'workers_released',v_workers,'slots_released',v_slots,'reviews_closed',v_reviews,'retry_states_closed',v_retry);
end $$;


--
-- Name: contentflow_review_gate_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_review_gate_reconcile(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$
declare
  x record;
  v_secret text;
  v_req bigint;
  v_dispatched int:=0;
  v_stale_claims int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;

  -- Recover stale RARA claims without destroying the already-generated artifact.
  update public.contentflow_review_work_queue q
     set state='pending',claim_token=null,claimed_at=null,available_at=now(),last_error='stale_review_claim_recovered',updated_at=now()
   where q.state='claimed' and q.claimed_at<now()-interval '5 minutes'
     and exists(select 1 from public.contentflow_builder_runs r where r.id=q.builder_run_id and r.project_key=p_project_key and r.status='review_required');
  get diagnostics v_stale_claims=row_count;

  select runner_secret into v_secret from public.contentflow_internal_runner_config where id=1;
  if coalesce(v_secret,'')='' then
    return jsonb_build_object('architecture','JUDGE_ONLY_RECOVERY_V1','judge_recovery_dispatched',0,'stale_claims_recovered',v_stale_claims,'warning','runner_secret_missing');
  end if;

  -- A missing/unparseable judge must NEVER cause the worker artifact to be regenerated.
  -- Re-run only the QA judge over the persisted artifact.
  for x in
    select r.id,q.builder_run_id
    from public.contentflow_builder_runs r
    join public.contentflow_review_work_queue q on q.builder_run_id=r.id
    where r.project_key=p_project_key
      and r.status='review_required'
      and r.result is not null
      and length(trim(r.result))>=40
      and coalesce(r.error,'') ilike '%judge_unavailable_or_unparseable%'
      and q.state='pending'
      and q.available_at<=now()
    order by q.updated_at,r.id
    limit 4
    for update of q skip locked
  loop
    select net.http_post(
      url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-judge-recovery',
      headers:=jsonb_build_object('Content-Type','application/json','X-ContentFlow-Internal',v_secret),
      body:=jsonb_build_object('run_id',x.id),
      timeout_milliseconds:=120000
    ) into v_req;
    update public.contentflow_review_work_queue
       set available_at=now()+interval '45 seconds',last_error='judge_recovery_dispatched:'||v_req::text,updated_at=now()
     where builder_run_id=x.id and state='pending';
    v_dispatched:=v_dispatched+1;
  end loop;

  if v_dispatched>0 or v_stale_claims>0 then
    insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
    values(p_project_key,'review_queue_reconcile','rara','judge_only_recovery','recovery_dispatched',false,
           format('judge_only_recovery=%s stale_claims=%s',v_dispatched,v_stale_claims),now());
  end if;

  return jsonb_build_object('architecture','JUDGE_ONLY_RECOVERY_V1','judge_recovery_dispatched',v_dispatched,'stale_claims_recovered',v_stale_claims);
end
$$;


--
-- Name: contentflow_run_evidence_producer_recipe(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_run_evidence_producer_recipe(p_evidence_task_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  r public.contentflow_evidence_producer_recipes%rowtype;
  er public.contentflow_evidence_requirements%rowtype;
  ok boolean:=false;
  observed jsonb:='{}'::jsonb;
  n bigint:=0;
  spec jsonb;
  evidence_payload jsonb;
  rec jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  select * into r from public.contentflow_evidence_producer_recipes where project_key='contentflow' and evidence_task_key=p_evidence_task_key and enabled=true;
  if not found then return jsonb_build_object('ok',false,'reason','recipe_not_found'); end if;
  select * into er from public.contentflow_evidence_requirements where project_key=r.project_key and evidence_task_key=r.evidence_task_key order by id desc limit 1;
  if not found then return jsonb_build_object('ok',false,'reason','requirement_not_found'); end if;
  spec:=r.check_spec;
  if r.check_type='table_exists' then
    select exists(select 1 from information_schema.tables where table_schema=coalesce(spec->>'schema','public') and table_name=spec->>'table') into ok;
    observed:=jsonb_build_object('schema',coalesce(spec->>'schema','public'),'table',spec->>'table','exists',ok);
  elsif r.check_type='function_exists' then
    select exists(select 1 from pg_proc p join pg_namespace nsp on nsp.oid=p.pronamespace where nsp.nspname=coalesce(spec->>'schema','public') and p.proname=spec->>'function') into ok;
    observed:=jsonb_build_object('schema',coalesce(spec->>'schema','public'),'function',spec->>'function','exists',ok);
  elsif r.check_type='policy_exists' then
    select exists(select 1 from pg_policies where schemaname=coalesce(spec->>'schema','public') and tablename=spec->>'table' and policyname=spec->>'policy') into ok;
    observed:=jsonb_build_object('schema',coalesce(spec->>'schema','public'),'table',spec->>'table','policy',spec->>'policy','exists',ok);
  elsif r.check_type='event_exists' then
    select count(*) into n from public.contentflow_runtime_event_ledger l where l.builder_run_id=er.source_run_id and l.event_type=spec->>'event_type';
    ok:=n>=coalesce((spec->>'min_count')::int,1);
    observed:=jsonb_build_object('builder_run_id',er.source_run_id,'event_type',spec->>'event_type','count',n);
  elsif r.check_type='runtime_verification_exists' then
    select count(*) into n from public.contentflow_runtime_verifications v where v.builder_run_id=er.source_run_id and v.passed=true and (spec->>'verification_type' is null or v.verification_type=spec->>'verification_type');
    ok:=n>=1;
    observed:=jsonb_build_object('builder_run_id',er.source_run_id,'verification_type',spec->>'verification_type','count',n);
  elsif r.check_type='row_count_gte' then
    return jsonb_build_object('ok',false,'reason','row_count_gte_requires_curated_query_not_enabled_v1');
  end if;
  if not ok then return jsonb_build_object('ok',true,'passed',false,'check_type',r.check_type,'observed',observed); end if;
  evidence_payload:=jsonb_build_object('architecture','DETERMINISTIC_PLATFORM_EVIDENCE_PRODUCER_V1','requirement_id',er.id,'source_task_key',er.task_key,'source_run_id',er.source_run_id,'evidence_task_key',er.evidence_task_key,'check_type',r.check_type,'check_spec',r.check_spec,'observed',observed,'verified_at',now());
  rec:=public.contentflow_record_runtime_evidence(er.source_run_id,'deterministic_platform_check','recipe:'||er.id::text,evidence_payload,'contentflow_run_evidence_producer_recipe',now());
  return jsonb_build_object('ok',true,'passed',true,'check_type',r.check_type,'observed',observed,'record',rec);
end $$;


--
-- Name: contentflow_runtime_claims_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_runtime_claims_snapshot() RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ select jsonb_pretty(jsonb_build_object('unique_active_task',exists(select 1 from pg_indexes where schemaname='public' and indexname='contentflow_builder_runs_one_active_per_task'),'unique_active_worker',exists(select 1 from pg_indexes where schemaname='public' and indexname='contentflow_builder_runs_one_active_per_worker'),'idempotency_unique',exists(select 1 from pg_indexes where schemaname='public' and indexname='contentflow_builder_runs_idempotency_key_uq'),'lease_fields',exists(select 1 from information_schema.columns where table_schema='public' and table_name='contentflow_builder_runs' and column_name='lease_expires_at') and exists(select 1 from information_schema.columns where table_schema='public' and table_name='contentflow_builder_runs' and column_name='heartbeat_at'),'heartbeat_rpc',exists(select 1 from pg_proc where proname='contentflow_builder_heartbeat'),'lease_recovery_rpc',exists(select 1 from pg_proc where proname='contentflow_recover_expired_leases'),'event_ledger',to_regclass('public.contentflow_runtime_event_ledger') is not null,'historical_stale_recoveries',(select count(*) from public.contentflow_builder_runs where error in ('stale_claim_recovered','lease_expired_recovered'))))::text $$;


--
-- Name: contentflow_runtime_evidence_for_requirement(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_runtime_evidence_for_requirement(p_requirement_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  er public.contentflow_evidence_requirements%rowtype;
  v_rows jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if;
  select * into er from public.contentflow_evidence_requirements where id=p_requirement_id;
  if not found then return jsonb_build_object('available',false,'reason','requirement_not_found'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('evidence_id',l.id,'evidence_type',l.evidence_type,'evidence_key',l.evidence_key,'sha256',l.payload_sha256,'producer',l.producer,'observed_at',l.observed_at,'payload',l.payload) order by l.id),'[]'::jsonb)
    into v_rows
  from public.contentflow_runtime_evidence_ledger l
  where l.project_key=er.project_key and l.builder_run_id=er.source_run_id and l.task_key=er.task_key;
  return jsonb_build_object('available',jsonb_array_length(v_rows)>0,'requirement_id',er.id,'source_run_id',er.source_run_id,'evidence',v_rows);
end $$;


--
-- Name: contentflow_runtime_health_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_runtime_health_snapshot() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$ select format('RUNTIME SNAPSHOT %s | backlog_completed=%s backlog_ready=%s backlog_running=%s backlog_failed=%s backlog_planned=%s | workers_ready=%s | open_help=%s | pending_dispatches=%s | queued_http=%s', now(), (select count(*) from public.contentflow_build_backlog where project_key='contentflow' and task_key not like 'gap_gap_%' and status='completed'), (select count(*) from public.contentflow_build_backlog where project_key='contentflow' and task_key not like 'gap_gap_%' and status='ready'), (select count(*) from public.contentflow_build_backlog where project_key='contentflow' and task_key not like 'gap_gap_%' and status='running'), (select count(*) from public.contentflow_build_backlog where project_key='contentflow' and task_key not like 'gap_gap_%' and status='failed'), (select count(*) from public.contentflow_build_backlog where project_key='contentflow' and task_key not like 'gap_gap_%' and status='planned'), (select count(*) from public.director_worker_queue where status='ready'), (select count(*) from public.director_help_alerts where project_key='contentflow' and status='open'), (select count(*) from public.contentflow_builder_dispatches where status='pending'), (select count(*) from net.http_request_queue)); $$;


--
-- Name: contentflow_sanitize_dependency_graph(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sanitize_dependency_graph(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r record; cleaned int:=0; self_removed int:=0; dup_removed int:=0; old_n int; new_n int; self_n int;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 for r in select id,task_key,depends_on from public.contentflow_build_backlog where project_key=p_project_key loop
   old_n:=jsonb_array_length(coalesce(r.depends_on,'[]'::jsonb));
   select count(*) into self_n from jsonb_array_elements_text(coalesce(r.depends_on,'[]'::jsonb)) d(v) where d.v=r.task_key;
   with vals as (select distinct d.v from jsonb_array_elements_text(coalesce(r.depends_on,'[]'::jsonb)) d(v) where d.v<>r.task_key and exists(select 1 from public.contentflow_build_backlog x where x.project_key=p_project_key and x.task_key=d.v))
   select coalesce(jsonb_agg(v order by v),'[]'::jsonb),count(*) into r.depends_on,new_n from vals;
   if old_n<>new_n then
     update public.contentflow_build_backlog set depends_on=r.depends_on,updated_at=now() where id=r.id;
     cleaned:=cleaned+1; self_removed:=self_removed+self_n; dup_removed:=dup_removed+greatest(0,old_n-new_n-self_n);
   end if;
 end loop;
 return jsonb_build_object('tasks_cleaned',cleaned,'self_dependencies_removed',self_removed,'duplicate_or_missing_removed',dup_removed);
end $$;


--
-- Name: contentflow_seed_bootstrap_deadline(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_seed_bootstrap_deadline() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$ begin
 if new.project_key='contentflow' and new.control_protocol='fenced-v2' and new.status in ('claimed','running') and new.finished_at is null and new.runner_instance_id is null and new.activity_deadline_at is null then
   new.activity_phase:='bootstrap'; new.activity_deadline_at:=now()+interval '75 seconds';
 end if; return new; end $$;


--
-- Name: contentflow_set_execution_lane(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_set_execution_lane() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.execution_lane is null
     or (tg_op='UPDATE' and (new.task_type,new.description,new.acceptance_criteria) is distinct from (old.task_type,old.description,old.acceptance_criteria)) then
    new.execution_lane:=public.contentflow_classify_execution_lane_fields(new.task_type,new.description,new.acceptance_criteria);
  end if;
  return new;
end
$$;


--
-- Name: contentflow_state_invariant_reconcile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_state_invariant_reconcile(p_project_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare fixed_ready int:=0; fixed_blocked int:=0; fixed_review int:=0;begin
  update public.contentflow_build_backlog b
     set status='blocked', blocked_reason='REVIEW_PENDING', next_eligible_at=null, updated_at=now()
   where b.project_key=p_project_key
     and exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status='review_required')
     and (b.status<>'blocked' or coalesce(b.blocked_reason,'')<>'REVIEW_PENDING' or b.next_eligible_at is not null);
  get diagnostics fixed_review=row_count;

  update public.contentflow_build_backlog b
     set blocked_reason=null,
         next_eligible_at=coalesce(b.next_eligible_at,now()),
         updated_at=now()
   where b.project_key=p_project_key
     and b.status='ready'
     and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status='review_required')
     and (b.blocked_reason is not null or exists(
       select 1 from public.contentflow_retry_state r
       where r.project_key=b.project_key and r.task_key=b.task_key and r.circuit_state='open'
     ));
  get diagnostics fixed_ready=row_count;

  update public.contentflow_retry_state r
     set circuit_state='closed',circuit_open_until=null,next_retry_at=null,updated_at=now()
   where r.project_key=p_project_key
     and exists(select 1 from public.contentflow_build_backlog b where b.project_key=r.project_key and b.task_key=r.task_key and b.status='ready')
     and not exists(select 1 from public.contentflow_builder_runs br join public.contentflow_build_backlog bb on bb.id=br.backlog_task_id where bb.project_key=r.project_key and bb.task_key=r.task_key and br.status='review_required');

  update public.contentflow_build_backlog b
     set blocked_reason=coalesce(nullif(b.blocked_reason,''),'STATE_INVARIANT_BLOCKED_UNSPECIFIED'),
         next_eligible_at=coalesce(b.next_eligible_at,now()+interval '7 minutes'),
         updated_at=now()
   where b.project_key=p_project_key and b.status='blocked'
     and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status='review_required')
     and (b.blocked_reason is null or b.next_eligible_at is null)
     and not exists(select 1 from public.director_repair_incidents i where i.project_key=b.project_key and i.status='needs_help' and i.requires_human=true);
  get diagnostics fixed_blocked=row_count;

  return jsonb_build_object('ok',true,'architecture','STATE_INVARIANT_RECONCILE_V2_REVIEW_PROTECTED','fixed_ready',fixed_ready,'fixed_blocked',fixed_blocked,'fixed_review_pending',fixed_review);
end$$;


--
-- Name: contentflow_strip_internal_execution_identity(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_strip_internal_execution_identity(p_run_id bigint, p_text text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $_$
declare out_text text; rid text:=p_run_id::text;begin
 select string_agg(line,E'\n' order by ord) into out_text
 from unnest(string_to_array(coalesce(p_text,''),E'\n')) with ordinality as t(line,ord)
 where not (
   line ~ ('(^|[^0-9])'||rid||'([^0-9]|$)')
   and lower(line) ~ '(builder|constructor|run|corrida|ejecuci[oó]n|execution|source[_ ]?run|correlation|correlaci[oó]n|evidence|evidencia|trace|traza|identificador|\bid\b)'
 );
 return coalesce(out_text,'');
end$_$;


--
-- Name: contentflow_sync_builder_span(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_builder_span() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare cls text; begin
 if new.trace_id is null or new.span_id is null then return new; end if;
 cls:=case when new.error is null then null else public.contentflow_classify_run_error(new.error) end;
 insert into public.director_trace_spans(span_id,trace_id,project_key,builder_run_id,span_name,span_kind,span_status,started_at,ended_at,attributes,error_class,error_message)
 values(new.span_id,new.trace_id,new.project_key,new.id,'builder.run','consumer',case when new.status='completed' then 'ok' when new.status in ('failed','deferred') then 'error' else 'unset' end,new.created_at,new.finished_at,
   jsonb_build_object('task_key',new.task_key,'task_type',new.task_type,'model',coalesce(new.selected_model,''),'workflow_version',coalesce(new.workflow_version,''),'quality_score',new.quality_score,'review_approved',new.review_approved),cls,case when new.error is null then null else left(new.error,500) end)
 on conflict(span_id) do update set span_status=excluded.span_status,ended_at=excluded.ended_at,attributes=excluded.attributes,error_class=excluded.error_class,error_message=excluded.error_message;
 return new;
end $$;


--
-- Name: contentflow_sync_dependency_states(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_dependency_states(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare demoted int:=0; promoted int:=0;
begin
  update public.contentflow_build_backlog b
     set status='planned',selected_model=null,blocked_reason='DEPENDENCY_INCOMPLETE',next_eligible_at=null,updated_at=now()
   where b.project_key=p_project_key
     and b.status='ready'
     and exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists(
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     );
  get diagnostics demoted=row_count;

  update public.contentflow_build_backlog b
     set status='ready',selected_model=null,blocked_reason=null,next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key
     and b.status in ('planned','blocked')
     and b.task_key not like 'gap_gap_%'
     and (b.status='planned' or coalesce(b.blocked_reason,'') in ('','STATE_GUARD_BLOCKED_UNSPECIFIED','DEPENDENCY_INCOMPLETE'))
     and not exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists(
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     )
     and not exists(
       select 1 from public.contentflow_retry_state rs
       where rs.backlog_task_id=b.id and rs.circuit_state='open'
     );
  get diagnostics promoted=row_count;

  return jsonb_build_object('architecture','DEPENDENCY_STATE_SYNC_V3_EXTERNAL_BLOCKER_SAFE','demoted_waiting',demoted,'promoted_dispatchable',promoted);
end
$$;


--
-- Name: contentflow_sync_help_and_dependents(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_help_and_dependents() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status='completed' and old.status is distinct from new.status then
    update public.director_help_alerts
       set status='resolved', resolved_at=now(), updated_at=now(),
           summary=coalesce(summary,'') || case when coalesce(summary,'')='' then '' else ' | ' end || 'AUTO_RESOLVED_FROM_BACKLOG_COMPLETION'
     where project_key=new.project_key and task_key=new.task_key and status='open';

    update public.contentflow_build_backlog p
       set status='ready', updated_at=now(), selected_model=null, blocked_reason=null, next_eligible_at=now()
     where p.project_key=new.project_key
       and p.status in ('blocked','planned')
       and (
         p.status='planned'
         or coalesce(p.blocked_reason,'') in ('','STATE_GUARD_BLOCKED_UNSPECIFIED')
       )
       and jsonb_array_length(coalesce(p.depends_on,'[]'::jsonb)) > 0
       and not exists (
         select 1
           from jsonb_array_elements_text(coalesce(p.depends_on,'[]'::jsonb)) d(dep)
           left join public.contentflow_build_backlog q
             on q.project_key=new.project_key and q.task_key=d.dep
          where coalesce(q.status,'missing') <> 'completed'
       )
       and not exists(
         select 1 from public.contentflow_retry_state rs
         where rs.backlog_task_id=p.id and rs.circuit_state='open'
       );
  end if;
  return new;
end
$$;


--
-- Name: contentflow_sync_obsolete_evidence_requirement(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_obsolete_evidence_requirement() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.project_key='contentflow' and new.status='obsolete' and new.evidence_task_key is not null then
    update public.contentflow_build_backlog b
       set blocked_reason='OBSOLETE_EVIDENCE_REQUIREMENT',
           workflow_state='obsolete',
           updated_at=now()
     where b.project_key=new.project_key
       and b.task_key=new.evidence_task_key
       and b.status='deferred';
  end if;
  return new;
end
$$;


--
-- Name: contentflow_sync_primary_source_context(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_primary_source_context() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare ctx text;begin
 ctx:=public.contentflow_primary_source_context(new.project_key,new.task_key);
 update public.contentflow_build_backlog b set description=regexp_replace(coalesce(b.description,''),E'\\n\\n\\[VERIFIED PRIMARY SOURCE PACK\\][\\s\\S]*$','','g')||E'\n\n[VERIFIED PRIMARY SOURCE PACK]\n'||ctx,updated_at=now()
 where b.project_key=new.project_key and b.task_key=new.task_key;
 return new;
end$_$;


--
-- Name: contentflow_sync_review_pending_backlog(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_review_pending_backlog() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status='review_required' then
    update public.contentflow_build_backlog
       set status='blocked',
           blocked_reason='REVIEW_PENDING',
           next_eligible_at=null,
           updated_at=now()
     where id=new.backlog_task_id;
  elsif tg_op='UPDATE' and old.status='review_required' and new.status<>'review_required' then
    update public.contentflow_build_backlog b
       set blocked_reason=case when b.status='blocked' and b.blocked_reason='REVIEW_PENDING' then null else b.blocked_reason end,
           updated_at=now()
     where b.id=new.backlog_task_id;
  end if;
  return new;
end$$;


--
-- Name: contentflow_sync_review_work_queue(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_review_work_queue() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
 if new.status='review_required' and (tg_op='INSERT' or old.status is distinct from new.status) then
   update public.contentflow_build_backlog
      set status='blocked', blocked_reason='REVIEW_PENDING', next_eligible_at=now()+interval '7 minutes', updated_at=now()
    where id=new.backlog_task_id and status not in ('completed','verification_required');
   insert into public.contentflow_review_work_queue(builder_run_id,task_key,state,available_at,updated_at)
   values(new.id,new.task_key,'pending',now(),now())
   on conflict(builder_run_id) do update
      set state='pending',claim_token=null,claimed_at=null,available_at=now(),last_error=null,updated_at=now();
 elsif tg_op='UPDATE' and old.status='review_required' and new.status<>'review_required' then
   update public.contentflow_review_work_queue
      set state='done',claim_token=null,claimed_at=null,updated_at=now()
    where builder_run_id=new.id;
 end if;
 return new;
end$$;


--
-- Name: contentflow_sync_tool_execution_queue(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_sync_tool_execution_queue(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare n int:=0; reactivated int:=0; quarantined int:=0; budget_blocked int:=0;
begin
 insert into public.contentflow_tool_execution_queue(project_key,backlog_task_id,task_key,state,updated_at)
 select b.project_key,b.id,b.task_key,'pending',now() from public.contentflow_build_backlog b
 where b.project_key=p_project_key and b.execution_lane in ('tool_executor','evidence_producer') and b.status in ('blocked','ready')
 and public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key) and (b.next_eligible_at is null or b.next_eligible_at<=now())
 and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'))
 on conflict(project_key,backlog_task_id) do nothing; get diagnostics n=row_count;

 update public.contentflow_tool_execution_queue q set state='pending',last_error=null,claim_token=null,claimed_at=null,updated_at=now()
 where q.project_key=p_project_key and q.state='blocked' and q.attempts<12
 and coalesce(q.last_error,'') in ('NOT_CURRENTLY_EXECUTABLE','ROUTED_TO_EVIDENCE_PRODUCER_V2','QUARANTINED_OFF_LANE_STALE_CLAIM','STALE_CLAIM_RECOVERED','')
 and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and b.execution_lane in ('tool_executor','evidence_producer') and b.status in ('blocked','ready') and public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key) and (b.next_eligible_at is null or b.next_eligible_at<=now()) and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed')));
 get diagnostics reactivated=row_count;

 update public.contentflow_tool_execution_queue q set state='blocked',claim_token=null,claimed_at=null,updated_at=now(),last_error='QUARANTINED_OFF_LANE_STALE_CLAIM' where q.project_key=p_project_key and q.state='claimed' and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and (b.execution_lane not in ('tool_executor','evidence_producer') or b.status<>'running'));
 get diagnostics quarantined=row_count;
 update public.contentflow_tool_execution_queue set state='blocked',claim_token=null,claimed_at=null,last_error='RETRY_BUDGET_EXHAUSTED',updated_at=now() where project_key=p_project_key and attempts>=12 and state<>'completed'; get diagnostics budget_blocked=row_count;
 update public.contentflow_build_backlog b set status='blocked',blocked_reason='RETRY_BUDGET_EXHAUSTED',updated_at=now() where b.project_key=p_project_key and b.status<>'completed' and exists(select 1 from public.contentflow_tool_execution_queue q where q.backlog_task_id=b.id and q.project_key=p_project_key and q.attempts>=12 and q.state='blocked');
 update public.contentflow_tool_execution_queue q set state='blocked',updated_at=now(),last_error='NOT_CURRENTLY_EXECUTABLE' where q.project_key=p_project_key and q.state='pending' and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and (b.execution_lane not in ('tool_executor','evidence_producer') or b.status not in ('blocked','ready') or not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key) or (b.next_eligible_at is not null and b.next_eligible_at>now()) or exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'))));
 return jsonb_build_object('architecture','DETERMINISTIC_EVIDENCE_QUEUE_V4_FAILURE_HOLD','synced',n,'reactivated',reactivated,'quarantined_claims',quarantined,'retry_budget_blocked',budget_blocked,'pending',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='pending'),'failed_held',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='failed'));
end $$;


--
-- Name: contentflow_tenant_security_admission_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_tenant_security_admission_v1(p_scope text DEFAULT 'customer_facing'::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$ declare r record; v_rel oid; v_rls boolean; v_force boolean; v_anon_grants int; v_auth_write int; v_policy_count int; v_blockers jsonb:='[]'::jsonb; v_tables jsonb:='[]'::jsonb; v_scope text:=lower(coalesce(nullif(p_scope,''),'customer_facing')); v_ok boolean:=true; begin if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if; if v_scope not in ('customer_facing','internal_control') then raise exception 'unsupported_security_admission_scope:%',v_scope; end if; for r in select * from public.contentflow_tenant_security_targets order by table_name loop select c.oid,c.relrowsecurity,c.relforcerowsecurity into v_rel,v_rls,v_force from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=r.table_name and c.relkind in ('r','p'); if v_rel is null then v_ok:=false; v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','table_missing')); v_tables:=v_tables||jsonb_build_array(jsonb_build_object('table',r.table_name,'exists',false)); continue; end if; select count(*) into v_anon_grants from information_schema.role_table_grants g where g.table_schema='public' and g.table_name=r.table_name and g.grantee='anon'; select count(*) into v_auth_write from information_schema.role_table_grants g where g.table_schema='public' and g.table_name=r.table_name and g.grantee='authenticated' and g.privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'); select count(*) into v_policy_count from pg_policy p where p.polrelid=v_rel; if v_scope='customer_facing' then if r.exposure_class='internal_only' then v_ok:=false; v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','internal_only_not_promotable')); end if; if r.required_rls and not coalesce(v_rls,false) then v_ok:=false; v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','rls_disabled')); end if; if v_anon_grants>0 then v_ok:=false; v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','anon_table_grants_present','count',v_anon_grants)); end if; if v_auth_write>0 then v_ok:=false; v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','authenticated_write_grants_present','count',v_auth_write)); end if; if r.exposure_class in ('customer_candidate','customer_approved') and r.required_rls and v_policy_count=0 then v_ok:=false; v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','rls_policy_missing')); end if; end if; v_tables:=v_tables||jsonb_build_array(jsonb_build_object('table',r.table_name,'exists',true,'exposure_class',r.exposure_class,'rls_enabled',coalesce(v_rls,false),'rls_forced',coalesce(v_force,false),'anon_grants',v_anon_grants,'authenticated_write_grants',v_auth_write,'policy_count',v_policy_count)); end loop; return jsonb_build_object('architecture','TENANT_RLS_SECURITY_ADMISSION_V1','scope',v_scope,'admitted',v_ok,'fail_closed',true,'tables',v_tables,'blockers',v_blockers,'evaluated_at',now()); end $$;


--
-- Name: contentflow_tool_execution_capability_ready(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_tool_execution_capability_ready(p_project_key text, p_task_key text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  b record;
  er record;
  prereq text;
  producer boolean:=false;
  recipe jsonb;
  has_recipe boolean:=false;
begin
  select id,epic,completion_phase,execution_lane,coalesce(workflow_contract,'{}'::jsonb) workflow_contract
    into b
  from public.contentflow_build_backlog
  where project_key=p_project_key and task_key=p_task_key
  order by id desc limit 1;
  if not found then return false; end if;

  if coalesce(b.epic,'')='evidence_first' or coalesce(b.completion_phase,'')='evidence_required' or coalesce(b.execution_lane,'')='evidence_producer' then
    select * into er
    from public.contentflow_evidence_requirements
    where project_key=p_project_key and evidence_task_key=p_task_key
    order by id desc limit 1;
    if not found then return false; end if;

    if public.contentflow_evidence_verifier_preflight(p_project_key,p_task_key) then
      return true;
    end if;

    select exists(
      select 1
      from public.contentflow_evidence_producer_recipes r
      where r.project_key=p_project_key
        and r.evidence_task_key=p_task_key
        and r.enabled=true
    ) into has_recipe;

    if coalesce((b.workflow_contract->>'no_retry_without_new_evidence')::boolean,false)
       and not has_recipe then
      return false;
    end if;

    prereq:=public.contentflow_evidence_prerequisite_class(er.requirement_class,er.requirement_text);
    select coalesce(producer_available,false) into producer
    from public.contentflow_evidence_capability_registry
    where prerequisite=prereq;
    return coalesce(producer,false);
  end if;

  if coalesce(b.execution_lane,'')='tool_executor' then
    recipe:=b.workflow_contract->'execution_recipe';
    return recipe is not null
       and jsonb_typeof(recipe)='object'
       and coalesce(recipe->>'handler','') in ('database_rpc','edge_function');
  end if;

  return false;
end;
$$;


--
-- Name: contentflow_transport_recovery_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_transport_recovery_v1(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$
declare x record; v_collected int:=0; v_expired int:=0; v_incidents int:=0; v_collect text;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 if not pg_try_advisory_xact_lock(hashtext('contentflow:transport-recovery:'||p_project_key)) then
   return jsonb_build_object('architecture','TRANSPORT_RECOVERY_V1','skipped','lock_busy');
 end if;
 for x in
   select d.request_id,d.builder_run_id
   from public.contentflow_builder_dispatches d
   join public.contentflow_builder_runs r on r.id=d.builder_run_id
   join net._http_response h on h.id=d.request_id
   where r.project_key=p_project_key and d.status='pending'
   order by d.builder_run_id
   for update of d skip locked
 loop
   begin
     v_collect:=public.internal_builder_collect(x.request_id);
     v_collected:=v_collected+1;
   exception when others then
     update public.contentflow_builder_dispatches set error=left('collect_failed:'||sqlerrm,1000) where request_id=x.request_id and status='pending';
   end;
 end loop;
 for x in
   select r.id run_id,r.backlog_task_id,r.task_key,r.selected_model,d.request_id
   from public.contentflow_builder_runs r
   join public.contentflow_builder_dispatches d on d.builder_run_id=r.id
   where r.project_key=p_project_key and d.status='pending' and r.status in ('claimed','running') and r.finished_at is null and r.lease_revoked_at is null
     and not exists(select 1 from net._http_response h where h.id=d.request_id)
     and d.created_at<now()-interval '8 minutes'
     and (r.activity_deadline_at is null or r.activity_deadline_at<now())
     and (r.heartbeat_deadline_at is null or r.heartbeat_deadline_at<now())
   order by r.id
   for update of r,d skip locked
 loop
   perform pg_advisory_xact_lock(hashtext('contentflow:run:'||x.run_id::text));
   update public.contentflow_builder_runs set status='deferred',finished_at=now(),error='TRANSPORT_TIMEOUT_EXPIRED',lease_revoked_at=now(),lease_generation=lease_generation+1 where id=x.run_id and status in ('claimed','running') and finished_at is null;
   update public.contentflow_builder_dispatches set status='superseded',collected_at=now(),error='transport_timeout_expired' where request_id=x.request_id and status='pending';
   update public.contentflow_build_backlog b set status='ready',selected_model=null,blocked_reason=null,next_eligible_at=now()+interval '10 seconds',updated_at=now()
    where b.id=x.backlog_task_id and b.status='running' and not exists(select 1 from public.contentflow_builder_runs z where z.backlog_task_id=b.id and z.id<>x.run_id and z.status in ('claimed','running','review_required','verification_required') and z.finished_at is null);
   update public.director_worker_queue set status='ready',current_task_key=null,last_outcome='transport_recovered',updated_at=now() where model_id=x.selected_model and current_task_key=x.task_key;
   v_expired:=v_expired+1;
 end loop;
 update public.director_repair_incidents i set status='resolved',requires_human=false,resolved_at=now(),updated_at=now(),diagnosis='Stale dispatch classified as deterministic transport lifecycle condition',root_cause='Dispatcher response/lease lifecycle race, now covered by transport recovery',proposed_action='Collect completed responses or fence only truly expired transport',executed_action='transport_recover',validation='dispatch_terminal_or_run_terminal',outcome='auto_transport_recovered'
 where i.project_key=p_project_key and i.error_class='stale_dispatch' and i.status in ('open','analyzing','repairing','validating','needs_help')
   and exists(select 1 from public.contentflow_builder_dispatches d left join public.contentflow_builder_runs r on r.id=d.builder_run_id where i.error_fingerprint='stale_dispatch:'||d.request_id::text and (d.status<>'pending' or r.status not in ('claimed','running') or r.finished_at is not null or r.lease_revoked_at is not null));
 get diagnostics v_incidents=row_count;
 return jsonb_build_object('architecture','TRANSPORT_RECOVERY_V1','collected_responses',v_collected,'expired_fenced',v_expired,'incidents_resolved',v_incidents);
end $$;


--
-- Name: contentflow_verified_external_evidence_context(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_verified_external_evidence_context(p_project_key text, p_task_key text) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select string_agg(
    format('type=%s | status=%s | verified=%s | source=%s | evidence=%s',
      e.evidence_type,
      e.status,
      e.verified,
      coalesce(e.source,''),
      left(coalesce(e.evidence::text,'{}'),2000)
    ),
    E'\n---\n'
    order by e.created_at desc, e.id desc
  )
  from public.director_external_evidence e
  where e.project_key=p_project_key
    and e.task_key=p_task_key
    and e.verified=true
    and e.status='pass';
$$;


--
-- Name: contentflow_verify_evidence_uri(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_verify_evidence_uri(p_storage_uri text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_id bigint;
  v_expected_hash text;
  v_row public.contentflow_runtime_evidence_ledger%rowtype;
  v_actual_hash text;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;
  if coalesce(trim(p_storage_uri),'')='' then raise exception 'storage_uri_required'; end if;
  if p_storage_uri !~ '^supabase://contentflow_runtime_evidence_ledger/[0-9]+\?sha256=[a-f0-9]{64}$' then raise exception 'invalid_storage_uri'; end if;
  v_id:=substring(p_storage_uri from 'ledger/([0-9]+)\?')::bigint;
  v_expected_hash:=substring(p_storage_uri from 'sha256=([a-f0-9]{64})$');
  select * into v_row from public.contentflow_runtime_evidence_ledger where id=v_id;
  if not found then return jsonb_build_object('ok',false,'verified',false,'reason','evidence_not_found','evidence_id',v_id); end if;
  v_actual_hash:=encode(extensions.digest(convert_to(v_row.payload::text,'UTF8'),'sha256'::text),'hex');
  return jsonb_build_object(
    'ok',true,
    'verified',(v_actual_hash=v_expected_hash and v_row.payload_sha256=v_expected_hash),
    'evidence_id',v_id,
    'builder_run_id',v_row.builder_run_id,
    'task_key',v_row.task_key,
    'producer',v_row.producer,
    'observed_at',v_row.observed_at,
    'expected_sha256',v_expected_hash,
    'stored_sha256',v_row.payload_sha256,
    'actual_sha256',v_actual_hash,
    'payload',v_row.payload
  );
end $_$;


--
-- Name: contentflow_verify_persistent_change_v1(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contentflow_verify_persistent_change_v1(p_change_id uuid, p_evidence_id text, p_evidence jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_status text;
begin
 select status into v_status from public.contentflow_persistent_change_provenance where change_id=p_change_id for update;
 if not found then raise exception 'persistent_change_not_found'; end if;
 if v_status<>'applied' then raise exception 'persistent_change_not_verifiable:%',v_status; end if;
 if coalesce(nullif(p_evidence_id,''),'')='' then raise exception 'verification_evidence_required'; end if;
 update public.contentflow_persistent_change_provenance set status='verified',evidence_id=p_evidence_id,evidence=coalesce(evidence,'{}'::jsonb)||coalesce(p_evidence,'{}'::jsonb),verified_at=now(),updated_at=now() where change_id=p_change_id;
 return jsonb_build_object('verified',true,'change_id',p_change_id,'evidence_id',p_evidence_id);
end $$;


--
-- Name: director_recovery_finalize_canary(text, text, text, boolean, text, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.director_recovery_finalize_canary(p_project_key text, p_fingerprint text, p_repair_id text, p_pass boolean, p_evidence_id text DEFAULT NULL::text, p_quality numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare m public.director_recovery_learning_memory%rowtype; next_attempts integer; begin select * into m from public.director_recovery_learning_memory where project_key=p_project_key and incident_fingerprint=p_fingerprint and repair_id=p_repair_id and enabled=true for update; if not found then return jsonb_build_object('ok',false,'decision','rollback','reason','memory_not_found'); end if; if m.risk_level in ('high','critical') or m.authority='owner_required' then p_pass:=false; p_reason:=coalesce(p_reason,'authority_or_risk_gate_failed'); end if; if p_pass and coalesce(p_quality,0)>=85 and p_evidence_id is not null then update public.director_recovery_learning_memory set certified_passes=certified_passes+1,reuse_count=reuse_count+1,last_reused_at=now(),updated_at=now(),evidence_ids=array_append(coalesce(evidence_ids,array[]::text[]),p_evidence_id),validation='pass' where id=m.id; update public.director_repair_incidents set status='resolved',resolved_at=now(),updated_at=now(),validation='pass',outcome='canary_validated_and_promoted',executed_action=p_repair_id,requires_human=false where project_key=p_project_key and error_fingerprint=p_fingerprint and status in ('open','analyzing'); insert into public.director_autonomy_events(project_key,event_type,error_fingerprint,source,assignment_mode,outcome,quality_score,started_at,finished_at,resolution_seconds,required_user_intervention,notes) values(p_project_key,'recovery_promoted',p_fingerprint,'recovery_learning_finalize_v1',m.authority,'promoted_after_canary',p_quality,now(),now(),0,false,jsonb_build_object('repair_id',p_repair_id,'evidence_id',p_evidence_id)::text); return jsonb_build_object('ok',true,'decision','promote','repair_id',p_repair_id,'authority',m.authority,'quality',p_quality); else update public.director_recovery_learning_memory set validation='fail',enabled=false,updated_at=now() where id=m.id; update public.director_repair_incidents set status=case when attempts+1>=max_attempts then 'needs_help' else 'analyzing' end,attempts=attempts+1,updated_at=now(),validation='fail',outcome='canary_failed_rollback_required',requires_human=(attempts+1>=max_attempts) where project_key=p_project_key and error_fingerprint=p_fingerprint and status in ('open','analyzing'); insert into public.director_autonomy_events(project_key,event_type,error_fingerprint,source,assignment_mode,outcome,quality_score,started_at,finished_at,resolution_seconds,required_user_intervention,notes) values(p_project_key,'recovery_rollback',p_fingerprint,'recovery_learning_finalize_v1','rollback','canary_failed',p_quality,now(),now(),0,false,jsonb_build_object('repair_id',p_repair_id,'reason',coalesce(p_reason,'validation_failed'),'rollback_evidence_id',m.rollback_evidence_id)::text); return jsonb_build_object('ok',true,'decision','rollback','repair_id',p_repair_id,'rollback_evidence_id',m.rollback_evidence_id,'reason',coalesce(p_reason,'validation_failed')); end if; end $$;


--
-- Name: director_recovery_learning_decision(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.director_recovery_learning_decision(p_project_key text, p_fingerprint text) RETURNS TABLE(decision text, repair_id text, authority text, reason text)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  with candidate as (
    select m.*
    from public.director_recovery_learning_memory m
    where m.project_key = p_project_key
      and m.incident_fingerprint = p_fingerprint
      and m.enabled
      and m.validation = 'pass'
      and m.certified_passes >= 1
    order by m.certified_passes desc, m.reuse_count desc, m.updated_at desc
    limit 1
  )
  select
    case
      when c.id is null then 'deny'
      when c.risk_level = 'low' and c.authority = 'rara_autonomous' then 'admit_canary'
      when c.risk_level = 'medium' and c.authority = 'canary_then_director' and c.rollback_evidence_id is not null then 'admit_canary'
      else 'escalate_owner'
    end,
    c.repair_id,
    c.authority,
    case
      when c.id is null then 'no_exact_certified_repair'
      when c.risk_level in ('high','critical') or c.authority = 'owner_required' then 'owner_required_by_authority_envelope'
      when c.risk_level = 'medium' and c.rollback_evidence_id is null then 'rollback_evidence_required'
      else 'exact_certified_repair_admitted_for_canary'
    end
  from (select 1) seed left join candidate c on true;
$$;


--
-- Name: director_recovery_learning_decision(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.director_recovery_learning_decision(p_project_key text, p_fingerprint text, p_context_version text DEFAULT NULL::text) RETURNS TABLE(decision text, repair_id text, authority text, reason text)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$ with candidate as (select m.* from public.director_recovery_learning_memory m where m.project_key=p_project_key and (m.incident_fingerprint=p_fingerprint or m.canonical_fingerprint=p_fingerprint or m.legacy_fingerprint=p_fingerprint) and m.enabled and m.validation='pass' and m.certified_passes>=1 order by m.certified_passes desc,m.reuse_count desc,m.updated_at desc limit 1) select case when c.id is null then 'deny' when c.recertification_required then 'deny' when p_context_version is not null and c.context_version is distinct from p_context_version then 'deny' when c.risk_level='low' and c.authority='rara_autonomous' then 'admit_canary' when c.risk_level='medium' and c.authority='canary_then_director' and c.rollback_evidence_id is not null then 'admit_canary' else 'escalate_owner' end,c.repair_id,c.authority,case when c.id is null then 'no_exact_certified_repair' when c.recertification_required then 'recertification_required' when p_context_version is not null and c.context_version is distinct from p_context_version then 'context_version_drift' when c.risk_level in ('high','critical') or c.authority='owner_required' then 'owner_required_by_authority_envelope' when c.risk_level='medium' and c.rollback_evidence_id is null then 'rollback_evidence_required' else 'exact_certified_repair_admitted_for_canary' end from (select 1) seed left join candidate c on true; $$;


--
-- Name: enforce_backlog_review_gate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_backlog_review_gate() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_run_id bigint;
  v_browser_passes integer;
begin
  if new.status='completed'
     and old.status is distinct from 'completed'
     and coalesce(new.epic,'')<>'evidence_capability'
     and public.contentflow_requires_runtime_evidence(new.task_type,new.title,new.description,new.acceptance_criteria)
     and not coalesce(new.runtime_verified,false) then
    new.status := 'verification_required';
    new.completion_phase := 'verification_required';
    new.updated_at := now();
    return new;
  end if;

  if new.task_type='code' and new.status='completed' and old.status is distinct from 'completed' then
    if coalesce(new.epic,'')='evidence_capability' then
      new.completion_phase:='artifact_approved';
      return new;
    end if;

    select count(distinct lower(e.engine)) into v_browser_passes
    from public.director_external_evidence e
    where e.project_key=new.project_key
      and e.task_key=new.task_key
      and e.evidence_type='browser_matrix'
      and e.environment='github_actions_ci'
      and e.verified=true
      and e.status='pass'
      and lower(e.engine) in ('chromium','firefox','webkit');

    if coalesce(v_browser_passes,0)=3 then return new; end if;

    select r.id into v_run_id
    from public.contentflow_builder_runs r
    where r.backlog_task_id=new.id
      and r.quality_score >= 85
      and r.result is not null
      and (r.status='review_required' or (r.status='completed' and coalesce(r.review_approved,false)=true))
    order by r.created_at desc,r.id desc limit 1;

    if v_run_id is null then
      new.status := 'blocked';
      new.updated_at := now();
      return new;
    end if;

    update public.contentflow_builder_runs
    set review_approved=true,status='completed',finished_at=coalesce(finished_at,now())
    where id=v_run_id;
  end if;
  return new;
end
$$;


--
-- Name: enforce_builder_review_before_complete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_builder_review_before_complete() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.task_type = 'code' and new.status = 'completed' and coalesce(new.review_approved,false) = false then
    raise exception 'review_required_before_code_completion';
  end if;
  return new;
end;
$$;


--
-- Name: internal_builder_approve_review(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.internal_builder_approve_review(p_builder_run_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_task_id bigint;
  v_type text;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'service_role_required';
  end if;

  select backlog_task_id, task_type into v_task_id, v_type
  from public.contentflow_builder_runs
  where id=p_builder_run_id
  for update;

  if not found then raise exception 'builder_run_not_found'; end if;

  update public.contentflow_builder_runs
  set review_approved=true,
      status='completed',
      finished_at=coalesce(finished_at,now())
  where id=p_builder_run_id;

  update public.contentflow_build_backlog
  set status='completed', updated_at=now()
  where id=v_task_id;

  return true;
end;
$$;


--
-- Name: FUNCTION internal_builder_approve_review(p_builder_run_id bigint); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.internal_builder_approve_review(p_builder_run_id bigint) IS 'LEGACY_QUARANTINED: canonical review path is RARA v2 claim + rara_apply_review_decision_v2';


--
-- Name: internal_builder_assert_deployable(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.internal_builder_assert_deployable(p_builder_run_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_status text;
  v_review boolean;
  v_type text;
begin
  select status, review_approved, task_type
    into v_status, v_review, v_type
  from public.contentflow_builder_runs
  where id = p_builder_run_id;
  if not found then raise exception 'builder_run_not_found'; end if;
  if v_type = 'code' and (v_status <> 'completed' or coalesce(v_review,false) = false) then
    raise exception 'deploy_blocked_review_required';
  end if;
  if v_status <> 'completed' then raise exception 'deploy_blocked_run_not_completed'; end if;
  return true;
end;
$$;


--
-- Name: internal_builder_claim_next_task(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.internal_builder_claim_next_task(p_project_key text DEFAULT 'contentflow'::text) RETURNS TABLE(id bigint, task_key text, title text, description text, task_type text, stage integer, priority integer, depends_on text[], acceptance_criteria text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'service_role_required';
  end if;
  if p_project_key not in ('contentflow','agent-academy-platform-v1') then
    raise exception 'builder_project_not_allowed';
  end if;
  return query
  with candidate as (
    select b1.id
    from public.contentflow_build_backlog b1
    where b1.project_key=p_project_key
      and b1.status in ('planned','ready')
      and coalesce(b1.execution_lane,'llm_artifact') = 'llm_artifact'
      and b1.task_key not like 'gap_gap_%'
      and (b1.next_eligible_at is null or b1.next_eligible_at <= now())
      and not exists (
        select 1 from public.contentflow_retry_state rs
        where rs.backlog_task_id=b1.id and rs.circuit_state='open'
      )
      and not exists (
        select 1
        from jsonb_array_elements_text(coalesce(b1.depends_on,'[]'::jsonb)) dep(value)
        where not exists (
          select 1 from public.contentflow_build_backlog d
          where d.project_key=b1.project_key and d.task_key=dep.value and d.status='completed'
        )
      )
    order by b1.stage asc,b1.priority desc,b1.id asc
    for update skip locked
    limit 1
  ), claimed as (
    update public.contentflow_build_backlog b2
    set status='running',updated_at=now()
    from candidate c
    where b2.id=c.id
    returning b2.*
  )
  select c2.id,c2.task_key,c2.title,c2.description,c2.task_type,c2.stage,c2.priority,
         array(select jsonb_array_elements_text(coalesce(c2.depends_on,'[]'::jsonb))),c2.acceptance_criteria
  from claimed c2;
end
$$;


--
-- Name: internal_builder_collect(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.internal_builder_collect(p_request_id bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_d public.contentflow_builder_dispatches%rowtype;
  v_r net._http_response%rowtype;
  v_j jsonb;
  v_run public.contentflow_builder_runs%rowtype;
  v_ok boolean; v_quality numeric; v_cost numeric; v_model text; v_result text; v_final text;
begin
  select * into v_d from public.contentflow_builder_dispatches where request_id=p_request_id for update;
  if not found then return 'dispatch_not_found'; end if;
  if v_d.status<>'pending' then return v_d.status; end if;
  select * into v_r from net._http_response where id=p_request_id;
  if not found then return 'pending'; end if;
  select * into v_run from public.contentflow_builder_runs where id=v_d.builder_run_id for update;
  if not found then
    update public.contentflow_builder_dispatches set status='failed',collected_at=now(),error='run_missing' where request_id=p_request_id;
    return 'run_missing';
  end if;
  if v_run.lease_revoked_at is not null or exists(select 1 from public.contentflow_builder_runs n where n.backlog_task_id=v_run.backlog_task_id and n.id>v_run.id) then
    update public.contentflow_builder_dispatches set status='superseded',collected_at=now(),http_status=v_r.status_code,error='fenced_out_late_response' where request_id=p_request_id;
    insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
    values(v_run.id,v_run.task_key,'late_response_fenced',v_run.idempotency_key,'collector',jsonb_build_object('request_id',p_request_id)) on conflict do nothing;
    return 'superseded';
  end if;
  if v_r.timed_out or v_r.error_msg is not null then
    update public.contentflow_builder_runs set status='failed',error=coalesce(v_r.error_msg,'http_timeout'),finished_at=now(),lease_revoked_at=now() where id=v_run.id;
    update public.contentflow_build_backlog set status='failed',updated_at=now() where id=v_d.backlog_task_id and status='running' and selected_model is not distinct from v_run.selected_model;
    update public.contentflow_builder_dispatches set status='failed',collected_at=now(),http_status=v_r.status_code,error=coalesce(v_r.error_msg,'http_timeout') where request_id=p_request_id;
    update public.director_worker_queue set status='ready',current_task_key=null,last_task_key=v_run.task_key,last_outcome='failed',last_quality_score=0,last_finished_at=now(),total_failures=total_failures+1,updated_at=now() where model_id=v_run.selected_model and current_task_key is not distinct from v_run.task_key;
    return 'failed';
  end if;
  begin v_j:=v_r.content::jsonb; exception when others then v_j:='{}'::jsonb; end;

  -- Any authenticated async executor acknowledgement is not the task result.
  if coalesce((v_j->>'accepted')::boolean,false)=true and v_r.status_code between 200 and 299 then
    update public.contentflow_builder_dispatches set status='collected',collected_at=now(),http_status=v_r.status_code,error=null where request_id=p_request_id;
    insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
    values(v_run.id,v_run.task_key,'async_dispatch_ack_collected',v_run.idempotency_key,'collector',jsonb_build_object('request_id',p_request_id,'http_status',v_r.status_code,'architecture',coalesce(v_j->>'architecture','unknown'))) on conflict do nothing;
    return 'async_accepted';
  end if;

  v_ok:=coalesce((v_j->>'ok')::boolean,false);
  v_quality:=coalesce((v_j->>'quality_score')::numeric,0);
  v_cost:=coalesce((v_j->>'cost_usd')::numeric,0);
  v_model:=nullif(v_j->>'selected_model','');
  v_result:=nullif(v_j->>'result','');
  if v_cost<0 or v_cost>0.05 then v_ok:=false; end if;
  if not v_ok or v_quality<80 then v_final:='failed'; elsif v_run.task_type='code' then v_final:='review_required'; else v_final:='completed'; end if;
  update public.contentflow_builder_runs set status=v_final,selected_model=coalesce(v_model,v_run.selected_model),quality_score=v_quality,cost_usd=least(greatest(v_cost,0),0.05),result=v_result,error=case when v_final='failed' then coalesce(v_j->>'quality_reason',v_j->>'error','quality_or_cost_gate_failed') else null end,review_approved=false,finished_at=case when v_final in ('completed','failed') then now() else null end,lease_revoked_at=case when v_final in ('completed','failed') then now() else lease_revoked_at end where id=v_run.id;
  update public.contentflow_build_backlog set status=case when v_final='review_required' then 'blocked' else v_final end,selected_model=coalesce(v_model,v_run.selected_model),quality_score=v_quality,cost_usd=least(greatest(v_cost,0),0.05),result=v_result,updated_at=now() where id=v_d.backlog_task_id and status='running' and selected_model is not distinct from v_run.selected_model;
  update public.contentflow_builder_dispatches set status='collected',collected_at=now(),http_status=v_r.status_code,error=case when v_final='failed' then coalesce(v_j->>'quality_reason',v_j->>'error') else null end where request_id=p_request_id;
  update public.director_worker_queue set status='ready',current_task_key=null,last_task_key=v_run.task_key,last_outcome=v_final,last_quality_score=v_quality,last_finished_at=now(),total_completions=total_completions+case when v_final in ('completed','review_required') then 1 else 0 end,total_failures=total_failures+case when v_final='failed' then 1 else 0 end,updated_at=now() where model_id=v_run.selected_model and current_task_key is not distinct from v_run.task_key;
  return v_final;
end
$$;


--
-- Name: internal_builder_dispatch(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.internal_builder_dispatch() RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$
declare
 v_task public.contentflow_build_backlog%rowtype;
 v_run_id bigint; v_secret text; v_req bigint; v_token text:=gen_random_uuid()::text;
 v_anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtvcXB5ZnZucHJtaXJxdmlhZnpxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY0OTg2NDksImV4cCI6MjEwMjA3NDY0OX0.eLlFkA9u_ZxPDXIPAp3tC31RLqGCKqNS7B9kYz7BfbI';
 v_prompt text; v_dep_context text; v_runtime_context text; v_worker text; v_reviewer text;
begin
 select q.model_id into v_worker
 from public.director_worker_queue q
 where q.status='ready'
   and not exists(select 1 from public.contentflow_builder_runs ar where ar.selected_model=q.model_id and ar.status in ('claimed','running') and ar.finished_at is null)
   and not exists(select 1 from public.contentflow_nexo_request_metrics m where m.model=q.model_id and m.created_at>now()-interval '15 minutes' and m.status_code=404)
 order by ((q.total_completions+1.0)/(q.total_assignments+2.0)) desc,q.last_quality_score desc nulls last,q.updated_at asc
 for update skip locked limit 1;
 if v_worker is null then return null; end if;

 select q.model_id into v_reviewer
 from public.director_worker_queue q
 where q.status='ready' and q.model_id<>v_worker
 order by ((q.total_completions+1.0)/(q.total_assignments+2.0)) desc,q.last_quality_score desc nulls last,q.updated_at asc limit 1;
 if v_reviewer is null then return null; end if;

 select b.* into v_task
 from public.contentflow_build_backlog b
 where b.project_key=coalesce(nullif(current_setting('contentflow.project_key',true),''),'contentflow') and b.status in ('planned','ready')
   and coalesce(b.execution_lane,'llm_artifact')='llm_artifact'
   and b.task_key not like 'gap_gap_%'
   and (b.next_eligible_at is null or b.next_eligible_at<=now())
   and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open')
   and not exists(select 1 from public.contentflow_builder_runs ar where ar.backlog_task_id=b.id and ar.status in ('claimed','running','review_required','verification_required') and ar.finished_at is null)
   and not exists(
     select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
     where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed')
   )
 order by public.contentflow_dependency_impact_score(b.project_key,b.task_key) desc,b.stage asc,b.priority desc,b.id asc
 for update skip locked limit 1;
 if not found then return null; end if;

 if coalesce(v_task.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap') then
   select string_agg(
     format('DEPENDENCY CONTRACT: %s | title=%s | status=%s | quality=%s | IMPORTANT: dependency execution IDs and literal implementation examples are intentionally NOT injected; implement against the abstract contract only.',d.task_key,coalesce(d.title,''),d.status,coalesce(d.quality_score::text,'0')),
     E'\n---\n'
   ) into v_dep_context
   from jsonb_array_elements_text(coalesce(v_task.depends_on,'[]'::jsonb)) dep(value)
   join public.contentflow_build_backlog d on d.project_key=v_task.project_key and d.task_key=dep.value;
 else
   select string_agg(format('DEPENDENCY: %s | title=%s | status=%s | quality=%s\nVERIFIED RESULT:\n%s',d.task_key,coalesce(d.title,''),d.status,coalesce(d.quality_score::text,'0'),left(coalesce(d.result,''),3000)),E'\n---\n') into v_dep_context
   from jsonb_array_elements_text(coalesce(v_task.depends_on,'[]'::jsonb)) dep(value)
   join public.contentflow_build_backlog d on d.project_key=v_task.project_key and d.task_key=dep.value;
 end if;

 if v_task.task_key='autocont_v1_runtime_health' then v_runtime_context:=public.contentflow_runtime_health_snapshot(); else v_runtime_context:='NO_DIRECT_RUNTIME_SNAPSHOT'; end if;

 update public.contentflow_build_backlog
 set status='running',selected_model=v_worker,team='director-core:'||v_worker||'|review:'||v_reviewer,updated_at=now()
 where id=v_task.id and status in ('planned','ready');
 if not found then return null; end if;

 select id into v_run_id from public.contentflow_builder_runs where backlog_task_id=v_task.id and status='claimed' order by id desc limit 1;
 if v_run_id is null then raise exception 'builder_run_missing_after_atomic_claim'; end if;
 update public.contentflow_builder_runs
 set selected_model=v_worker,idempotency_key=coalesce(idempotency_key,'contentflow:'||v_task.task_key||':run:'||v_run_id::text),heartbeat_at=now(),lease_expires_at=now()+interval '3 minutes',lease_token=v_token,lease_generation=lease_generation+1,lease_revoked_at=null,runner_instance_id=null,heartbeat_seq=0,control_protocol='fenced-v2'
 where id=v_run_id;
 insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
 select v_run_id,v_task.task_key,'claimed',idempotency_key,'director_core',jsonb_build_object('worker',v_worker,'reviewer',v_reviewer,'lease_generation',lease_generation,'lease_expires_at',lease_expires_at) from public.contentflow_builder_runs where id=v_run_id on conflict do nothing;
 update public.director_worker_queue set status='running',current_task_key=v_task.task_key,last_started_at=now(),total_assignments=total_assignments+1,updated_at=now() where model_id=v_worker and status='ready';
 if not found then
   update public.contentflow_build_backlog set status='ready',selected_model=null,updated_at=now() where id=v_task.id;
   update public.contentflow_builder_runs set status='deferred',finished_at=now(),error='worker_claim_race_recovered',lease_revoked_at=now() where id=v_run_id;
   return null;
 end if;
 select runner_secret into v_secret from public.contentflow_internal_runner_config where id=1;
 if v_secret is null then raise exception 'runner_secret_missing'; end if;

 if coalesce(v_task.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap') then
   v_prompt:=format('PROYECTO: ContentFlow AI\nTAREA: %s\nDESCRIPCION: %s\nTIPO: %s\nCRITERIO DE ACEPTACION: %s\n\nEXECUTION CORRELATION POLICY: The platform tracks this execution internally. The reusable artifact MUST NOT contain, echo, comment, default, fixture, constant, or hardcode the numeric builder_run_id of this or any previous execution. builder_run_id MUST exist only as a runtime-supplied parameter/input in the reusable contract. Do not infer run IDs from dependency examples.\n\nDEPENDENCIAS VERIFICADAS COMO CONTRATOS:\n%s\n\nProduce el artefacto fuente minimo verificable and reusable. No inventes despliegues, pruebas ejecutadas, credenciales, tablas, policies ni resultados.',v_task.title,coalesce(v_task.description,''),coalesce(v_task.task_type,'general'),coalesce(v_task.acceptance_criteria,''),coalesce(v_dep_context,'NO_DEPENDENCIES'));
 else
   v_prompt:=format('PROYECTO: ContentFlow AI\nTAREA: %s\nDESCRIPCION: %s\nTIPO: %s\nCRITERIO DE ACEPTACION: %s\n\nCONTRATO DE EJECUCION CANONICO: %s | EVIDENCIA EXTERNA VERIFICADA: %s | BUILDER_RUN_ID: %s\nLa evidencia runtime debe estar persistida por la plataforma y correlacionada con este builder_run_id. No inventes UUIDs o eventos en memoria.\n\nEVIDENCIA VERIFICADA DE DEPENDENCIAS:\n%s\n\nSNAPSHOT RUNTIME DETERMINISTA:\n%s\n\nProduce el artefacto minimo verificable usando solo evidencia real. No inventes despliegues, pruebas, credenciales, tablas, policies ni resultados.',v_task.title,coalesce(v_task.description,''),coalesce(v_task.task_type,'general'),coalesce(v_task.acceptance_criteria,''),coalesce(v_task.workflow_contract::text,'{}'),coalesce(public.contentflow_verified_external_evidence_context(v_task.project_key,v_task.task_key),'NO_VERIFIED_EXTERNAL_EVIDENCE'),v_run_id,coalesce(v_dep_context,'NO_DEPENDENCIES'),coalesce(v_runtime_context,'NO_DIRECT_RUNTIME_SNAPSHOT'));
 end if;

 select net.http_post(
   url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-dispatch-executor-v2',
   headers:=jsonb_build_object('Authorization','Bearer '||v_anon,'Content-Type','application/json','X-ContentFlow-Internal',v_secret),
   body:=jsonb_build_object('task_type',coalesce(v_task.task_type,'general'),'task',v_prompt,'model_hint',v_worker,'reviewer_hint',v_reviewer,'claim_task_key',v_task.task_key,'builder_run_id',v_run_id,'lease_token',v_token),
   timeout_milliseconds:=300000
 ) into v_req;
 insert into public.contentflow_builder_dispatches(request_id,builder_run_id,backlog_task_id) values(v_req,v_run_id,v_task.id);
 perform net.wake();
 return v_req;
exception when others then
 if v_worker is not null then update public.director_worker_queue set status='ready',current_task_key=null,updated_at=now() where model_id=v_worker and current_task_key=v_task.task_key; end if;
 raise;
end
$$;


--
-- Name: internal_builder_finalize(bigint, text, text, numeric, numeric, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.internal_builder_finalize(p_builder_run_id bigint, p_status text, p_selected_model text DEFAULT NULL::text, p_quality_score numeric DEFAULT 0, p_cost_usd numeric DEFAULT 0, p_result text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_review_approved boolean DEFAULT false) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare v_run public.contentflow_builder_runs%rowtype; v_final text; begin if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if; select * into v_run from public.contentflow_builder_runs where id=p_builder_run_id for update; if not found then raise exception 'builder_run_not_found'; end if; if p_cost_usd < 0 or p_cost_usd > 0.05 then raise exception 'builder_cost_limit'; end if; if p_status not in ('completed','failed','blocked','deferred','review_required') then raise exception 'invalid_status'; end if; v_final:=p_status; if p_status='completed' and p_quality_score < 80 then raise exception 'quality_gate_failed'; end if; if p_status='completed' and v_run.task_type='code' and not p_review_approved then v_final:='review_required'; end if; update public.contentflow_builder_runs set status=v_final,selected_model=p_selected_model,quality_score=coalesce(p_quality_score,0),cost_usd=coalesce(p_cost_usd,0),result=p_result,error=p_error,review_approved=p_review_approved,finished_at=case when v_final in ('completed','failed','blocked','deferred') then now() else null end where id=p_builder_run_id; update public.contentflow_build_backlog set status=case when v_final='review_required' then 'running' else v_final end,selected_model=p_selected_model,quality_score=coalesce(p_quality_score,0),cost_usd=coalesce(p_cost_usd,0),result=p_result,updated_at=now() where id=v_run.backlog_task_id; return true; end $$;


--
-- Name: FUNCTION internal_builder_finalize(p_builder_run_id bigint, p_status text, p_selected_model text, p_quality_score numeric, p_cost_usd numeric, p_result text, p_error text, p_review_approved boolean); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.internal_builder_finalize(p_builder_run_id bigint, p_status text, p_selected_model text, p_quality_score numeric, p_cost_usd numeric, p_result text, p_error text, p_review_approved boolean) IS 'LEGACY_QUARANTINED: canonical finalization is contentflow_finalize_run_v2 via contentflow-dispatch-executor-v2';


--
-- Name: internal_builder_recover_stale_claims(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.internal_builder_recover_stale_claims(p_minutes integer DEFAULT 60) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ declare v_count integer:=0; begin if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role_required'; end if; if p_minutes < 30 then raise exception 'minimum_stale_window_30_minutes'; end if; with stale as (select r.id,r.backlog_task_id from public.contentflow_builder_runs r join public.contentflow_build_backlog b on b.id=r.backlog_task_id where r.status='claimed' and r.finished_at is null and r.created_at < now() - make_interval(mins=>p_minutes) and b.status='running' for update of r,b), upd_runs as (update public.contentflow_builder_runs r set status='deferred',finished_at=now(),error='stale_claim_recovered' from stale s where r.id=s.id returning r.backlog_task_id), upd_backlog as (update public.contentflow_build_backlog b set status='ready',updated_at=now(),result=coalesce(result,'') || case when coalesce(result,'')='' then '' else E'\n' end || '[builder] stale claim recovered automatically' from upd_runs u where b.id=u.backlog_task_id returning b.id) select count(*) into v_count from upd_backlog; return v_count; end $$;


--
-- Name: FUNCTION internal_builder_recover_stale_claims(p_minutes integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.internal_builder_recover_stale_claims(p_minutes integer) IS 'LEGACY_QUARANTINED: canonical recovery is contentflow_recover_orphan_claims/master reconcile';


--
-- Name: log_contentflow_autonomy_backlog(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_contentflow_autonomy_backlog() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_mode text; v_started timestamptz; v_problem_id bigint;
begin
  v_mode := case
    when coalesce(new.team,'') ~* '^(ranked|auto|director-core|adaptive):|^ranked-v' then 'auto'
    else 'manual'
  end;
  if new.status='running' and old.status is distinct from 'running' then
    insert into director_autonomy_events(project_key,event_type,task_key,source,assignment_mode,assigned_model,outcome,started_at,required_user_intervention,notes)
    values(new.project_key,'task_assigned',new.task_key,'contentflow_build_backlog',v_mode,new.selected_model,'assigned',now(),false,new.team);
  end if;
  if new.status='completed' and old.status is distinct from 'completed' then
    select started_at into v_started from director_autonomy_events where project_key=new.project_key and task_key=new.task_key and event_type='task_assigned' order by id desc limit 1;
    insert into director_autonomy_events(project_key,event_type,task_key,source,assignment_mode,assigned_model,outcome,quality_score,started_at,finished_at,resolution_seconds,required_user_intervention,notes)
    values(new.project_key,'task_completed',new.task_key,'contentflow_build_backlog',v_mode,new.selected_model,'completed',new.quality_score,v_started,now(),case when v_started is null then null else extract(epoch from(now()-v_started)) end,false,new.team);
    select id into v_problem_id from director_autonomy_events where project_key=new.project_key and task_key=new.task_key and event_type='problem_detected' and outcome='open' order by id desc limit 1;
    if v_problem_id is not null then
      select started_at into v_started from director_autonomy_events where id=v_problem_id;
      insert into director_autonomy_events(project_key,event_type,task_key,source,assignment_mode,assigned_model,outcome,quality_score,started_at,finished_at,resolution_seconds,required_user_intervention,notes)
      values(new.project_key,'problem_resolved',new.task_key,'backlog_completion',v_mode,new.selected_model,'resolved',new.quality_score,v_started,now(),case when v_started is null then null else extract(epoch from(now()-v_started)) end,false,'Resolved by subsequent successful task completion');
      update director_autonomy_events set outcome='closed' where id=v_problem_id;
    end if;
  end if;
  return new;
end
$$;


--
-- Name: log_contentflow_problem_from_run(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_contentflow_problem_from_run() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare fp text;
begin
  if new.status='failed' and (old.status is distinct from 'failed') then
    fp := lower(regexp_replace(coalesce(new.error,'unknown_error'),'[^a-zA-Z0-9:_-]+','_','g'));
    insert into director_autonomy_events(project_key,event_type,task_key,error_fingerprint,source,assignment_mode,assigned_model,outcome,quality_score,started_at,finished_at,required_user_intervention,notes)
    values(coalesce(new.project_key,'contentflow'),'problem_detected',new.task_key,left(fp,180),'contentflow_builder_runs','auto',new.selected_model,'open',new.quality_score,new.created_at,new.finished_at,false,new.error);
  end if;
  return new;
end $$;


--
-- Name: rara_apply_known_repair(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_apply_known_repair(p_incident_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare i public.director_repair_incidents%rowtype; r public.director_repair_recipes%rowtype; ok boolean:=false; detail jsonb:='{}'::jsonb; s integer:=0; v_resolved_status text:='resolved';
begin
 select * into i from public.director_repair_incidents where id=p_incident_id for update;
 if not found or i.status not in ('open','analyzing') then return jsonb_build_object('applied',false,'reason','incident_not_actionable'); end if;
 select * into r from public.director_repair_recipes x where x.project_key=i.project_key and x.enabled=true and x.risk_level='low' and x.confidence>=x.min_confidence and x.failures<x.max_consecutive_failures and (x.error_class is null or x.error_class=i.error_class) and (x.component is null or x.component=i.component) and (x.fingerprint_prefix is null or i.error_fingerprint like x.fingerprint_prefix||'%') order by (case when x.fingerprint_prefix is not null then 3 else 0 end + case when x.error_class is not null then 2 else 0 end + case when x.component is not null then 1 else 0 end) desc,x.confidence desc limit 1;
 if not found then
   update public.director_repair_incidents set attempts=attempts+1,status=case when attempts+1>=max_attempts then 'needs_help' else 'open' end,requires_human=(attempts+1>=max_attempts),updated_at=now(),outcome='no_known_recipe' where id=i.id;
   return jsonb_build_object('applied',false,'reason','no_known_recipe','escalated',i.attempts+1>=i.max_attempts);
 end if;
 update public.director_repair_incidents set status='repairing',attempts=attempts+1,proposed_action=r.action_type,updated_at=now() where id=i.id;
 if r.action_type='collect_dispatches' then s:=public.rara_safe_collect_ready_dispatches(); ok:=true; detail:=jsonb_build_object('collected',s);
 elsif r.action_type='transport_recover' then detail:=public.contentflow_transport_recovery_v1(i.project_key); ok:=coalesce(detail->>'skipped','')='' ;
 elsif r.action_type='restart_pg_net' then ok:=public.rara_safe_restart_pg_net_if_stuck(); detail:=jsonb_build_object('restarted',ok);
 elsif r.action_type='requeue_failed_task' and i.task_key is not null then ok:=public.rara_safe_requeue_failed_task(i.task_key); detail:=jsonb_build_object('requeued',ok,'task_key',i.task_key);
 elsif r.action_type='review_gate_reconcile' then detail:=public.contentflow_review_gate_reconcile(i.project_key); ok:=true;
 elsif r.action_type='runtime_state_reconcile' then detail:=public.contentflow_reconcile_runtime_state(i.project_key); ok:=true;
 elsif r.action_type='progress_stall_reconcile' then detail:=public.contentflow_progress_stall_reconcile(i.project_key); ok:=coalesce((detail->>'dispatchable_after')::int,0)>0 or coalesce((detail->>'running')::int,0)>0 or coalesce((detail->>'ready')::int,0)=0;
 else
   update public.director_repair_incidents set status=case when attempts>=max_attempts then 'needs_help' else 'open' end,requires_human=(attempts>=max_attempts),updated_at=now(),outcome='unsupported_recipe_action' where id=i.id;
   return jsonb_build_object('applied',false,'reason','recipe_action_not_supported','action_type',r.action_type);
 end if;
 insert into public.director_repair_actions(incident_id,action_type,action_payload,risk_level,status,result,error) values(i.id,r.action_type,jsonb_build_object('recipe_key',r.recipe_key,'task_key',i.task_key),r.risk_level,case when ok then 'completed' else 'failed' end,detail,case when ok then null else 'known_recipe_validation_failed' end);
 if ok then
   if exists(select 1 from public.director_repair_incidents z where z.id<>i.id and z.project_key=i.project_key and z.error_fingerprint=i.error_fingerprint and z.status='resolved') then v_resolved_status:='resolved_repeat'; end if;
   update public.director_repair_incidents set status=v_resolved_status,resolved_at=now(),updated_at=now(),executed_action=r.action_type,validation=r.validation_type,outcome='resolved_by_known_recipe',requires_human=false where id=i.id and status='repairing';
   update public.director_repair_recipes set successes=successes+1,failures=0,confidence=least(0.99,confidence+0.01),updated_at=now() where id=r.id;
 else
   update public.director_repair_incidents set status=case when attempts>=max_attempts then 'needs_help' else 'open' end,updated_at=now(),executed_action=r.action_type,outcome='known_recipe_failed',requires_human=(attempts>=max_attempts) where id=i.id;
   update public.director_repair_recipes set failures=failures+1,confidence=greatest(0.10,confidence-0.10),enabled=case when failures+1>=max_consecutive_failures then false else enabled end,updated_at=now() where id=r.id;
 end if;
 return jsonb_build_object('applied',true,'ok',ok,'recipe_key',r.recipe_key,'action_type',r.action_type,'detail',detail,'resolution_status',v_resolved_status);
end $$;


--
-- Name: rara_apply_known_repairs(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_apply_known_repairs(p_project_key text DEFAULT 'contentflow'::text, p_limit integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare x record; a jsonb; n int:=0; fixed int:=0; escalated int:=0; changed_strategy int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 update public.director_repair_incidents set status='needs_help',requires_human=true,updated_at=now(),outcome=case when coalesce(outcome,'') like '%attempt_budget_exhausted%' then outcome else coalesce(outcome,'')||case when coalesce(outcome,'')='' then '' else '|' end||'attempt_budget_exhausted' end
 where project_key=p_project_key and status in ('open','analyzing','repairing','validating') and attempts>=max_attempts and error_class not in ('autonomy_no_progress','progress_stall','zero_throughput_semantic_deadlock');
 get diagnostics escalated=row_count;
 for x in select id,error_class from public.director_repair_incidents where project_key=p_project_key and status in ('open','analyzing') and requires_human=false order by case when error_class in ('autonomy_no_progress','progress_stall','zero_throughput_semantic_deadlock') then 0 else 1 end,created_at asc limit greatest(1,least(p_limit,50)) loop
   if x.error_class in ('autonomy_no_progress','progress_stall','zero_throughput_semantic_deadlock') then a:=public.contentflow_apply_control_incident_strategy(x.id); changed_strategy:=changed_strategy+1;
   else a:=public.rara_apply_known_repair(x.id); end if;
   n:=n+1; if coalesce((a->>'ok')::boolean,false) then fixed:=fixed+1; end if;
 end loop;
 return jsonb_build_object('architecture','CONTROL_INCIDENT_RETRY_POLICY_V1','examined',n,'repaired',fixed,'control_strategies_attempted',changed_strategy,'attempt_budget_escalated',escalated);
end $$;


--
-- Name: rara_apply_review_decision(bigint, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_apply_review_decision(p_builder_run_id bigint, p_approve boolean, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; b public.contentflow_build_backlog%rowtype; ev_claimed int; ev_started int; ev_artifact int; ev_judge int; ev_done int; judge_pass boolean:=false; done_pass boolean:=false; deps_complete boolean:=true; reject_status text:='ready';
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 select * into r from public.contentflow_builder_runs where id=p_builder_run_id for update; if not found then raise exception 'builder_run_not_found'; end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update;
 if r.status<>'review_required' then return jsonb_build_object('ok',false,'reason','not_review_required','run_status',r.status); end if;
 select count(*) filter(where event_type='claimed'),
        count(*) filter(where event_type='runner_started' or (event_type like 'runner\_%\_started' escape '\')),
        count(*) filter(where event_type='artifact_generated'),
        count(*) filter(where event_type='judge_completed'),
        count(*) filter(where event_type='runner_completed'),
        coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='judge_completed'),false),
        coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='runner_completed'),false)
 into ev_claimed,ev_started,ev_artifact,ev_judge,ev_done,judge_pass,done_pass
 from public.contentflow_runtime_event_ledger where builder_run_id=p_builder_run_id;
 select not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed')) into deps_complete;
 if p_approve then
  if coalesce(r.quality_score,0)<85 or r.result is null or length(trim(r.result))<40 or ev_claimed=0 or ev_started=0 or ev_artifact=0 or ev_judge=0 or ev_done=0 or not judge_pass or not done_pass then
   return jsonb_build_object('ok',false,'reason','deterministic_stage_gate_failed','quality',r.quality_score,'events',jsonb_build_object('claimed',ev_claimed,'started',ev_started,'artifact',ev_artifact,'judge',ev_judge,'done',ev_done,'judge_pass',judge_pass,'done_pass',done_pass));
  end if;
  update public.contentflow_builder_runs set review_approved=true,status='completed',finished_at=coalesce(finished_at,now()),error=null where id=p_builder_run_id;
  update public.contentflow_build_backlog set status='completed',quality_score=r.quality_score,result=r.result,selected_model=r.selected_model,artifact_version=artifact_version+1,workflow_state='completed',patch_feedback=null,completion_phase='artifact_approved',updated_at=now() where id=b.id;
  perform public.contentflow_checkpoint_stage(b.id,'review','completed',null,null,jsonb_build_object('run_id',r.id,'quality_score',r.quality_score));
  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at) values(b.project_key,'rara_review_approved','rara','durable_stage_v2','completed',false,format('run=%s task=%s',p_builder_run_id,b.task_key),now());
  return jsonb_build_object('ok',true,'decision','approved','task_key',b.task_key,'run_id',p_builder_run_id);
 else
  reject_status:=case when deps_complete then 'ready' else 'planned' end;
  update public.contentflow_builder_runs set status='failed',finished_at=now(),review_approved=false,error='RARA_ARTIFACT_REVIEW_REJECTED: '||left(coalesce(p_reason,'artifact defect'),1600) where id=p_builder_run_id;
  update public.contentflow_build_backlog set status=reject_status,selected_model=null,quality_score=r.quality_score,result=coalesce(r.result,result),workflow_state='patch_required',patch_feedback=left(coalesce(p_reason,'Artifact requires localized patch.'),5000),next_eligible_at=case when reject_status='ready' then now() else next_eligible_at end,blocked_reason=null,updated_at=now() where id=b.id;
  perform public.contentflow_checkpoint_stage(b.id,'review','rejected','artifact_defect',p_reason,jsonb_build_object('run_id',r.id,'preserved_artifact',true,'target_state','patch_required'));
  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at) values(b.project_key,'rara_review_rejected','rara','durable_stage_v2','patch_required',false,format('run=%s task=%s state=%s',p_builder_run_id,b.task_key,reject_status),now());
  return jsonb_build_object('ok',true,'decision','rejected_patch_required','task_key',b.task_key,'run_id',p_builder_run_id,'target_status',reject_status);
 end if;
end $$;


--
-- Name: FUNCTION rara_apply_review_decision(p_builder_run_id bigint, p_approve boolean, p_reason text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.rara_apply_review_decision(p_builder_run_id bigint, p_approve boolean, p_reason text) IS 'LEGACY_QUARANTINED: canonical review decision is rara_apply_review_decision_v2';


--
-- Name: rara_apply_review_decision_v2(bigint, text, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_apply_review_decision_v2(p_builder_run_id bigint, p_claim_token text, p_approve boolean, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  q public.contentflow_review_work_queue%rowtype;
  d jsonb;
  l jsonb;
  b public.contentflow_build_backlog%rowtype;
  effective_approve boolean := p_approve;
  normalized_reason text := coalesce(p_reason,'');
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
  if not effective_approve
     and normalized_reason ilike '%class=NONE%'
     and normalized_reason ilike '%action=COMPLETE%'
     and normalized_reason ilike '%missing=[]%'
     and normalized_reason ilike '%gate=false%'
     and normalized_reason ilike '%contract={}%'
  then
    effective_approve := true;
  end if;
  select * into q from public.contentflow_review_work_queue where builder_run_id=p_builder_run_id for update;
  if not found then return jsonb_build_object('ok',false,'reason','review_claim_not_found'); end if;
  if q.state<>'claimed' or q.claim_token is distinct from p_claim_token then return jsonb_build_object('ok',false,'reason','review_claim_fenced'); end if;
  d:=public.rara_apply_review_decision(p_builder_run_id,effective_approve,normalized_reason);
  if coalesce((d->>'ok')::boolean,false)=false and effective_approve and d->>'reason' in ('deterministic_evidence_gate_failed','deterministic_stage_gate_failed') then
    d:=public.rara_apply_review_decision(p_builder_run_id,false,'Deterministic stage gate failed at commit: '||normalized_reason);
  end if;
  if coalesce((d->>'ok')::boolean,false)=false then
    update public.contentflow_review_work_queue set state='pending',claim_token=null,claimed_at=null,available_at=now()+interval '60 seconds',last_error=left(coalesce(d->>'reason','decision_failed'),1000),updated_at=now() where builder_run_id=p_builder_run_id and state='claimed' and claim_token=p_claim_token;
    return d;
  end if;
  update public.contentflow_review_work_queue set state='done',claim_token=null,claimed_at=null,updated_at=now() where builder_run_id=p_builder_run_id and claim_token=p_claim_token;
  if coalesce(d->>'decision','') in ('rejected_patch_required','rejected_requeued') then
    l:=public.rara_learn_and_replan_rejection(p_builder_run_id,normalized_reason); d:=d||jsonb_build_object('learning',l);
    if coalesce(l->>'action','')='owner_required' then
      select b2.* into b from public.contentflow_build_backlog b2 join public.contentflow_builder_runs r on r.backlog_task_id=b2.id where r.id=p_builder_run_id;
      update public.contentflow_build_backlog set status='blocked',blocked_reason='OWNER_REQUIRED',workflow_state='external_approval_wait',selected_model=null,next_eligible_at=null,updated_at=now() where id=b.id;
      insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,status,risk_level,requires_human,diagnosis,root_cause,proposed_action) values(b.project_key,'rara_review','owner_required','rara_owner_required_v2',left(normalized_reason,1000),'needs_help','high',true,'Explicit workflow contract requires owner authority','True non-autonomous authority boundary','Request explicit owner/counsel approval') on conflict do nothing;
    end if;
  end if;
  return d;
end
$$;


--
-- Name: rara_claim_next_incident(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_claim_next_incident(p_project_key text DEFAULT 'contentflow'::text) RETURNS TABLE(id bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 return query
 with c as (
   select i.id from public.director_repair_incidents i
   left join public.director_control_incident_strategy_state s on s.incident_id=i.id
   where i.project_key=p_project_key and i.status='open'
     and not (i.error_class in ('autonomy_no_progress','progress_stall','zero_throughput_semantic_deadlock','no_progress_with_pending_work') and coalesce(s.exhausted,false))
   order by case when i.error_class in ('autonomy_no_progress','progress_stall','zero_throughput_semantic_deadlock','no_progress_with_pending_work') then 0 else 1 end,i.created_at asc
   for update of i skip locked limit 1
 )
 update public.director_repair_incidents x
 set status='analyzing',attempts=case when x.error_class in ('autonomy_no_progress','progress_stall','zero_throughput_semantic_deadlock','no_progress_with_pending_work') then x.attempts else x.attempts+1 end,updated_at=now()
 from c where x.id=c.id returning x.id;
end $$;


--
-- Name: rara_claim_review_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_claim_review_v1() RETURNS TABLE(out_builder_run_id bigint, out_task_key text, out_claim_token text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_id bigint;
  v_task text;
  v_token text:=gen_random_uuid()::text;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;

  update public.contentflow_review_work_queue q
  set state='pending',claim_token=null,claimed_at=null,available_at=now(),
      last_error='stale_review_claim_recovered_fairness_v5',updated_at=now()
  where q.state='claimed' and q.claimed_at<now()-interval '3 minutes'
    and exists(select 1 from public.contentflow_builder_runs r where r.id=q.builder_run_id and r.status='review_required');

  select q.builder_run_id,q.task_key into v_id,v_task
  from public.contentflow_review_work_queue q
  join public.contentflow_builder_runs r on r.id=q.builder_run_id
  join public.contentflow_build_backlog b on b.id=r.backlog_task_id
  where q.state='pending' and q.available_at<=now() and r.status='review_required'
  order by
    q.attempts asc,
    q.available_at asc,
    coalesce(b.priority,0) desc,
    q.builder_run_id asc
  for update of q skip locked limit 1;

  if v_id is null then return; end if;
  update public.contentflow_review_work_queue q
  set state='claimed',claim_token=v_token,claimed_at=now(),attempts=q.attempts+1,updated_at=now()
  where q.builder_run_id=v_id and q.state='pending';
  if not found then return; end if;
  return query select v_id,v_task,v_token;
end
$$;


--
-- Name: rara_claim_review_v2(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_claim_review_v2(p_project_key text DEFAULT NULL::text) RETURNS TABLE(out_builder_run_id bigint, out_task_key text, out_claim_token text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_id bigint; v_task text; v_token text:=gen_random_uuid()::text;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 update public.contentflow_review_work_queue q
 set state='pending',claim_token=null,claimed_at=null,available_at=now(),last_error='stale_review_claim_recovered_v2',updated_at=now()
 where q.state='claimed' and q.claimed_at<now()-interval '3 minutes'
   and exists(select 1 from public.contentflow_builder_runs r where r.id=q.builder_run_id and r.status='review_required');
 select q.builder_run_id,q.task_key into v_id,v_task
 from public.contentflow_review_work_queue q
 join public.contentflow_builder_runs r on r.id=q.builder_run_id
 where q.state='pending' and q.available_at<=now() and r.status='review_required'
   and (p_project_key is null or r.project_key=p_project_key)
 order by q.updated_at,q.builder_run_id
 for update of q skip locked limit 1;
 if v_id is null then return; end if;
 update public.contentflow_review_work_queue q
 set state='claimed',claim_token=v_token,claimed_at=now(),attempts=q.attempts+1,updated_at=now()
 where q.builder_run_id=v_id and q.state='pending';
 if not found then return; end if;
 return query select v_id,v_task,v_token;
end $$;


--
-- Name: rara_classify_rejection(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_classify_rejection(p_reason text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
with x as (select lower(coalesce(p_reason,'')) s)
select case
  when s like '%legal%' or s like '%counsel%' or s like '%consent%' or s like '%biometric%' or s like '%privacy%' or s like '%purchase%' or s like '%cost authorization%' or s like '%gpu rental%' or s like '%production deploy%' or s like '%irreversible%' or s like '%owner approval%' then 'owner_required'
  when s like '%vendor claim%' or s like '%benchmark result%' or s like '%independent verification%' or s like '%unverified hardware%' or s like '%unverified latency%' or s like '%route a%' or s like '%route b%' or s like '%route c%' or s like '%mapping%a/b/c%' then 'vendor_claim_not_benchmark'
  when (s like '%hardcod%' and (s like '%builder%' or s like '%execution%' or s like '%correlation%' or s like '%run id%' or s like '%run_id%')) or s like '%builder_run_id%' or s like '%run-specific%' then 'hardcoded_execution_identity'
  when s like '%placeholder%' or s like '%stub%' or s like '%scaffold%' or s like '%empty json%' or s like '%empty object%' then 'placeholder_or_stub'
  when s like '%missing evidence%' or s like '%evidence%insufficient%' or s like '%runtime proof%' or s like '%persisted evidence%' or s like '%acceptance criterion%' or s like '%verification%' then 'acceptance_evidence'
  when s like '%contract%' or s like '%interface%' or s like '%integration%not%verified%' or s like '%incomplete%' then 'contract_incomplete'
  else 'correctable_quality'
end from x
$$;


--
-- Name: rara_detect_incidents(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_detect_incidents(p_project_key text DEFAULT 'contentflow'::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$
declare v_n integer:=0; v_x integer:=0;
begin
  insert into public.director_repair_incidents(project_key,task_key,component,error_class,error_fingerprint,symptom,evidence,risk_level)
  select p_project_key,b.task_key,'builder',public.contentflow_classify_run_error(r.error),public.contentflow_classify_run_error(r.error)||':'||b.task_key,coalesce(r.error,'builder task failed'),jsonb_build_object('backlog_status',b.status,'quality_score',b.quality_score,'run_id',r.id,'run_status',r.status,'selected_model',r.selected_model,'error',r.error),'low'
  from public.contentflow_build_backlog b
  join lateral (select * from public.contentflow_builder_runs x where x.backlog_task_id=b.id order by x.id desc limit 1) r on true
  where b.project_key=p_project_key and b.status='failed' and b.task_key not like 'gap_gap_%'
    and not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint=public.contentflow_classify_run_error(r.error)||':'||b.task_key and i.status in ('open','analyzing','repairing','validating','needs_help'))
  on conflict do nothing;
  get diagnostics v_x=row_count; v_n:=v_n+v_x;

  insert into public.director_repair_incidents(project_key,task_key,component,error_class,error_fingerprint,symptom,evidence,risk_level)
  select p_project_key,b.task_key,'dispatcher','stale_dispatch','stale_dispatch:'||d.request_id::text,'dispatch truly pending beyond transport/activity deadline',jsonb_build_object('request_id',d.request_id,'created_at',d.created_at,'builder_run_id',d.builder_run_id,'backlog_task_id',d.backlog_task_id),'low'
  from public.contentflow_builder_dispatches d
  join public.contentflow_build_backlog b on b.id=d.backlog_task_id and b.project_key=p_project_key
  join public.contentflow_builder_runs r on r.id=d.builder_run_id
  where d.status='pending' and d.created_at<now()-interval '8 minutes'
    and not exists(select 1 from net._http_response h where h.id=d.request_id)
    and (r.status not in ('claimed','running') or r.finished_at is not null or r.lease_revoked_at is not null
         or ((r.activity_deadline_at is null or r.activity_deadline_at<=now()) and (r.heartbeat_deadline_at is null or r.heartbeat_deadline_at<=now())))
    and not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='stale_dispatch:'||d.request_id::text and i.status in ('open','analyzing','repairing','validating','needs_help'))
  on conflict do nothing;
  get diagnostics v_x=row_count; v_n:=v_n+v_x;
  return v_n;
end $$;


--
-- Name: rara_learn_and_replan_rejection(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_learn_and_replan_rejection(p_builder_run_id bigint, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r public.contentflow_builder_runs%rowtype; b public.contentflow_build_backlog%rowtype; cls text; fp text; rule text; deps_ok boolean:=true; target text;
begin
 select * into r from public.contentflow_builder_runs where id=p_builder_run_id; if not found then return jsonb_build_object('ok',false,'reason','run_not_found'); end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update; if not found then return jsonb_build_object('ok',false,'reason','task_not_found'); end if;
 cls:=public.rara_classify_rejection(p_reason);
 if cls='owner_required' and coalesce((b.workflow_contract->>'artifact_completion_independent_of_external_approval')::boolean,false) then cls:='external_approval_wait'; end if;
 fp:='rara_reject_'||cls||'_v2';
 rule:=case cls when 'hardcoded_execution_identity' then 'Never emit execution-specific identifiers in reusable artifacts.' when 'vendor_claim_not_benchmark' then 'Keep vendor claims distinct from independent/measured evidence and mark decision metrics pending benchmark.' when 'placeholder_or_stub' then 'Replace placeholders/stubs with substantive contract content.' when 'acceptance_evidence' then 'Request evidence only when the explicit workflow contract says evidence_policy=required; otherwise declare the gap.' when 'contract_incomplete' then 'Patch only the rejected contract findings while preserving accepted artifact content.' when 'external_approval_wait' then 'External approval is a production authorization wait, not an artifact-completion failure.' else 'Patch only the explicit RARA findings and preserve accepted stages.' end;
 if cls='owner_required' then return jsonb_build_object('ok',false,'action','owner_required','class',cls); end if;
 select not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed')) into deps_ok;
 target:=case when deps_ok then 'ready' else 'planned' end;
 update public.contentflow_retry_state set attempt_count=0,next_retry_at=null,circuit_state='closed',circuit_open_until=null,updated_at=now() where project_key=b.project_key and backlog_task_id=b.id;
 update public.contentflow_evidence_requirements set status='obsolete',updated_at=now() where project_key=b.project_key and backlog_task_id=b.id and status in ('open','task_created') and coalesce(b.workflow_contract->>'evidence_policy','declared_gaps_allowed')<>'required';
 update public.contentflow_build_backlog set status=target,selected_model=null,blocked_reason=null,next_eligible_at=case when target='ready' then now() else next_eligible_at end,workflow_state=case when cls='external_approval_wait' then 'artifact_patch_required' else 'patch_required' end,patch_feedback=left(coalesce(p_reason,'')||E'\n[DURABLE PATCH RULE] '||rule,5000),updated_at=now() where id=b.id;
 insert into public.director_error_memory(project_key,error_class,error_fingerprint,component,symptom,root_cause,correction,prevention_rule,evidence,occurrences,correction_successes,correction_failures,confidence,status,last_seen_at,updated_at) values(b.project_key,'rara_review_rejection',fp,'rara_review',left(coalesce(p_reason,''),1000),cls,'Localized stage patch; preserve previous artifact/checkpoints',rule,'run='||p_builder_run_id,1,0,0,0.8,'active',now(),now()) on conflict(project_key,error_fingerprint) do update set last_seen_at=now(),updated_at=now(),occurrences=public.director_error_memory.occurrences+1,symptom=excluded.symptom,root_cause=excluded.root_cause,correction=excluded.correction,prevention_rule=excluded.prevention_rule,status='active';
 return jsonb_build_object('ok',true,'action','localized_patch','class',cls,'task_key',b.task_key,'target_status',target,'preserved_artifact',true);
end $$;


--
-- Name: rara_normalize_and_reopen_known_incidents(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_normalize_and_reopen_known_incidents(p_project_key text DEFAULT 'contentflow'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare normalized int:=0; reopened int:=0;
begin
  update public.director_repair_incidents
  set error_class='builder_timeout',error_fingerprint='builder_timeout:'||task_key,component='builder',updated_at=now()
  where project_key=p_project_key and error_class='builder_failed' and coalesce(symptom,'') ilike '%timeout%';
  get diagnostics normalized=row_count;

  update public.director_help_alerts
  set error_class='builder_timeout',error_fingerprint='builder_timeout:'||task_key,updated_at=now()
  where project_key=p_project_key and status='open' and error_class='builder_failed' and (coalesce(summary,'') ilike '%timeout%' or coalesce(last_error,'') ilike '%timeout%' or exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.task_key=director_help_alerts.task_key and i.error_class='builder_timeout'));

  update public.director_repair_incidents i
  set status='open',requires_human=false,attempts=least(attempts, greatest(0,max_attempts-1)),outcome='reopened_by_learned_recipe',updated_at=now()
  where i.project_key=p_project_key and i.status='needs_help'
    and exists(select 1 from public.director_repair_recipes r where r.project_key=i.project_key and r.enabled=true and r.risk_level='low' and r.confidence>=r.min_confidence and r.failures<r.max_consecutive_failures and (r.error_class is null or r.error_class=i.error_class) and (r.component is null or r.component=i.component) and (r.fingerprint_prefix is null or i.error_fingerprint like r.fingerprint_prefix||'%'));
  get diagnostics reopened=row_count;
  return jsonb_build_object('normalized',normalized,'reopened',reopened);
end $$;


--
-- Name: rara_release_review_v1(bigint, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_release_review_v1(p_builder_run_id bigint, p_claim_token text, p_error text DEFAULT NULL::text, p_delay_seconds integer DEFAULT 30) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 update public.contentflow_review_work_queue as q
 set state='pending',claim_token=null,claimed_at=null,
     available_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay_seconds,30),600))),
     last_error=left(p_error,1000),updated_at=now()
 where q.builder_run_id=p_builder_run_id and q.state='claimed' and q.claim_token=p_claim_token;
 return found;
end $$;


--
-- Name: rara_safe_collect_ready_dispatches(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_safe_collect_ready_dispatches() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$ declare x record; n integer:=0; s text; begin for x in select d.request_id from public.contentflow_builder_dispatches d join net._http_response r on r.id=d.request_id where d.status='pending' loop s:=public.internal_builder_collect(x.request_id); n:=n+1; end loop; return n; end $$;


--
-- Name: rara_safe_requeue_failed_task(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_safe_requeue_failed_task(p_task_key text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_id bigint;
begin
  if p_task_key like 'gap_gap_%' then return false; end if;

  select b.id into v_id
  from public.contentflow_build_backlog b
  where b.project_key='contentflow' and b.task_key=p_task_key
    and b.status in ('failed','blocked')
    and exists(
      select 1 from public.contentflow_builder_runs lr
      where lr.backlog_task_id=b.id
        and lr.id=(select max(id) from public.contentflow_builder_runs z where z.backlog_task_id=b.id)
        and lr.status='failed'
    )
    and not exists(
      select 1 from public.contentflow_builder_runs r
      where r.backlog_task_id=b.id
        and r.status in ('claimed','running','review_required','verification_required')
        and r.finished_at is null
    )
  for update;

  if v_id is null then return false; end if;

  update public.contentflow_retry_state s
     set circuit_state='closed', circuit_open_until=null, next_retry_at=now(), updated_at=now()
   where s.backlog_task_id=v_id;

  update public.contentflow_build_backlog b
  set status='ready',
      selected_model=null,
      quality_score=0,
      blocked_reason=null,
      next_eligible_at=now(),
      updated_at=now(),
      result=coalesce(result,'')||E'\n[RARA] safe requeue after diagnosed failure/timeout'
  where b.id=v_id;

  return true;
end
$$;


--
-- Name: rara_safe_restart_pg_net_if_stuck(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rara_safe_restart_pg_net_if_stuck() RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'net'
    AS $$ declare q integer; begin select count(*) into q from net.http_request_queue; if q>0 then perform net.worker_restart(); perform net.wait_until_running(); perform net.wake(); return true; end if; return false; end $$;


--
-- Name: record_director_model_stat(text, text, text, boolean, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_director_model_stat(p_project_key text, p_task_type text, p_model_id text, p_success boolean, p_quality numeric, p_latency_ms numeric, p_cost_usd numeric) RETURNS void
    LANGUAGE sql
    SET search_path TO 'public'
    AS $$
  insert into public.director_model_stats(
    user_id, project_key, task_type, model_id, runs, successes,
    avg_quality, avg_latency_ms, avg_cost_usd, updated_at
  ) values (
    (select auth.uid()), p_project_key, p_task_type, p_model_id, 1,
    case when p_success then 1 else 0 end,
    coalesce(p_quality,0), coalesce(p_latency_ms,0), coalesce(p_cost_usd,0), now()
  )
  on conflict (user_id, project_key, task_type, model_id)
  do update set
    runs = public.director_model_stats.runs + 1,
    successes = public.director_model_stats.successes + case when p_success then 1 else 0 end,
    avg_quality = ((public.director_model_stats.avg_quality * public.director_model_stats.runs) + coalesce(p_quality,0)) / (public.director_model_stats.runs + 1),
    avg_latency_ms = ((public.director_model_stats.avg_latency_ms * public.director_model_stats.runs) + coalesce(p_latency_ms,0)) / (public.director_model_stats.runs + 1),
    avg_cost_usd = ((public.director_model_stats.avg_cost_usd * public.director_model_stats.runs) + coalesce(p_cost_usd,0)) / (public.director_model_stats.runs + 1),
    updated_at = now();
$$;


--
-- Name: refresh_orchestrator_run_usage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_orchestrator_run_usage() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update public.orchestrator_runs r
     set input_tokens = s.input_tokens,
         output_tokens = s.output_tokens
    from (
      select run_id,
             coalesce(sum(input_tokens),0)::bigint as input_tokens,
             coalesce(sum(output_tokens),0)::bigint as output_tokens
        from public.orchestrator_tasks
       where run_id = new.run_id
       group by run_id
    ) s
   where r.id = s.run_id;
  return new;
end;
$$;


--
-- Name: requeue_approved_worker_on_run_finish(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.requeue_approved_worker_on_run_finish() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ begin if new.selected_model is not null and new.status in ('review_required','completed','failed') and exists(select 1 from public.contentflow_fresh10_items f where f.model=new.selected_model and f.status='pass' and f.quality_score>=85) then insert into public.director_worker_queue(model_id,status,current_task_key,last_task_key,last_outcome,last_quality_score,last_finished_at,total_assignments,total_completions,total_failures,updated_at) values(new.selected_model,'ready',null,new.task_key,new.status,new.quality_score,new.finished_at,0,case when new.status in ('review_required','completed') then 1 else 0 end,case when new.status='failed' then 1 else 0 end,now()) on conflict(model_id) do update set status='ready',current_task_key=null,last_task_key=excluded.last_task_key,last_outcome=excluded.last_outcome,last_quality_score=excluded.last_quality_score,last_finished_at=excluded.last_finished_at,total_completions=director_worker_queue.total_completions+case when excluded.last_outcome in ('review_required','completed') then 1 else 0 end,total_failures=director_worker_queue.total_failures+case when excluded.last_outcome='failed' then 1 else 0 end,updated_at=now(); end if; return new; end $$;


--
-- Name: upsert_meta_oauth_token(text, text, text, text, text[], text[], text, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_meta_oauth_token(p_app_id text, p_user_id text, p_page_id text, p_instagram_id text, p_scopes text[], p_tasks text[], p_token_ciphertext text, p_token_iv text, p_token_tag text, p_token_fingerprint text, p_expires_at timestamp with time zone) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'private', 'public'
    AS $$
begin
  insert into private.meta_oauth_tokens (
    provider, app_id, user_id, page_id, instagram_id, scopes, tasks,
    token_ciphertext, token_iv, token_tag, token_fingerprint, expires_at, updated_at
  ) values (
    'meta', p_app_id, p_user_id, p_page_id, p_instagram_id, coalesce(p_scopes,'{}'), coalesce(p_tasks,'{}'),
    p_token_ciphertext, p_token_iv, p_token_tag, p_token_fingerprint, p_expires_at, now()
  )
  on conflict (provider, app_id, page_id) do update set
    user_id = excluded.user_id,
    instagram_id = excluded.instagram_id,
    scopes = excluded.scopes,
    tasks = excluded.tasks,
    token_ciphertext = excluded.token_ciphertext,
    token_iv = excluded.token_iv,
    token_tag = excluded.token_tag,
    token_fingerprint = excluded.token_fingerprint,
    expires_at = excluded.expires_at,
    updated_at = now();
end;
$$;


--
-- Name: upsert_youtube_oauth_token(text, text, text[], text, text, text, text, text, text, text, timestamp with time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_youtube_oauth_token(p_channel_id text, p_channel_title text, p_scopes text[], p_access_token_ciphertext text, p_access_token_iv text, p_access_token_tag text, p_refresh_token_ciphertext text, p_refresh_token_iv text, p_refresh_token_tag text, p_token_fingerprint text, p_access_expires_at timestamp with time zone, p_refresh_token_received boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into public.youtube_oauth_token_vault (
    channel_id, channel_title, scopes,
    access_token_ciphertext, access_token_iv, access_token_tag,
    refresh_token_ciphertext, refresh_token_iv, refresh_token_tag,
    token_fingerprint, access_expires_at, refresh_token_received, updated_at
  ) values (
    p_channel_id, p_channel_title, coalesce(p_scopes,'{}'),
    p_access_token_ciphertext, p_access_token_iv, p_access_token_tag,
    p_refresh_token_ciphertext, p_refresh_token_iv, p_refresh_token_tag,
    p_token_fingerprint, p_access_expires_at, p_refresh_token_received, now()
  )
  on conflict (channel_id) do update set
    channel_title = excluded.channel_title,
    scopes = excluded.scopes,
    access_token_ciphertext = excluded.access_token_ciphertext,
    access_token_iv = excluded.access_token_iv,
    access_token_tag = excluded.access_token_tag,
    refresh_token_ciphertext = coalesce(excluded.refresh_token_ciphertext, public.youtube_oauth_token_vault.refresh_token_ciphertext),
    refresh_token_iv = coalesce(excluded.refresh_token_iv, public.youtube_oauth_token_vault.refresh_token_iv),
    refresh_token_tag = coalesce(excluded.refresh_token_tag, public.youtube_oauth_token_vault.refresh_token_tag),
    token_fingerprint = excluded.token_fingerprint,
    access_expires_at = excluded.access_expires_at,
    refresh_token_received = public.youtube_oauth_token_vault.refresh_token_received or excluded.refresh_token_received,
    updated_at = now();
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: academy_whatsapp_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.academy_whatsapp_config (
    id smallint DEFAULT 1 NOT NULL,
    phone_e164 text NOT NULL,
    waba_id text,
    phone_number_id text,
    verified_name text,
    status text DEFAULT 'meta_binding_required'::text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    webhook_verified boolean DEFAULT false NOT NULL,
    access_token_configured boolean DEFAULT false NOT NULL,
    app_secret_configured boolean DEFAULT false NOT NULL,
    verify_token_configured boolean DEFAULT false NOT NULL,
    graph_version_configured boolean DEFAULT false NOT NULL,
    last_verified_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT academy_whatsapp_config_id_check CHECK ((id = 1)),
    CONSTRAINT academy_whatsapp_config_status_check CHECK ((status = ANY (ARRAY['prepared'::text, 'meta_binding_required'::text, 'registered'::text, 'active'::text, 'paused'::text, 'error'::text])))
);


--
-- Name: academy_whatsapp_conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.academy_whatsapp_conversations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    wa_id text NOT NULL,
    display_name text,
    language text DEFAULT 'es'::text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    last_intent text,
    human_required boolean DEFAULT false NOT NULL,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    last_message_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT academy_whatsapp_conversations_status_check CHECK ((status = ANY (ARRAY['open'::text, 'human_required'::text, 'human_active'::text, 'closed'::text])))
);


--
-- Name: academy_whatsapp_handoffs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.academy_whatsapp_handoffs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    conversation_id uuid NOT NULL,
    reason text NOT NULL,
    user_question text,
    status text DEFAULT 'open'::text NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    assigned_at timestamp with time zone,
    resolved_at timestamp with time zone,
    resolution_note text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT academy_whatsapp_handoffs_status_check CHECK ((status = ANY (ARRAY['open'::text, 'assigned'::text, 'resolved'::text, 'closed'::text])))
);


--
-- Name: academy_whatsapp_knowledge; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.academy_whatsapp_knowledge (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    intent text NOT NULL,
    language text DEFAULT 'es'::text NOT NULL,
    topic text NOT NULL,
    answer_text text NOT NULL,
    source_type text NOT NULL,
    source_ref text NOT NULL,
    source_verified_at timestamp with time zone NOT NULL,
    requires_human boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 50 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: academy_whatsapp_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.academy_whatsapp_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    conversation_id uuid NOT NULL,
    whatsapp_message_id text,
    direction text NOT NULL,
    message_type text DEFAULT 'text'::text NOT NULL,
    body text,
    intent text,
    knowledge_id uuid,
    confidence numeric(4,3),
    status text DEFAULT 'received'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT academy_whatsapp_messages_direction_check CHECK ((direction = ANY (ARRAY['inbound'::text, 'outbound'::text])))
);


--
-- Name: academy_whatsapp_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.academy_whatsapp_outbox (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    conversation_id uuid NOT NULL,
    recipient_wa_id text NOT NULL,
    body text NOT NULL,
    source_knowledge_id uuid,
    status text DEFAULT 'pending'::text NOT NULL,
    whatsapp_message_id text,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    sent_at timestamp with time zone,
    CONSTRAINT academy_whatsapp_outbox_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'failed'::text, 'blocked'::text])))
);


--
-- Name: brands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brands (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    industry text,
    ideal_customer text,
    tone text,
    description text,
    memory_summary text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: content_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_schedule (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    project_id uuid,
    social_account_id uuid,
    scheduled_for timestamp with time zone NOT NULL,
    publish_mode text DEFAULT 'approval'::text NOT NULL,
    status text DEFAULT 'scheduled'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT content_schedule_publish_mode_check CHECK ((publish_mode = ANY (ARRAY['manual'::text, 'approval'::text, 'autopilot'::text])))
);


--
-- Name: contentflow_build_backlog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_build_backlog (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    epic text NOT NULL,
    task_key text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    task_type text NOT NULL,
    stage integer DEFAULT 1 NOT NULL,
    depends_on jsonb DEFAULT '[]'::jsonb NOT NULL,
    team text,
    status text DEFAULT 'planned'::text NOT NULL,
    priority integer DEFAULT 50 NOT NULL,
    acceptance_criteria text,
    selected_model text,
    quality_score numeric DEFAULT 0 NOT NULL,
    cost_usd numeric DEFAULT 0 NOT NULL,
    source_run_id bigint,
    result text,
    next_eligible_at timestamp with time zone,
    completion_phase text DEFAULT 'designed'::text NOT NULL,
    runtime_verified boolean DEFAULT false NOT NULL,
    runtime_verified_at timestamp with time zone,
    runtime_evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    execution_lane text DEFAULT 'llm_artifact'::text NOT NULL,
    blocked_reason text,
    workflow_contract jsonb DEFAULT '{}'::jsonb NOT NULL,
    workflow_state text DEFAULT 'artifact_pending'::text NOT NULL,
    patch_feedback text,
    artifact_version integer DEFAULT 0 NOT NULL,
    last_checkpoint_at timestamp with time zone,
    CONSTRAINT contentflow_build_backlog_execution_lane_chk CHECK ((execution_lane = ANY (ARRAY['llm_artifact'::text, 'tool_executor'::text, 'evidence_producer'::text]))),
    CONSTRAINT contentflow_build_backlog_priority_check CHECK (((priority >= 0) AND (priority <= 100))),
    CONSTRAINT contentflow_build_backlog_stage_check CHECK ((stage > 0)),
    CONSTRAINT contentflow_build_backlog_status_check CHECK ((status = ANY (ARRAY['planned'::text, 'ready'::text, 'running'::text, 'verification_required'::text, 'completed'::text, 'blocked'::text, 'failed'::text, 'deferred'::text]))),
    CONSTRAINT contentflow_build_backlog_task_type_check CHECK ((task_type = ANY (ARRAY['code'::text, 'architecture'::text, 'general'::text, 'bulk'::text])))
);


--
-- Name: contentflow_build_backlog_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_build_backlog ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_build_backlog_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_builder_dispatches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_builder_dispatches (
    request_id bigint NOT NULL,
    builder_run_id bigint NOT NULL,
    backlog_task_id bigint NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    collected_at timestamp with time zone,
    http_status integer,
    error text,
    CONSTRAINT contentflow_builder_dispatches_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'collected'::text, 'failed'::text, 'superseded'::text])))
);


--
-- Name: contentflow_builder_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_builder_runs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    backlog_task_id bigint NOT NULL,
    task_key text NOT NULL,
    task_type text NOT NULL,
    status text DEFAULT 'claimed'::text NOT NULL,
    selected_model text,
    quality_score numeric DEFAULT 0 NOT NULL,
    cost_usd numeric DEFAULT 0 NOT NULL,
    result text,
    error text,
    review_approved boolean DEFAULT false NOT NULL,
    idempotency_key text,
    lease_expires_at timestamp with time zone,
    heartbeat_at timestamp with time zone,
    workflow_version text,
    trace_id text,
    span_id text,
    lease_token text,
    lease_generation bigint DEFAULT 0 NOT NULL,
    runner_instance_id text,
    heartbeat_seq bigint DEFAULT 0 NOT NULL,
    lease_revoked_at timestamp with time zone,
    control_protocol text,
    activity_phase text,
    activity_deadline_at timestamp with time zone,
    activity_seq bigint DEFAULT 0 NOT NULL,
    heartbeat_deadline_at timestamp with time zone,
    activity_checkpoint jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT contentflow_builder_runs_status_check CHECK ((status = ANY (ARRAY['claimed'::text, 'running'::text, 'review_required'::text, 'verification_required'::text, 'completed'::text, 'failed'::text, 'blocked'::text, 'deferred'::text])))
);


--
-- Name: contentflow_builder_review_queue; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_builder_review_queue AS
 SELECT id AS builder_run_id,
    task_key,
    task_type,
    status,
    quality_score,
    cost_usd,
    review_approved,
    created_at,
    finished_at,
    error,
        CASE
            WHEN ((task_type <> 'code'::text) AND (status = 'completed'::text)) THEN 'approved'::text
            WHEN ((task_type = 'code'::text) AND review_approved AND (status = 'completed'::text)) THEN 'approved'::text
            WHEN ((task_type = 'code'::text) AND (status = 'review_required'::text) AND (NOT review_approved)) THEN 'pending'::text
            WHEN (status = ANY (ARRAY['failed'::text, 'blocked'::text, 'deferred'::text])) THEN 'rejected'::text
            ELSE 'pending'::text
        END AS review_decision
   FROM public.contentflow_builder_runs r;


--
-- Name: contentflow_builder_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_builder_runs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_builder_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_builder_stage_evidence; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_builder_stage_evidence AS
 SELECT b.task_key,
    b.status,
    b.task_type,
    b.team,
    r.id AS builder_run_id,
    r.status AS run_status,
    r.quality_score,
    r.cost_usd,
    r.review_approved,
    r.selected_model,
    r.created_at,
    r.finished_at,
        CASE
            WHEN (r.id IS NULL) THEN 'not_started'::text
            WHEN (r.status = 'claimed'::text) THEN 'planning'::text
            WHEN ((r.status = 'review_required'::text) AND (NOT r.review_approved)) THEN 'review'::text
            WHEN ((r.status = 'completed'::text) AND r.review_approved) THEN 'qa_passed'::text
            WHEN (r.status = ANY (ARRAY['failed'::text, 'blocked'::text, 'deferred'::text])) THEN 'blocked'::text
            ELSE 'in_progress'::text
        END AS construction_stage
   FROM (public.contentflow_build_backlog b
     LEFT JOIN LATERAL ( SELECT x.id,
            x.created_at,
            x.finished_at,
            x.project_key,
            x.backlog_task_id,
            x.task_key,
            x.task_type,
            x.status,
            x.selected_model,
            x.quality_score,
            x.cost_usd,
            x.result,
            x.error,
            x.review_approved
           FROM public.contentflow_builder_runs x
          WHERE (x.task_key = b.task_key)
          ORDER BY x.created_at DESC
         LIMIT 1) r ON (true));


--
-- Name: contentflow_builder_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_builder_status AS
 SELECT b.id AS backlog_task_id,
    b.task_key,
    b.title,
    b.task_type,
    b.status AS backlog_status,
    b.stage,
    b.priority,
    b.updated_at AS backlog_updated_at,
    r.id AS builder_run_id,
    r.status AS builder_run_status,
    r.selected_model,
    r.quality_score,
    r.cost_usd,
    r.review_approved,
    r.error,
    r.created_at AS claimed_at,
    r.finished_at,
        CASE
            WHEN ((b.status = 'running'::text) AND (r.status = ANY (ARRAY['claimed'::text, 'running'::text, 'review_required'::text])) AND (r.finished_at IS NULL)) THEN true
            ELSE false
        END AS is_active_claim
   FROM (public.contentflow_build_backlog b
     LEFT JOIN LATERAL ( SELECT x.id,
            x.created_at,
            x.finished_at,
            x.project_key,
            x.backlog_task_id,
            x.task_key,
            x.task_type,
            x.status,
            x.selected_model,
            x.quality_score,
            x.cost_usd,
            x.result,
            x.error,
            x.review_approved
           FROM public.contentflow_builder_runs x
          WHERE (x.backlog_task_id = b.id)
          ORDER BY x.created_at DESC
         LIMIT 1) r ON (true))
  WHERE (b.project_key = 'contentflow'::text);


--
-- Name: contentflow_capability_certifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_capability_certifications (
    prerequisite text NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    certification_task_key text,
    certification_run_id bigint,
    verification_id bigint,
    evidence_id bigint,
    verifier text,
    quality_score numeric,
    certified_at timestamp with time zone,
    last_error text,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_capability_certifications_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'runtime_passed'::text, 'certified'::text, 'failed'::text])))
);


--
-- Name: contentflow_capacity_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_capacity_decisions (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    from_phase smallint NOT NULL,
    to_phase smallint NOT NULL,
    reason text NOT NULL,
    metrics jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: contentflow_capacity_decisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_capacity_decisions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_capacity_decisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_capacity_phases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_capacity_phases (
    phase smallint NOT NULL,
    global_max integer NOT NULL,
    production_max integer NOT NULL,
    qa_max integer NOT NULL,
    recruitment_max integer NOT NULL,
    fallback_max integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_capacity_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_capacity_state (
    id smallint DEFAULT 1 NOT NULL,
    active_phase smallint DEFAULT 1 NOT NULL,
    auto_scale boolean DEFAULT true NOT NULL,
    phase_started_at timestamp with time zone DEFAULT now() NOT NULL,
    min_phase_minutes integer DEFAULT 360 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_capacity_state_id_check CHECK ((id = 1))
);


--
-- Name: contentflow_continuation_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_continuation_state (
    project_key text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    max_tasks_per_cycle integer DEFAULT 3 NOT NULL,
    last_cycle integer DEFAULT 0 NOT NULL,
    last_generated_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_dependency_priority; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_dependency_priority WITH (security_invoker='true') AS
 SELECT id,
    project_key,
    task_key,
    title,
    status,
    execution_lane,
    priority,
    public.contentflow_dependency_impact_score(project_key, task_key) AS dependency_impact_score
   FROM public.contentflow_build_backlog b
  WHERE (status <> ALL (ARRAY['completed'::text, 'deferred'::text]));


--
-- Name: contentflow_durable_signal_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_durable_signal_ledger (
    id bigint NOT NULL,
    project_key text NOT NULL,
    task_key text NOT NULL,
    signal_key text NOT NULL,
    signal_id text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    producer text DEFAULT 'unknown'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_durable_signal_ledger_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_durable_signal_ledger ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_durable_signal_ledger_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_durable_task_stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_durable_task_stages (
    backlog_task_id bigint NOT NULL,
    project_key text NOT NULL,
    task_key text NOT NULL,
    stage_name text NOT NULL,
    stage_state text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    artifact_version integer DEFAULT 0 NOT NULL,
    last_error_class text,
    last_error text,
    checkpoint jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_evidence_capability_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_evidence_capability_registry (
    prerequisite text NOT NULL,
    verifier_available boolean DEFAULT false NOT NULL,
    producer_available boolean DEFAULT false NOT NULL,
    provider text,
    scope text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_evidence_requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_evidence_requirements (
    id bigint NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    backlog_task_id bigint NOT NULL,
    source_run_id bigint NOT NULL,
    task_key text NOT NULL,
    requirement_class text NOT NULL,
    requirement_fingerprint text NOT NULL,
    requirement_text text NOT NULL,
    evidence_task_key text,
    status text DEFAULT 'open'::text NOT NULL,
    evidence_ref jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    verified_at timestamp with time zone,
    CONSTRAINT contentflow_evidence_requirements_status_check CHECK ((status = ANY (ARRAY['open'::text, 'task_created'::text, 'verified'::text, 'blocked'::text, 'obsolete'::text])))
);


--
-- Name: contentflow_evidence_capability_matrix; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_evidence_capability_matrix AS
 SELECT er.id AS requirement_id,
    er.project_key,
    er.backlog_task_id,
    er.task_key AS source_task_key,
    er.evidence_task_key,
    er.status AS requirement_status,
    public.contentflow_evidence_prerequisite_class(er.requirement_class, er.requirement_text) AS prerequisite,
    COALESCE(cr.verifier_available, false) AS verifier_available,
    COALESCE(cr.producer_available, false) AS producer_available,
    cr.provider,
    cr.scope,
    public.contentflow_evidence_verifier_preflight(er.project_key, er.evidence_task_key) AS evidence_already_verifiable
   FROM (public.contentflow_evidence_requirements er
     LEFT JOIN public.contentflow_evidence_capability_registry cr ON ((cr.prerequisite = public.contentflow_evidence_prerequisite_class(er.requirement_class, er.requirement_text))));


--
-- Name: contentflow_evidence_producer_recipes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_evidence_producer_recipes (
    id bigint NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    evidence_task_key text NOT NULL,
    check_type text NOT NULL,
    check_spec jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_evidence_producer_recipes_check_type_check CHECK ((check_type = ANY (ARRAY['table_exists'::text, 'function_exists'::text, 'policy_exists'::text, 'event_exists'::text, 'runtime_verification_exists'::text, 'row_count_gte'::text])))
);


--
-- Name: contentflow_evidence_producer_recipes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_evidence_producer_recipes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_evidence_producer_recipes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_evidence_requirements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contentflow_evidence_requirements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contentflow_evidence_requirements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contentflow_evidence_requirements_id_seq OWNED BY public.contentflow_evidence_requirements.id;


--
-- Name: contentflow_external_executor_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_external_executor_registry (
    project_key text NOT NULL,
    executor_key text NOT NULL,
    endpoint text,
    status text DEFAULT 'unconfigured'::text NOT NULL,
    capabilities jsonb DEFAULT '{}'::jsonb NOT NULL,
    verified_at timestamp with time zone,
    last_health jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_external_executor_registry_status_chk CHECK ((status = ANY (ARRAY['unconfigured'::text, 'configured'::text, 'healthy'::text, 'degraded'::text, 'offline'::text])))
);


--
-- Name: contentflow_external_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_external_reports (
    report_key text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    ready_at timestamp with time zone,
    sent_at timestamp with time zone,
    recipient text,
    gmail_reply_message_id text,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    notes text
);


--
-- Name: contentflow_fresh10_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_fresh10_items (
    id bigint NOT NULL,
    run_id bigint NOT NULL,
    slot integer NOT NULL,
    model text NOT NULL,
    status text DEFAULT 'waiting'::text NOT NULL,
    quality_score numeric DEFAULT 0 NOT NULL,
    latency_ms bigint,
    judge_latency_ms bigint,
    input_tokens bigint DEFAULT 0 NOT NULL,
    output_tokens bigint DEFAULT 0 NOT NULL,
    cost_usd numeric DEFAULT 0 NOT NULL,
    judge_model text,
    quality_reason text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    CONSTRAINT contentflow_fresh10_items_slot_check CHECK (((slot >= 1) AND (slot <= 10))),
    CONSTRAINT contentflow_fresh10_items_status_check CHECK ((status = ANY (ARRAY['waiting'::text, 'running'::text, 'judging'::text, 'pass'::text, 'worker_fail'::text, 'judge_fail'::text, 'infra_fail'::text, 'truncation_fail'::text])))
);


--
-- Name: contentflow_fresh10_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_fresh10_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_fresh10_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_fresh10_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_fresh10_runs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    status text DEFAULT 'queued'::text NOT NULL,
    catalog_count integer DEFAULT 0 NOT NULL,
    excluded_count integer DEFAULT 0 NOT NULL,
    candidate_count integer DEFAULT 0 NOT NULL,
    completed_count integer DEFAULT 0 NOT NULL,
    approved_count integer DEFAULT 0 NOT NULL,
    winner text,
    error text,
    CONSTRAINT contentflow_fresh10_runs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'discovering'::text, 'running'::text, 'judging'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: contentflow_fresh10_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_fresh10_runs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_fresh10_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_internal_runner_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_internal_runner_config (
    id smallint NOT NULL,
    runner_secret text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    rotated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_internal_runner_config_id_check CHECK ((id = 1))
);


--
-- Name: contentflow_lane_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_lane_models (
    lane text NOT NULL,
    primary_model text NOT NULL,
    role text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_lane_models_lane_check CHECK ((lane = ANY (ARRAY['production'::text, 'qa'::text, 'recruitment'::text, 'fallback'::text])))
);


--
-- Name: contentflow_legal_governance_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_legal_governance_profiles (
    project_key text NOT NULL,
    operator_name text,
    jurisdictions jsonb DEFAULT '[]'::jsonb NOT NULL,
    user_categories jsonb DEFAULT '[]'::jsonb NOT NULL,
    data_inventory jsonb DEFAULT '[]'::jsonb NOT NULL,
    sensitive_data_categories jsonb DEFAULT '[]'::jsonb NOT NULL,
    vendor_inventory jsonb DEFAULT '[]'::jsonb NOT NULL,
    ip_license_inventory jsonb DEFAULT '[]'::jsonb NOT NULL,
    autonomous_authority jsonb DEFAULT '{}'::jsonb NOT NULL,
    human_approval_actions jsonb DEFAULT '[]'::jsonb NOT NULL,
    retention_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    incident_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    required_legal_docs jsonb DEFAULT '[]'::jsonb NOT NULL,
    risk_tier text DEFAULT 'unclassified'::text NOT NULL,
    legal_review_status text DEFAULT 'draft'::text NOT NULL,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_legal_governance_profiles_legal_review_status_check CHECK ((legal_review_status = ANY (ARRAY['draft'::text, 'internal_approved'::text, 'counsel_review_required'::text, 'counsel_approved'::text]))),
    CONSTRAINT contentflow_legal_governance_profiles_risk_tier_check CHECK ((risk_tier = ANY (ARRAY['unclassified'::text, 'low'::text, 'medium'::text, 'high'::text])))
);


--
-- Name: contentflow_model_task_quarantine; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_model_task_quarantine (
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    task_key text NOT NULL,
    model_id text NOT NULL,
    reason text NOT NULL,
    failures integer DEFAULT 1 NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: contentflow_nexo_request_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_nexo_request_metrics (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    lane text NOT NULL,
    model text NOT NULL,
    task_key text,
    slot_id uuid,
    status_code integer,
    success boolean,
    error_class text,
    retry_after_seconds numeric,
    timeout_seconds integer,
    latency_ms integer,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    cost_usd numeric DEFAULT 0 NOT NULL,
    phase smallint,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    nexo_request_id text,
    completion_id text,
    logical_request_id uuid,
    attempt_id uuid,
    parent_attempt_id uuid,
    attempt_index integer,
    attempt_kind text,
    semantic_success boolean,
    task_success boolean,
    CONSTRAINT contentflow_nexo_request_metrics_lane_check CHECK ((lane = ANY (ARRAY['production'::text, 'qa'::text, 'recruitment'::text, 'fallback'::text])))
);


--
-- Name: contentflow_nexo_lane_kpis_24h; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_nexo_lane_kpis_24h WITH (security_invoker='true') AS
 SELECT lane,
    count(*) AS requests,
    count(*) FILTER (WHERE success) AS successful_requests,
    round(((100.0 * (count(*) FILTER (WHERE success))::numeric) / (NULLIF(count(*), 0))::numeric), 2) AS success_pct,
    round(avg(latency_ms)) AS avg_latency_ms,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((latency_ms)::double precision)) AS p95_latency_ms,
    max(latency_ms) AS max_latency_ms,
    count(*) FILTER (WHERE (status_code = 429)) AS rate_limit_429,
    count(*) FILTER (WHERE (error_class = 'UPSTREAM'::text)) AS upstream_errors,
    count(*) FILTER (WHERE (error_class = 'TIMEOUT'::text)) AS timeouts,
    round(avg(input_tokens), 1) AS avg_input_tokens,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((input_tokens)::double precision)) AS p95_input_tokens,
    max(input_tokens) AS max_input_tokens,
    round(avg(output_tokens), 1) AS avg_output_tokens,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((output_tokens)::double precision)) AS p95_output_tokens,
    max(output_tokens) AS max_output_tokens,
    sum((input_tokens + output_tokens)) AS total_tokens,
    sum(cost_usd) AS total_cost_usd
   FROM public.contentflow_nexo_request_metrics
  WHERE (created_at >= (now() - '24:00:00'::interval))
  GROUP BY lane;


--
-- Name: contentflow_nexo_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_nexo_slots (
    slot_id uuid DEFAULT gen_random_uuid() NOT NULL,
    lane text NOT NULL,
    model text NOT NULL,
    task_key text,
    acquired_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    released_at timestamp with time zone,
    release_reason text,
    CONSTRAINT contentflow_nexo_slots_lane_check CHECK ((lane = ANY (ARRAY['production'::text, 'qa'::text, 'recruitment'::text, 'fallback'::text])))
);


--
-- Name: contentflow_nexo_lane_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_nexo_lane_status WITH (security_invoker='true') AS
 SELECT s.active_phase,
    p.global_max,
    p.production_max,
    p.qa_max,
    p.recruitment_max,
    p.fallback_max,
    ( SELECT count(*) AS count
           FROM public.contentflow_nexo_slots x
          WHERE ((x.released_at IS NULL) AND (x.expires_at > now()))) AS active_global,
    ( SELECT count(*) AS count
           FROM public.contentflow_nexo_slots x
          WHERE ((x.released_at IS NULL) AND (x.expires_at > now()) AND (x.lane = 'production'::text))) AS active_production,
    ( SELECT count(*) AS count
           FROM public.contentflow_nexo_slots x
          WHERE ((x.released_at IS NULL) AND (x.expires_at > now()) AND (x.lane = 'qa'::text))) AS active_qa,
    ( SELECT count(*) AS count
           FROM public.contentflow_nexo_slots x
          WHERE ((x.released_at IS NULL) AND (x.expires_at > now()) AND (x.lane = 'recruitment'::text))) AS active_recruitment,
    ( SELECT count(*) AS count
           FROM public.contentflow_nexo_slots x
          WHERE ((x.released_at IS NULL) AND (x.expires_at > now()) AND (x.lane = 'fallback'::text))) AS active_fallback,
    s.phase_started_at,
    s.auto_scale
   FROM (public.contentflow_capacity_state s
     JOIN public.contentflow_capacity_phases p ON ((p.phase = s.active_phase)))
  WHERE (s.id = 1);


--
-- Name: contentflow_nexo_request_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_nexo_request_metrics ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_nexo_request_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_persistent_change_provenance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_persistent_change_provenance (
    id bigint NOT NULL,
    change_id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    change_class text NOT NULL,
    incident_id bigint,
    repair_recipe text,
    migration_name text,
    git_commit_sha text,
    git_pr_number bigint,
    causal_state_version text,
    evidence_id text,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    break_glass boolean DEFAULT false NOT NULL,
    status text DEFAULT 'intent_registered'::text NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    admitted_at timestamp with time zone,
    applied_at timestamp with time zone,
    verified_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_persistent_change_git_sha_chk CHECK (((git_commit_sha IS NULL) OR (git_commit_sha ~ '^[0-9a-f]{40}$'::text))),
    CONSTRAINT contentflow_persistent_change_provenance_change_class_check CHECK ((change_class = ANY (ARRAY['schema'::text, 'function'::text, 'policy'::text, 'trigger'::text, 'extension'::text, 'persistent_control'::text, 'other'::text]))),
    CONSTRAINT contentflow_persistent_change_provenance_status_check CHECK ((status = ANY (ARRAY['intent_registered'::text, 'admitted'::text, 'applied'::text, 'verified'::text, 'quarantined'::text, 'rejected'::text])))
);


--
-- Name: contentflow_persistent_change_provenance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_persistent_change_provenance ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_persistent_change_provenance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_primary_source_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_primary_source_evidence (
    id bigint NOT NULL,
    project_key text NOT NULL,
    task_key text NOT NULL,
    provider text NOT NULL,
    source_title text NOT NULL,
    source_url text NOT NULL,
    source_domain text NOT NULL,
    source_type text DEFAULT 'official_primary'::text NOT NULL,
    verification_status text DEFAULT 'verified'::text NOT NULL,
    verification_method text DEFAULT 'manual_or_tool_verified'::text NOT NULL,
    accessed_at timestamp with time zone DEFAULT now() NOT NULL,
    publication_or_update_date text,
    claim_scope text,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_primary_source_evidence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contentflow_primary_source_evidence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contentflow_primary_source_evidence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contentflow_primary_source_evidence_id_seq OWNED BY public.contentflow_primary_source_evidence.id;


--
-- Name: contentflow_retry_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_retry_policies (
    error_class text NOT NULL,
    retryable boolean NOT NULL,
    max_attempts integer DEFAULT 1 NOT NULL,
    initial_backoff_seconds integer DEFAULT 30 NOT NULL,
    backoff_coefficient numeric DEFAULT 2.0 NOT NULL,
    max_backoff_seconds integer DEFAULT 300 NOT NULL,
    jitter_ratio numeric DEFAULT 0.15 NOT NULL,
    switch_model_on_retry boolean DEFAULT true NOT NULL,
    notes text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_retry_policies_backoff_coefficient_check CHECK ((backoff_coefficient >= (1)::numeric)),
    CONSTRAINT contentflow_retry_policies_initial_backoff_seconds_check CHECK ((initial_backoff_seconds >= 0)),
    CONSTRAINT contentflow_retry_policies_jitter_ratio_check CHECK (((jitter_ratio >= (0)::numeric) AND (jitter_ratio <= 0.5))),
    CONSTRAINT contentflow_retry_policies_max_attempts_check CHECK (((max_attempts >= 0) AND (max_attempts <= 20))),
    CONSTRAINT contentflow_retry_policies_max_backoff_seconds_check CHECK ((max_backoff_seconds >= 0))
);


--
-- Name: contentflow_retry_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_retry_state (
    backlog_task_id bigint NOT NULL,
    project_key text NOT NULL,
    task_key text NOT NULL,
    error_class text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_run_id bigint,
    last_error text,
    last_model text,
    next_retry_at timestamp with time zone,
    circuit_state text DEFAULT 'closed'::text NOT NULL,
    circuit_open_until timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_retry_state_circuit_state_check CHECK ((circuit_state = ANY (ARRAY['closed'::text, 'cooldown'::text, 'open'::text])))
);


--
-- Name: contentflow_review_work_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_review_work_queue (
    builder_run_id bigint NOT NULL,
    task_key text NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    claim_token text,
    claimed_at timestamp with time zone,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_review_work_queue_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'done'::text])))
);


--
-- Name: contentflow_runtime_event_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_runtime_event_ledger (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    builder_run_id bigint NOT NULL,
    task_key text NOT NULL,
    event_type text NOT NULL,
    idempotency_key text,
    actor text,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    trace_id text,
    span_id text,
    parent_span_id text
);


--
-- Name: contentflow_runtime_event_ledger_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contentflow_runtime_event_ledger_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contentflow_runtime_event_ledger_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contentflow_runtime_event_ledger_id_seq OWNED BY public.contentflow_runtime_event_ledger.id;


--
-- Name: contentflow_runtime_evidence_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_runtime_evidence_ledger (
    id bigint NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    backlog_task_id bigint NOT NULL,
    builder_run_id bigint NOT NULL,
    task_key text NOT NULL,
    evidence_type text NOT NULL,
    evidence_key text NOT NULL,
    payload jsonb NOT NULL,
    payload_sha256 text NOT NULL,
    producer text NOT NULL,
    observed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    requirement_id bigint,
    CONSTRAINT contentflow_runtime_evidence_ledger_payload_check CHECK ((jsonb_typeof(payload) = ANY (ARRAY['object'::text, 'array'::text]))),
    CONSTRAINT contentflow_runtime_evidence_ledger_payload_sha256_check CHECK ((length(payload_sha256) = 64))
);


--
-- Name: contentflow_runtime_evidence_ledger_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_runtime_evidence_ledger ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.contentflow_runtime_evidence_ledger_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contentflow_runtime_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_runtime_verifications (
    id bigint NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    backlog_task_id bigint NOT NULL,
    builder_run_id bigint,
    task_key text NOT NULL,
    verification_type text NOT NULL,
    passed boolean DEFAULT false NOT NULL,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    verifier text DEFAULT 'runtime_verifier'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_runtime_verifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contentflow_runtime_verifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contentflow_runtime_verifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contentflow_runtime_verifications_id_seq OWNED BY public.contentflow_runtime_verifications.id;


--
-- Name: contentflow_specialist_task_record; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_specialist_task_record WITH (security_invoker='true') AS
 SELECT id AS run_id,
    project_key,
    task_key,
    task_type AS specialty,
    selected_model,
    status,
    quality_score,
    cost_usd,
    error,
    created_at,
    finished_at,
        CASE
            WHEN (finished_at IS NOT NULL) THEN (EXTRACT(epoch FROM (finished_at - created_at)) * (1000)::numeric)
            ELSE NULL::numeric
        END AS duration_ms,
        CASE
            WHEN (status = ANY (ARRAY['review_required'::text, 'completed'::text])) THEN 1
            ELSE 0
        END AS completed_flag,
        CASE
            WHEN (status = 'failed'::text) THEN 1
            ELSE 0
        END AS failed_flag
   FROM public.contentflow_builder_runs r
  WHERE (selected_model IS NOT NULL);


--
-- Name: contentflow_specialist_ranking; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_specialist_ranking WITH (security_invoker='true') AS
 SELECT project_key,
    specialty,
    selected_model,
    count(*) FILTER (WHERE (status = ANY (ARRAY['review_required'::text, 'completed'::text, 'failed'::text]))) AS evaluated_tasks,
    sum(completed_flag) AS completed_tasks,
    sum(failed_flag) AS failed_tasks,
    round(((100.0 * (sum(completed_flag))::numeric) / (NULLIF(count(*) FILTER (WHERE (status = ANY (ARRAY['review_required'::text, 'completed'::text, 'failed'::text]))), 0))::numeric), 2) AS completion_rate_pct,
    round(avg(quality_score) FILTER (WHERE (status = ANY (ARRAY['review_required'::text, 'completed'::text, 'failed'::text]))), 2) AS avg_quality_score,
    round(avg(duration_ms) FILTER (WHERE (duration_ms IS NOT NULL)), 0) AS avg_duration_ms,
    round(sum(cost_usd), 8) AS total_cost_usd,
    max(finished_at) AS last_finished_at,
    dense_rank() OVER (PARTITION BY project_key, specialty ORDER BY ((100.0 * (sum(completed_flag))::numeric) / (NULLIF(count(*) FILTER (WHERE (status = ANY (ARRAY['review_required'::text, 'completed'::text, 'failed'::text]))), 0))::numeric) DESC NULLS LAST, (avg(quality_score) FILTER (WHERE (status = ANY (ARRAY['review_required'::text, 'completed'::text, 'failed'::text])))) DESC NULLS LAST, (count(*) FILTER (WHERE (status = ANY (ARRAY['review_required'::text, 'completed'::text, 'failed'::text])))) DESC) AS specialty_rank
   FROM public.contentflow_specialist_task_record
  WHERE (selected_model IS NOT NULL)
  GROUP BY project_key, specialty, selected_model;


--
-- Name: contentflow_tenant_security_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_tenant_security_targets (
    table_name text NOT NULL,
    exposure_class text DEFAULT 'internal_only'::text NOT NULL,
    required_rls boolean DEFAULT true NOT NULL,
    notes text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_tenant_security_targets_exposure_class_check CHECK ((exposure_class = ANY (ARRAY['internal_only'::text, 'customer_candidate'::text, 'customer_approved'::text])))
);


--
-- Name: contentflow_tool_execution_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_tool_execution_queue (
    id bigint NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    backlog_task_id bigint NOT NULL,
    task_key text NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    claim_token uuid,
    claimed_at timestamp with time zone,
    completed_at timestamp with time zone,
    last_error text,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_tool_execution_queue_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text, 'failed'::text, 'blocked'::text])))
);


--
-- Name: contentflow_tool_execution_queue_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contentflow_tool_execution_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contentflow_tool_execution_queue_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contentflow_tool_execution_queue_id_seq OWNED BY public.contentflow_tool_execution_queue.id;


--
-- Name: director_trace_spans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_trace_spans (
    span_id text NOT NULL,
    trace_id text NOT NULL,
    parent_span_id text,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    cycle_id bigint,
    builder_run_id bigint,
    span_name text NOT NULL,
    span_kind text DEFAULT 'internal'::text NOT NULL,
    span_status text DEFAULT 'unset'::text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ended_at timestamp with time zone,
    attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_class text,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT director_trace_spans_span_kind_check CHECK ((span_kind = ANY (ARRAY['internal'::text, 'producer'::text, 'consumer'::text, 'client'::text, 'server'::text]))),
    CONSTRAINT director_trace_spans_span_status_check CHECK ((span_status = ANY (ARRAY['unset'::text, 'ok'::text, 'error'::text])))
);


--
-- Name: contentflow_trace_health; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contentflow_trace_health WITH (security_invoker='true') AS
 SELECT trace_id,
    count(*) AS spans,
    count(*) FILTER (WHERE (span_status = 'error'::text)) AS error_spans,
    round(avg((EXTRACT(epoch FROM (COALESCE(ended_at, now()) - started_at)) * (1000)::numeric)), 1) AS avg_span_ms,
    (max((EXTRACT(epoch FROM (COALESCE(ended_at, now()) - started_at)) * (1000)::numeric)))::bigint AS max_span_ms,
    min(started_at) AS started_at,
    max(COALESCE(ended_at, now())) AS last_activity_at
   FROM public.director_trace_spans
  GROUP BY trace_id;


--
-- Name: contentflow_wait_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_wait_registry (
    backlog_task_id bigint NOT NULL,
    project_key text NOT NULL,
    task_key text NOT NULL,
    wait_kind text NOT NULL,
    wait_key text,
    wake_at timestamp with time zone,
    terminal_reason text,
    generation bigint DEFAULT 1 NOT NULL,
    state text DEFAULT 'waiting'::text NOT NULL,
    classified_at timestamp with time zone DEFAULT now() NOT NULL,
    released_at timestamp with time zone,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_wait_registry_state_check CHECK ((state = ANY (ARRAY['waiting'::text, 'released'::text, 'terminal'::text, 'unclassified'::text]))),
    CONSTRAINT contentflow_wait_registry_wait_kind_check CHECK ((wait_kind = ANY (ARRAY['timer'::text, 'retry'::text, 'dependency'::text, 'capability'::text, 'review'::text, 'external_signal'::text, 'terminal'::text, 'unclassified'::text])))
);


--
-- Name: contentflow_workflow_e2e_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contentflow_workflow_e2e_state (
    workflow_id uuid NOT NULL,
    source_run_id bigint NOT NULL,
    status text NOT NULL,
    evidence_uri text,
    last_action_id text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contentflow_workflow_e2e_state_status_check CHECK ((status = ANY (ARRAY['in_progress'::text, 'completed'::text])))
);


--
-- Name: TABLE contentflow_workflow_e2e_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.contentflow_workflow_e2e_state IS 'Dedicated persisted E2E harness state for proving evidence-gated workflow completion; never used as production workflow state.';


--
-- Name: credit_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credit_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    type text NOT NULL,
    units numeric(10,2) NOT NULL,
    monetary_value_usd numeric(12,4),
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT credit_transactions_type_check CHECK ((type = ANY (ARRAY['grant'::text, 'usage'::text, 'extra'::text, 'expire'::text, 'adjustment'::text])))
);


--
-- Name: credit_wallets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credit_wallets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    plan text DEFAULT 'creator'::text NOT NULL,
    units_included numeric(10,2) DEFAULT 5 NOT NULL,
    units_remaining numeric(10,2) DEFAULT 5 NOT NULL,
    extra_usage_usd numeric(12,2) DEFAULT 0 NOT NULL,
    cycle_started_at timestamp with time zone DEFAULT now() NOT NULL,
    cycle_ends_at timestamp with time zone DEFAULT (now() + '1 mon'::interval) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: director_approved_solutions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_approved_solutions (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone,
    user_id uuid NOT NULL,
    project_key text NOT NULL,
    task_type text NOT NULL,
    task_fingerprint text NOT NULL,
    task text NOT NULL,
    solution text NOT NULL,
    model_id text,
    quality_score numeric DEFAULT 0 NOT NULL,
    usage_count integer DEFAULT 0 NOT NULL
);


--
-- Name: director_approved_solutions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_approved_solutions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_approved_solutions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_autonomy_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_autonomy_events (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    event_type text NOT NULL,
    task_key text,
    error_fingerprint text,
    source text,
    assignment_mode text,
    assigned_model text,
    outcome text,
    quality_score numeric,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    resolution_seconds numeric,
    required_user_intervention boolean DEFAULT false NOT NULL,
    notes text
);


--
-- Name: director_autonomy_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_autonomy_events ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_autonomy_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_autonomy_kpis; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.director_autonomy_kpis WITH (security_invoker='true') AS
 SELECT project_key,
    count(*) FILTER (WHERE (event_type = 'problem_detected'::text)) AS problems_detected,
    count(*) FILTER (WHERE ((event_type = 'problem_resolved'::text) AND (required_user_intervention = false))) AS problems_resolved_autonomously,
    count(*) FILTER (WHERE ((event_type = 'problem_escalated'::text) OR (required_user_intervention = true))) AS problems_escalated,
    round(((100.0 * (count(*) FILTER (WHERE ((event_type = 'problem_resolved'::text) AND (required_user_intervention = false))))::numeric) / (NULLIF(count(*) FILTER (WHERE (event_type = 'problem_detected'::text)), 0))::numeric), 2) AS autonomous_problem_resolution_pct,
    count(*) FILTER (WHERE ((event_type = 'task_assigned'::text) AND (assignment_mode = 'auto'::text))) AS tasks_auto_assigned,
    count(*) FILTER (WHERE ((event_type = 'task_completed'::text) AND (assignment_mode = 'auto'::text))) AS auto_assigned_tasks_completed,
    round(((100.0 * (count(*) FILTER (WHERE ((event_type = 'task_completed'::text) AND (assignment_mode = 'auto'::text))))::numeric) / (NULLIF(count(*) FILTER (WHERE ((event_type = 'task_assigned'::text) AND (assignment_mode = 'auto'::text))), 0))::numeric), 2) AS autonomous_assignment_completion_pct,
    round(avg(resolution_seconds) FILTER (WHERE ((event_type = 'problem_resolved'::text) AND (required_user_intervention = false))), 2) AS avg_autonomous_resolution_seconds,
    round(avg(quality_score) FILTER (WHERE ((event_type = 'task_completed'::text) AND (assignment_mode = 'auto'::text))), 2) AS avg_quality_auto_completed
   FROM public.director_autonomy_events
  GROUP BY project_key;


--
-- Name: director_budgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_budgets (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    project_key text NOT NULL,
    monthly_budget_usd numeric DEFAULT 10 NOT NULL,
    max_run_cost_usd numeric DEFAULT 0.05 NOT NULL,
    is_enabled boolean DEFAULT true NOT NULL,
    CONSTRAINT director_budgets_max_run_cost_usd_check CHECK ((max_run_cost_usd >= (0)::numeric)),
    CONSTRAINT director_budgets_monthly_budget_usd_check CHECK ((monthly_budget_usd >= (0)::numeric))
);


--
-- Name: director_budgets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_budgets ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_budgets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_canary_policy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_canary_policy (
    id integer DEFAULT 1 NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    bootstrap_parallelism integer DEFAULT 3 NOT NULL,
    stable_parallelism integer DEFAULT 6 NOT NULL,
    required_clean_cycles integer DEFAULT 5 NOT NULL,
    max_recent_failure_rate numeric DEFAULT 0.25 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT director_canary_policy_id_check CHECK ((id = 1))
);


--
-- Name: director_control_incident_strategy_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_control_incident_strategy_state (
    project_key text NOT NULL,
    incident_id bigint NOT NULL,
    error_fingerprint text NOT NULL,
    strategy_index integer DEFAULT 0 NOT NULL,
    last_strategy text,
    strategies_attempted jsonb DEFAULT '[]'::jsonb NOT NULL,
    last_observation jsonb DEFAULT '{}'::jsonb NOT NULL,
    exhausted boolean DEFAULT false NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT director_control_incident_strategy_state_strategy_index_check CHECK (((strategy_index >= 0) AND (strategy_index <= 3)))
);


--
-- Name: director_control_policy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_control_policy (
    project_key text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    desired_running integer DEFAULT 6 NOT NULL,
    min_ready_buffer integer DEFAULT 4 NOT NULL,
    no_progress_minutes integer DEFAULT 15 NOT NULL,
    max_open_incidents integer DEFAULT 25 NOT NULL,
    max_needs_help integer DEFAULT 0 NOT NULL,
    max_state_mismatches integer DEFAULT 0 NOT NULL,
    max_repeat_failures_24h integer DEFAULT 3 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT director_control_policy_desired_running_check CHECK ((desired_running >= 0)),
    CONSTRAINT director_control_policy_max_needs_help_check CHECK ((max_needs_help >= 0)),
    CONSTRAINT director_control_policy_max_open_incidents_check CHECK ((max_open_incidents >= 1)),
    CONSTRAINT director_control_policy_max_repeat_failures_24h_check CHECK ((max_repeat_failures_24h >= 1)),
    CONSTRAINT director_control_policy_max_state_mismatches_check CHECK ((max_state_mismatches >= 0)),
    CONSTRAINT director_control_policy_min_ready_buffer_check CHECK ((min_ready_buffer >= 0)),
    CONSTRAINT director_control_policy_no_progress_minutes_check CHECK ((no_progress_minutes >= 1))
);


--
-- Name: director_cycle_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_cycle_runs (
    id bigint NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    status text DEFAULT 'running'::text NOT NULL,
    phase text DEFAULT 'start'::text NOT NULL,
    dispatched integer DEFAULT 0 NOT NULL,
    pre_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    post_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    warnings jsonb DEFAULT '[]'::jsonb NOT NULL,
    error text,
    workflow_version text,
    trace_id text,
    CONSTRAINT director_cycle_runs_status_check CHECK ((status = ANY (ARRAY['running'::text, 'completed'::text, 'completed_with_warnings'::text, 'failed'::text, 'skipped_locked'::text])))
);


--
-- Name: director_cycle_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_cycle_runs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_cycle_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_error_memory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_error_memory (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    error_class text NOT NULL,
    error_fingerprint text NOT NULL,
    component text,
    symptom text NOT NULL,
    root_cause text,
    correction text NOT NULL,
    prevention_rule text,
    evidence text,
    occurrences integer DEFAULT 1 NOT NULL,
    correction_successes integer DEFAULT 0 NOT NULL,
    correction_failures integer DEFAULT 0 NOT NULL,
    confidence numeric DEFAULT 0.5 NOT NULL,
    status text DEFAULT 'learned'::text NOT NULL
);


--
-- Name: director_error_memory_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_error_memory ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_error_memory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_external_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_external_evidence (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text NOT NULL,
    task_key text NOT NULL,
    evidence_type text NOT NULL,
    environment text,
    engine text,
    version text,
    status text NOT NULL,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    source text NOT NULL,
    verified boolean DEFAULT false NOT NULL,
    CONSTRAINT director_external_evidence_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'pass'::text, 'fail'::text, 'blocked'::text])))
);


--
-- Name: director_external_evidence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.director_external_evidence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: director_external_evidence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.director_external_evidence_id_seq OWNED BY public.director_external_evidence.id;


--
-- Name: director_help_alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_help_alerts (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    task_key text,
    component text,
    error_class text NOT NULL,
    error_fingerprint text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    summary text NOT NULL,
    last_error text,
    actions_tried jsonb DEFAULT '[]'::jsonb NOT NULL,
    resolved_at timestamp with time zone
);


--
-- Name: director_help_alerts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_help_alerts ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_help_alerts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_model_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_model_stats (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    project_key text NOT NULL,
    task_type text NOT NULL,
    model_id text NOT NULL,
    runs integer DEFAULT 0 NOT NULL,
    successes integer DEFAULT 0 NOT NULL,
    avg_quality numeric DEFAULT 0 NOT NULL,
    avg_latency_ms numeric DEFAULT 0 NOT NULL,
    avg_cost_usd numeric DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: director_model_stats_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_model_stats ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_model_stats_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_operating_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_operating_rules (
    id bigint NOT NULL,
    rule_key text NOT NULL,
    rule_text text NOT NULL,
    target_pct numeric DEFAULT 100 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: director_operating_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_operating_rules ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_operating_rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_project_task_scope; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_project_task_scope (
    project_key text NOT NULL,
    task_key text NOT NULL,
    scope_class text NOT NULL,
    counts_toward_progress boolean DEFAULT true NOT NULL,
    reason text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT director_project_task_scope_scope_class_check CHECK ((scope_class = ANY (ARRAY['product'::text, 'infrastructure'::text, 'obsolete_evidence'::text])))
);


--
-- Name: director_recovery_learning_memory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_recovery_learning_memory (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text NOT NULL,
    incident_fingerprint text NOT NULL,
    root_cause text NOT NULL,
    repair_id text NOT NULL,
    evidence_ids text[] DEFAULT '{}'::text[] NOT NULL,
    validation text NOT NULL,
    authority text NOT NULL,
    risk_level text NOT NULL,
    rollback_evidence_id text,
    certified_passes integer DEFAULT 0 NOT NULL,
    reuse_count integer DEFAULT 0 NOT NULL,
    last_reused_at timestamp with time zone,
    enabled boolean DEFAULT true NOT NULL,
    context_version text,
    canonical_fingerprint text,
    legacy_fingerprint text,
    recertification_required boolean DEFAULT false NOT NULL,
    certified_context jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT director_recovery_learning_memory_authority_check CHECK ((authority = ANY (ARRAY['rara_autonomous'::text, 'canary_then_director'::text, 'owner_required'::text]))),
    CONSTRAINT director_recovery_learning_memory_certified_passes_check CHECK ((certified_passes >= 0)),
    CONSTRAINT director_recovery_learning_memory_reuse_count_check CHECK ((reuse_count >= 0)),
    CONSTRAINT director_recovery_learning_memory_risk_level_check CHECK ((risk_level = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text, 'critical'::text]))),
    CONSTRAINT director_recovery_learning_memory_validation_check CHECK ((validation = ANY (ARRAY['pass'::text, 'fail'::text])))
);


--
-- Name: TABLE director_recovery_learning_memory; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.director_recovery_learning_memory IS 'Certified recovery memory. Exact fingerprints only; autonomous reuse is canary-scoped and fail-closed.';


--
-- Name: director_recovery_learning_memory_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_recovery_learning_memory ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_recovery_learning_memory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_repair_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_repair_actions (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    incident_id bigint NOT NULL,
    action_type text NOT NULL,
    action_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    risk_level text DEFAULT 'low'::text NOT NULL,
    status text DEFAULT 'proposed'::text NOT NULL,
    result jsonb,
    error text
);


--
-- Name: director_repair_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.director_repair_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: director_repair_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.director_repair_actions_id_seq OWNED BY public.director_repair_actions.id;


--
-- Name: director_repair_incidents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_repair_incidents (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    task_key text,
    component text DEFAULT 'unknown'::text NOT NULL,
    error_class text DEFAULT 'unknown'::text NOT NULL,
    error_fingerprint text NOT NULL,
    symptom text,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 3 NOT NULL,
    risk_level text DEFAULT 'low'::text NOT NULL,
    assigned_model text,
    diagnosis text,
    root_cause text,
    proposed_action text,
    executed_action text,
    validation text,
    outcome text,
    requires_human boolean DEFAULT false NOT NULL
);


--
-- Name: director_repair_incidents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.director_repair_incidents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: director_repair_incidents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.director_repair_incidents_id_seq OWNED BY public.director_repair_incidents.id;


--
-- Name: director_repair_recipes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_repair_recipes (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    recipe_key text NOT NULL,
    error_class text,
    component text,
    fingerprint_prefix text,
    action_type text NOT NULL,
    action_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    risk_level text DEFAULT 'low'::text NOT NULL,
    min_confidence numeric DEFAULT 0.80 NOT NULL,
    confidence numeric DEFAULT 0.80 NOT NULL,
    successes integer DEFAULT 0 NOT NULL,
    failures integer DEFAULT 0 NOT NULL,
    max_consecutive_failures integer DEFAULT 2 NOT NULL,
    validation_type text DEFAULT 'state_reconciled'::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    notes text
);


--
-- Name: director_repair_recipes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_repair_recipes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_repair_recipes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_resilience_checks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_resilience_checks (
    id bigint NOT NULL,
    project_key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    check_name text NOT NULL,
    status text NOT NULL,
    observed jsonb DEFAULT '{}'::jsonb NOT NULL,
    expected jsonb DEFAULT '{}'::jsonb NOT NULL,
    trace_id text,
    CONSTRAINT director_resilience_checks_status_check CHECK ((status = ANY (ARRAY['pass'::text, 'fail'::text, 'warn'::text])))
);


--
-- Name: director_resilience_checks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_resilience_checks ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_resilience_checks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_runs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    project_key text NOT NULL,
    task_type text NOT NULL,
    task text NOT NULL,
    selected_model text,
    fallback_used boolean DEFAULT false NOT NULL,
    ok boolean DEFAULT false NOT NULL,
    total_cost_usd numeric(14,8) DEFAULT 0 NOT NULL,
    attempts jsonb DEFAULT '[]'::jsonb NOT NULL,
    input_tokens bigint DEFAULT 0 NOT NULL,
    output_tokens bigint DEFAULT 0 NOT NULL,
    judge_input_tokens bigint DEFAULT 0 NOT NULL,
    judge_output_tokens bigint DEFAULT 0 NOT NULL
);


--
-- Name: director_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_runs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_state_transition_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_state_transition_ledger (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    workflow_version text NOT NULL,
    trace_id text,
    entity_type text NOT NULL,
    entity_key text NOT NULL,
    from_state text,
    to_state text NOT NULL,
    actor text DEFAULT 'system'::text NOT NULL,
    reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: director_state_transition_ledger_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.director_state_transition_ledger_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: director_state_transition_ledger_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.director_state_transition_ledger_id_seq OWNED BY public.director_state_transition_ledger.id;


--
-- Name: director_task_decompositions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_task_decompositions (
    id bigint NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    parent_task_key text NOT NULL,
    planner_version text DEFAULT 'v1'::text NOT NULL,
    child_task_keys jsonb DEFAULT '[]'::jsonb NOT NULL,
    rationale text,
    status text DEFAULT 'applied'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT director_task_decompositions_status_check CHECK ((status = ANY (ARRAY['applied'::text, 'skipped'::text, 'superseded'::text])))
);


--
-- Name: director_task_decompositions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.director_task_decompositions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.director_task_decompositions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: director_worker_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_worker_queue (
    model_id text NOT NULL,
    status text DEFAULT 'ready'::text NOT NULL,
    current_task_key text,
    last_task_key text,
    last_outcome text,
    last_quality_score numeric,
    last_started_at timestamp with time zone,
    last_finished_at timestamp with time zone,
    total_assignments integer DEFAULT 0 NOT NULL,
    total_completions integer DEFAULT 0 NOT NULL,
    total_failures integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: director_workflow_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.director_workflow_versions (
    version text NOT NULL,
    project_key text DEFAULT 'contentflow'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    architecture jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    activated_at timestamp with time zone,
    retired_at timestamp with time zone
);


--
-- Name: generations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    project_id uuid,
    provider text NOT NULL,
    model text NOT NULL,
    generation_type text NOT NULL,
    prompt_tokens bigint DEFAULT 0 NOT NULL,
    completion_tokens bigint DEFAULT 0 NOT NULL,
    actual_cost_usd numeric(12,6) DEFAULT 0 NOT NULL,
    latency_ms integer,
    quality_score numeric(5,2),
    status text DEFAULT 'queued'::text NOT NULL,
    output_json jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    orchestrator_run_id bigint
);


--
-- Name: jarvis_device_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jarvis_device_tokens (
    token_hash text NOT NULL,
    label text DEFAULT 'jarvis-desktop'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone
);


--
-- Name: jarvis_pairing_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jarvis_pairing_codes (
    code_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: marketing_memory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketing_memory (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    brand_id uuid,
    memory_type text NOT NULL,
    key text NOT NULL,
    value jsonb NOT NULL,
    confidence numeric(5,2),
    source text,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: nexorouter_usage_reconciliation; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.nexorouter_usage_reconciliation AS
 SELECT id AS director_run_id,
    created_at,
    project_key,
    selected_model,
    COALESCE(input_tokens, (0)::bigint) AS model_input_tokens,
    COALESCE(output_tokens, (0)::bigint) AS model_output_tokens,
    COALESCE(judge_input_tokens, (0)::bigint) AS judge_input_tokens,
    COALESCE(judge_output_tokens, (0)::bigint) AS judge_output_tokens,
    (((COALESCE(input_tokens, (0)::bigint) + COALESCE(output_tokens, (0)::bigint)) + COALESCE(judge_input_tokens, (0)::bigint)) + COALESCE(judge_output_tokens, (0)::bigint)) AS total_reported_tokens,
    total_cost_usd AS estimated_cost_usd,
    'dashboard_usage_logs_required'::text AS actual_billing_source,
    NULL::numeric AS actual_charged_usd,
        CASE
            WHEN (total_cost_usd > (0)::numeric) THEN 'estimated_only'::text
            ELSE 'no_estimated_cost'::text
        END AS reconciliation_status
   FROM public.director_runs dr;


--
-- Name: orchestrator_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orchestrator_runs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    project_key text NOT NULL,
    objective text NOT NULL,
    status text DEFAULT 'planning'::text NOT NULL,
    plan jsonb DEFAULT '[]'::jsonb NOT NULL,
    final_result text,
    total_cost_usd numeric DEFAULT 0 NOT NULL,
    input_tokens bigint DEFAULT 0 NOT NULL,
    output_tokens bigint DEFAULT 0 NOT NULL,
    CONSTRAINT orchestrator_runs_status_check CHECK ((status = ANY (ARRAY['planning'::text, 'running'::text, 'integrating'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: orchestrator_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.orchestrator_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: orchestrator_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.orchestrator_runs_id_seq OWNED BY public.orchestrator_runs.id;


--
-- Name: orchestrator_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orchestrator_tasks (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    run_id bigint NOT NULL,
    user_id uuid NOT NULL,
    project_key text NOT NULL,
    task_key text NOT NULL,
    task_type text NOT NULL,
    title text NOT NULL,
    instruction text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    selected_model text,
    quality_score numeric DEFAULT 0 NOT NULL,
    cost_usd numeric DEFAULT 0 NOT NULL,
    result text,
    error text,
    depends_on jsonb DEFAULT '[]'::jsonb NOT NULL,
    stage integer DEFAULT 1 NOT NULL,
    input_tokens bigint DEFAULT 0 NOT NULL,
    output_tokens bigint DEFAULT 0 NOT NULL,
    CONSTRAINT orchestrator_tasks_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'completed'::text, 'failed'::text, 'blocked'::text])))
);


--
-- Name: orchestrator_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.orchestrator_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: orchestrator_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.orchestrator_tasks_id_seq OWNED BY public.orchestrator_tasks.id;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    display_name text DEFAULT ''::text,
    plan text DEFAULT 'creator'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT profiles_plan_check CHECK ((plan = ANY (ARRAY['creator'::text, 'pro'::text, 'marketer'::text, 'business'::text])))
);


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    brand_id uuid,
    title text NOT NULL,
    goal text,
    duration_seconds integer DEFAULT 30 NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: provider_costs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_costs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider text NOT NULL,
    model text NOT NULL,
    task_type text NOT NULL,
    input_cost_per_million numeric(16,8),
    output_cost_per_million numeric(16,8),
    cost_per_second numeric(16,8),
    cost_per_image numeric(16,8),
    quality_floor numeric(5,2) DEFAULT 85,
    active boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: social_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.social_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    brand_id uuid,
    platform text NOT NULL,
    external_account_id text,
    display_name text,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    connection_status text DEFAULT 'disconnected'::text NOT NULL,
    connected_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: social_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.social_metrics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    social_account_id uuid NOT NULL,
    content_id text,
    metric_date date NOT NULL,
    metrics jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    provider text,
    external_subscription_id text,
    plan text DEFAULT 'creator'::text NOT NULL,
    status text DEFAULT 'inactive'::text NOT NULL,
    current_period_start timestamp with time zone,
    current_period_end timestamp with time zone,
    cancel_at_period_end boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: youtube_oauth_token_vault; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.youtube_oauth_token_vault (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id text NOT NULL,
    channel_title text,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    access_token_ciphertext text NOT NULL,
    access_token_iv text NOT NULL,
    access_token_tag text NOT NULL,
    refresh_token_ciphertext text,
    refresh_token_iv text,
    refresh_token_tag text,
    token_fingerprint text NOT NULL,
    access_expires_at timestamp with time zone,
    refresh_token_received boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contentflow_evidence_requirements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_evidence_requirements ALTER COLUMN id SET DEFAULT nextval('public.contentflow_evidence_requirements_id_seq'::regclass);


--
-- Name: contentflow_primary_source_evidence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_primary_source_evidence ALTER COLUMN id SET DEFAULT nextval('public.contentflow_primary_source_evidence_id_seq'::regclass);


--
-- Name: contentflow_runtime_event_ledger id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_event_ledger ALTER COLUMN id SET DEFAULT nextval('public.contentflow_runtime_event_ledger_id_seq'::regclass);


--
-- Name: contentflow_runtime_verifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_verifications ALTER COLUMN id SET DEFAULT nextval('public.contentflow_runtime_verifications_id_seq'::regclass);


--
-- Name: contentflow_tool_execution_queue id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_tool_execution_queue ALTER COLUMN id SET DEFAULT nextval('public.contentflow_tool_execution_queue_id_seq'::regclass);


--
-- Name: director_external_evidence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_external_evidence ALTER COLUMN id SET DEFAULT nextval('public.director_external_evidence_id_seq'::regclass);


--
-- Name: director_repair_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_repair_actions ALTER COLUMN id SET DEFAULT nextval('public.director_repair_actions_id_seq'::regclass);


--
-- Name: director_repair_incidents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_repair_incidents ALTER COLUMN id SET DEFAULT nextval('public.director_repair_incidents_id_seq'::regclass);


--
-- Name: director_state_transition_ledger id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_state_transition_ledger ALTER COLUMN id SET DEFAULT nextval('public.director_state_transition_ledger_id_seq'::regclass);


--
-- Name: orchestrator_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_runs ALTER COLUMN id SET DEFAULT nextval('public.orchestrator_runs_id_seq'::regclass);


--
-- Name: orchestrator_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_tasks ALTER COLUMN id SET DEFAULT nextval('public.orchestrator_tasks_id_seq'::regclass);


--
-- Name: academy_whatsapp_config academy_whatsapp_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_config
    ADD CONSTRAINT academy_whatsapp_config_pkey PRIMARY KEY (id);


--
-- Name: academy_whatsapp_conversations academy_whatsapp_conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_conversations
    ADD CONSTRAINT academy_whatsapp_conversations_pkey PRIMARY KEY (id);


--
-- Name: academy_whatsapp_conversations academy_whatsapp_conversations_wa_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_conversations
    ADD CONSTRAINT academy_whatsapp_conversations_wa_id_key UNIQUE (wa_id);


--
-- Name: academy_whatsapp_handoffs academy_whatsapp_handoffs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_handoffs
    ADD CONSTRAINT academy_whatsapp_handoffs_pkey PRIMARY KEY (id);


--
-- Name: academy_whatsapp_knowledge academy_whatsapp_knowledge_intent_language_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_knowledge
    ADD CONSTRAINT academy_whatsapp_knowledge_intent_language_key UNIQUE (intent, language);


--
-- Name: academy_whatsapp_knowledge academy_whatsapp_knowledge_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_knowledge
    ADD CONSTRAINT academy_whatsapp_knowledge_pkey PRIMARY KEY (id);


--
-- Name: academy_whatsapp_messages academy_whatsapp_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_messages
    ADD CONSTRAINT academy_whatsapp_messages_pkey PRIMARY KEY (id);


--
-- Name: academy_whatsapp_messages academy_whatsapp_messages_whatsapp_message_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_messages
    ADD CONSTRAINT academy_whatsapp_messages_whatsapp_message_id_key UNIQUE (whatsapp_message_id);


--
-- Name: academy_whatsapp_outbox academy_whatsapp_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_outbox
    ADD CONSTRAINT academy_whatsapp_outbox_pkey PRIMARY KEY (id);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: content_schedule content_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_schedule
    ADD CONSTRAINT content_schedule_pkey PRIMARY KEY (id);


--
-- Name: contentflow_build_backlog contentflow_build_backlog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_build_backlog
    ADD CONSTRAINT contentflow_build_backlog_pkey PRIMARY KEY (id);


--
-- Name: contentflow_build_backlog contentflow_build_backlog_project_key_task_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_build_backlog
    ADD CONSTRAINT contentflow_build_backlog_project_key_task_key_key UNIQUE (project_key, task_key);


--
-- Name: contentflow_builder_dispatches contentflow_builder_dispatches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_builder_dispatches
    ADD CONSTRAINT contentflow_builder_dispatches_pkey PRIMARY KEY (request_id);


--
-- Name: contentflow_builder_runs contentflow_builder_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_builder_runs
    ADD CONSTRAINT contentflow_builder_runs_pkey PRIMARY KEY (id);


--
-- Name: contentflow_capability_certifications contentflow_capability_certifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_capability_certifications
    ADD CONSTRAINT contentflow_capability_certifications_pkey PRIMARY KEY (prerequisite);


--
-- Name: contentflow_capacity_decisions contentflow_capacity_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_capacity_decisions
    ADD CONSTRAINT contentflow_capacity_decisions_pkey PRIMARY KEY (id);


--
-- Name: contentflow_capacity_phases contentflow_capacity_phases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_capacity_phases
    ADD CONSTRAINT contentflow_capacity_phases_pkey PRIMARY KEY (phase);


--
-- Name: contentflow_capacity_state contentflow_capacity_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_capacity_state
    ADD CONSTRAINT contentflow_capacity_state_pkey PRIMARY KEY (id);


--
-- Name: contentflow_continuation_state contentflow_continuation_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_continuation_state
    ADD CONSTRAINT contentflow_continuation_state_pkey PRIMARY KEY (project_key);


--
-- Name: contentflow_durable_signal_ledger contentflow_durable_signal_le_project_key_task_key_signal_k_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_durable_signal_ledger
    ADD CONSTRAINT contentflow_durable_signal_le_project_key_task_key_signal_k_key UNIQUE (project_key, task_key, signal_key, signal_id);


--
-- Name: contentflow_durable_signal_ledger contentflow_durable_signal_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_durable_signal_ledger
    ADD CONSTRAINT contentflow_durable_signal_ledger_pkey PRIMARY KEY (id);


--
-- Name: contentflow_durable_task_stages contentflow_durable_task_stages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_durable_task_stages
    ADD CONSTRAINT contentflow_durable_task_stages_pkey PRIMARY KEY (backlog_task_id, stage_name);


--
-- Name: contentflow_evidence_capability_registry contentflow_evidence_capability_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_evidence_capability_registry
    ADD CONSTRAINT contentflow_evidence_capability_registry_pkey PRIMARY KEY (prerequisite);


--
-- Name: contentflow_evidence_producer_recipes contentflow_evidence_producer_project_key_evidence_task_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_evidence_producer_recipes
    ADD CONSTRAINT contentflow_evidence_producer_project_key_evidence_task_key_key UNIQUE (project_key, evidence_task_key);


--
-- Name: contentflow_evidence_producer_recipes contentflow_evidence_producer_recipes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_evidence_producer_recipes
    ADD CONSTRAINT contentflow_evidence_producer_recipes_pkey PRIMARY KEY (id);


--
-- Name: contentflow_evidence_requirements contentflow_evidence_requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_evidence_requirements
    ADD CONSTRAINT contentflow_evidence_requirements_pkey PRIMARY KEY (id);


--
-- Name: contentflow_external_executor_registry contentflow_external_executor_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_external_executor_registry
    ADD CONSTRAINT contentflow_external_executor_registry_pkey PRIMARY KEY (project_key, executor_key);


--
-- Name: contentflow_external_reports contentflow_external_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_external_reports
    ADD CONSTRAINT contentflow_external_reports_pkey PRIMARY KEY (report_key);


--
-- Name: contentflow_fresh10_items contentflow_fresh10_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_fresh10_items
    ADD CONSTRAINT contentflow_fresh10_items_pkey PRIMARY KEY (id);


--
-- Name: contentflow_fresh10_items contentflow_fresh10_items_run_id_model_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_fresh10_items
    ADD CONSTRAINT contentflow_fresh10_items_run_id_model_key UNIQUE (run_id, model);


--
-- Name: contentflow_fresh10_items contentflow_fresh10_items_run_id_slot_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_fresh10_items
    ADD CONSTRAINT contentflow_fresh10_items_run_id_slot_key UNIQUE (run_id, slot);


--
-- Name: contentflow_fresh10_runs contentflow_fresh10_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_fresh10_runs
    ADD CONSTRAINT contentflow_fresh10_runs_pkey PRIMARY KEY (id);


--
-- Name: contentflow_internal_runner_config contentflow_internal_runner_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_internal_runner_config
    ADD CONSTRAINT contentflow_internal_runner_config_pkey PRIMARY KEY (id);


--
-- Name: contentflow_lane_models contentflow_lane_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_lane_models
    ADD CONSTRAINT contentflow_lane_models_pkey PRIMARY KEY (lane);


--
-- Name: contentflow_legal_governance_profiles contentflow_legal_governance_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_legal_governance_profiles
    ADD CONSTRAINT contentflow_legal_governance_profiles_pkey PRIMARY KEY (project_key);


--
-- Name: contentflow_model_task_quarantine contentflow_model_task_quarantine_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_model_task_quarantine
    ADD CONSTRAINT contentflow_model_task_quarantine_pkey PRIMARY KEY (project_key, task_key, model_id);


--
-- Name: contentflow_nexo_request_metrics contentflow_nexo_request_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_nexo_request_metrics
    ADD CONSTRAINT contentflow_nexo_request_metrics_pkey PRIMARY KEY (id);


--
-- Name: contentflow_nexo_slots contentflow_nexo_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_nexo_slots
    ADD CONSTRAINT contentflow_nexo_slots_pkey PRIMARY KEY (slot_id);


--
-- Name: contentflow_persistent_change_provenance contentflow_persistent_change_provenance_change_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_persistent_change_provenance
    ADD CONSTRAINT contentflow_persistent_change_provenance_change_id_key UNIQUE (change_id);


--
-- Name: contentflow_persistent_change_provenance contentflow_persistent_change_provenance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_persistent_change_provenance
    ADD CONSTRAINT contentflow_persistent_change_provenance_pkey PRIMARY KEY (id);


--
-- Name: contentflow_primary_source_evidence contentflow_primary_source_ev_project_key_task_key_source_u_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_primary_source_evidence
    ADD CONSTRAINT contentflow_primary_source_ev_project_key_task_key_source_u_key UNIQUE (project_key, task_key, source_url);


--
-- Name: contentflow_primary_source_evidence contentflow_primary_source_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_primary_source_evidence
    ADD CONSTRAINT contentflow_primary_source_evidence_pkey PRIMARY KEY (id);


--
-- Name: contentflow_retry_policies contentflow_retry_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_retry_policies
    ADD CONSTRAINT contentflow_retry_policies_pkey PRIMARY KEY (error_class);


--
-- Name: contentflow_retry_state contentflow_retry_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_retry_state
    ADD CONSTRAINT contentflow_retry_state_pkey PRIMARY KEY (backlog_task_id);


--
-- Name: contentflow_review_work_queue contentflow_review_work_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_review_work_queue
    ADD CONSTRAINT contentflow_review_work_queue_pkey PRIMARY KEY (builder_run_id);


--
-- Name: contentflow_runtime_event_ledger contentflow_runtime_event_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_event_ledger
    ADD CONSTRAINT contentflow_runtime_event_ledger_pkey PRIMARY KEY (id);


--
-- Name: contentflow_runtime_evidence_ledger contentflow_runtime_evidence__project_key_builder_run_id_ev_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_evidence_ledger
    ADD CONSTRAINT contentflow_runtime_evidence__project_key_builder_run_id_ev_key UNIQUE (project_key, builder_run_id, evidence_key, payload_sha256);


--
-- Name: contentflow_runtime_evidence_ledger contentflow_runtime_evidence_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_evidence_ledger
    ADD CONSTRAINT contentflow_runtime_evidence_ledger_pkey PRIMARY KEY (id);


--
-- Name: contentflow_runtime_verifications contentflow_runtime_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_verifications
    ADD CONSTRAINT contentflow_runtime_verifications_pkey PRIMARY KEY (id);


--
-- Name: contentflow_tenant_security_targets contentflow_tenant_security_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_tenant_security_targets
    ADD CONSTRAINT contentflow_tenant_security_targets_pkey PRIMARY KEY (table_name);


--
-- Name: contentflow_tool_execution_queue contentflow_tool_execution_queu_project_key_backlog_task_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_tool_execution_queue
    ADD CONSTRAINT contentflow_tool_execution_queu_project_key_backlog_task_id_key UNIQUE (project_key, backlog_task_id);


--
-- Name: contentflow_tool_execution_queue contentflow_tool_execution_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_tool_execution_queue
    ADD CONSTRAINT contentflow_tool_execution_queue_pkey PRIMARY KEY (id);


--
-- Name: contentflow_wait_registry contentflow_wait_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_wait_registry
    ADD CONSTRAINT contentflow_wait_registry_pkey PRIMARY KEY (backlog_task_id);


--
-- Name: contentflow_wait_registry contentflow_wait_registry_project_key_task_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_wait_registry
    ADD CONSTRAINT contentflow_wait_registry_project_key_task_key_key UNIQUE (project_key, task_key);


--
-- Name: contentflow_workflow_e2e_state contentflow_workflow_e2e_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_workflow_e2e_state
    ADD CONSTRAINT contentflow_workflow_e2e_state_pkey PRIMARY KEY (workflow_id);


--
-- Name: credit_transactions credit_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_transactions
    ADD CONSTRAINT credit_transactions_pkey PRIMARY KEY (id);


--
-- Name: credit_wallets credit_wallets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_wallets
    ADD CONSTRAINT credit_wallets_pkey PRIMARY KEY (id);


--
-- Name: credit_wallets credit_wallets_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_wallets
    ADD CONSTRAINT credit_wallets_user_id_key UNIQUE (user_id);


--
-- Name: director_approved_solutions director_approved_solutions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_approved_solutions
    ADD CONSTRAINT director_approved_solutions_pkey PRIMARY KEY (id);


--
-- Name: director_approved_solutions director_approved_solutions_user_id_project_key_task_finger_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_approved_solutions
    ADD CONSTRAINT director_approved_solutions_user_id_project_key_task_finger_key UNIQUE (user_id, project_key, task_fingerprint);


--
-- Name: director_autonomy_events director_autonomy_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_autonomy_events
    ADD CONSTRAINT director_autonomy_events_pkey PRIMARY KEY (id);


--
-- Name: director_budgets director_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_budgets
    ADD CONSTRAINT director_budgets_pkey PRIMARY KEY (id);


--
-- Name: director_budgets director_budgets_user_id_project_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_budgets
    ADD CONSTRAINT director_budgets_user_id_project_key_key UNIQUE (user_id, project_key);


--
-- Name: director_canary_policy director_canary_policy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_canary_policy
    ADD CONSTRAINT director_canary_policy_pkey PRIMARY KEY (id);


--
-- Name: director_control_incident_strategy_state director_control_incident_strategy_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_control_incident_strategy_state
    ADD CONSTRAINT director_control_incident_strategy_state_pkey PRIMARY KEY (incident_id);


--
-- Name: director_control_policy director_control_policy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_control_policy
    ADD CONSTRAINT director_control_policy_pkey PRIMARY KEY (project_key);


--
-- Name: director_cycle_runs director_cycle_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_cycle_runs
    ADD CONSTRAINT director_cycle_runs_pkey PRIMARY KEY (id);


--
-- Name: director_error_memory director_error_memory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_error_memory
    ADD CONSTRAINT director_error_memory_pkey PRIMARY KEY (id);


--
-- Name: director_error_memory director_error_memory_project_key_error_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_error_memory
    ADD CONSTRAINT director_error_memory_project_key_error_fingerprint_key UNIQUE (project_key, error_fingerprint);


--
-- Name: director_external_evidence director_external_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_external_evidence
    ADD CONSTRAINT director_external_evidence_pkey PRIMARY KEY (id);


--
-- Name: director_help_alerts director_help_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_help_alerts
    ADD CONSTRAINT director_help_alerts_pkey PRIMARY KEY (id);


--
-- Name: director_model_stats director_model_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_model_stats
    ADD CONSTRAINT director_model_stats_pkey PRIMARY KEY (id);


--
-- Name: director_model_stats director_model_stats_user_id_project_key_task_type_model_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_model_stats
    ADD CONSTRAINT director_model_stats_user_id_project_key_task_type_model_id_key UNIQUE (user_id, project_key, task_type, model_id);


--
-- Name: director_operating_rules director_operating_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_operating_rules
    ADD CONSTRAINT director_operating_rules_pkey PRIMARY KEY (id);


--
-- Name: director_operating_rules director_operating_rules_rule_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_operating_rules
    ADD CONSTRAINT director_operating_rules_rule_key_key UNIQUE (rule_key);


--
-- Name: director_project_task_scope director_project_task_scope_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_project_task_scope
    ADD CONSTRAINT director_project_task_scope_pkey PRIMARY KEY (project_key, task_key);


--
-- Name: director_recovery_learning_memory director_recovery_learning_me_project_key_incident_fingerpr_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_recovery_learning_memory
    ADD CONSTRAINT director_recovery_learning_me_project_key_incident_fingerpr_key UNIQUE (project_key, incident_fingerprint, repair_id);


--
-- Name: director_recovery_learning_memory director_recovery_learning_memory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_recovery_learning_memory
    ADD CONSTRAINT director_recovery_learning_memory_pkey PRIMARY KEY (id);


--
-- Name: director_repair_actions director_repair_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_repair_actions
    ADD CONSTRAINT director_repair_actions_pkey PRIMARY KEY (id);


--
-- Name: director_repair_incidents director_repair_incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_repair_incidents
    ADD CONSTRAINT director_repair_incidents_pkey PRIMARY KEY (id);


--
-- Name: director_repair_recipes director_repair_recipes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_repair_recipes
    ADD CONSTRAINT director_repair_recipes_pkey PRIMARY KEY (id);


--
-- Name: director_repair_recipes director_repair_recipes_project_key_recipe_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_repair_recipes
    ADD CONSTRAINT director_repair_recipes_project_key_recipe_key_key UNIQUE (project_key, recipe_key);


--
-- Name: director_resilience_checks director_resilience_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_resilience_checks
    ADD CONSTRAINT director_resilience_checks_pkey PRIMARY KEY (id);


--
-- Name: director_runs director_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_runs
    ADD CONSTRAINT director_runs_pkey PRIMARY KEY (id);


--
-- Name: director_state_transition_ledger director_state_transition_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_state_transition_ledger
    ADD CONSTRAINT director_state_transition_ledger_pkey PRIMARY KEY (id);


--
-- Name: director_task_decompositions director_task_decompositions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_task_decompositions
    ADD CONSTRAINT director_task_decompositions_pkey PRIMARY KEY (id);


--
-- Name: director_task_decompositions director_task_decompositions_project_key_parent_task_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_task_decompositions
    ADD CONSTRAINT director_task_decompositions_project_key_parent_task_key_key UNIQUE (project_key, parent_task_key);


--
-- Name: director_trace_spans director_trace_spans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_trace_spans
    ADD CONSTRAINT director_trace_spans_pkey PRIMARY KEY (span_id);


--
-- Name: director_worker_queue director_worker_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_worker_queue
    ADD CONSTRAINT director_worker_queue_pkey PRIMARY KEY (model_id);


--
-- Name: director_workflow_versions director_workflow_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_workflow_versions
    ADD CONSTRAINT director_workflow_versions_pkey PRIMARY KEY (version);


--
-- Name: generations generations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generations
    ADD CONSTRAINT generations_pkey PRIMARY KEY (id);


--
-- Name: jarvis_device_tokens jarvis_device_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jarvis_device_tokens
    ADD CONSTRAINT jarvis_device_tokens_pkey PRIMARY KEY (token_hash);


--
-- Name: jarvis_pairing_codes jarvis_pairing_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jarvis_pairing_codes
    ADD CONSTRAINT jarvis_pairing_codes_pkey PRIMARY KEY (code_hash);


--
-- Name: marketing_memory marketing_memory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_memory
    ADD CONSTRAINT marketing_memory_pkey PRIMARY KEY (id);


--
-- Name: orchestrator_runs orchestrator_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_runs
    ADD CONSTRAINT orchestrator_runs_pkey PRIMARY KEY (id);


--
-- Name: orchestrator_tasks orchestrator_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_tasks
    ADD CONSTRAINT orchestrator_tasks_pkey PRIMARY KEY (id);


--
-- Name: orchestrator_tasks orchestrator_tasks_run_id_task_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_tasks
    ADD CONSTRAINT orchestrator_tasks_run_id_task_key_key UNIQUE (run_id, task_key);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_key UNIQUE (user_id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: provider_costs provider_costs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_costs
    ADD CONSTRAINT provider_costs_pkey PRIMARY KEY (id);


--
-- Name: provider_costs provider_costs_provider_model_task_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_costs
    ADD CONSTRAINT provider_costs_provider_model_task_type_key UNIQUE (provider, model, task_type);


--
-- Name: social_accounts social_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_accounts
    ADD CONSTRAINT social_accounts_pkey PRIMARY KEY (id);


--
-- Name: social_accounts social_accounts_user_id_platform_external_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_accounts
    ADD CONSTRAINT social_accounts_user_id_platform_external_account_id_key UNIQUE (user_id, platform, external_account_id);


--
-- Name: social_metrics social_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_metrics
    ADD CONSTRAINT social_metrics_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_key UNIQUE (user_id);


--
-- Name: youtube_oauth_token_vault youtube_oauth_token_vault_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.youtube_oauth_token_vault
    ADD CONSTRAINT youtube_oauth_token_vault_channel_id_key UNIQUE (channel_id);


--
-- Name: youtube_oauth_token_vault youtube_oauth_token_vault_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.youtube_oauth_token_vault
    ADD CONSTRAINT youtube_oauth_token_vault_pkey PRIMARY KEY (id);


--
-- Name: academy_whatsapp_handoffs_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX academy_whatsapp_handoffs_status_idx ON public.academy_whatsapp_handoffs USING btree (status, requested_at);


--
-- Name: academy_whatsapp_messages_conversation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX academy_whatsapp_messages_conversation_idx ON public.academy_whatsapp_messages USING btree (conversation_id, created_at DESC);


--
-- Name: academy_whatsapp_outbox_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX academy_whatsapp_outbox_status_idx ON public.academy_whatsapp_outbox USING btree (status, created_at);


--
-- Name: contentflow_build_backlog_next_eligible_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_build_backlog_next_eligible_idx ON public.contentflow_build_backlog USING btree (project_key, status, next_eligible_at, priority DESC);


--
-- Name: contentflow_builder_runs_idempotency_key_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contentflow_builder_runs_idempotency_key_uq ON public.contentflow_builder_runs USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: contentflow_builder_runs_one_active_per_task; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contentflow_builder_runs_one_active_per_task ON public.contentflow_builder_runs USING btree (backlog_task_id) WHERE (status = ANY (ARRAY['claimed'::text, 'running'::text, 'review_required'::text]));


--
-- Name: contentflow_builder_runs_one_active_per_worker; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contentflow_builder_runs_one_active_per_worker ON public.contentflow_builder_runs USING btree (selected_model) WHERE ((selected_model IS NOT NULL) AND (status = ANY (ARRAY['claimed'::text, 'running'::text])));


--
-- Name: contentflow_builder_runs_task_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_builder_runs_task_idx ON public.contentflow_builder_runs USING btree (backlog_task_id, created_at DESC);


--
-- Name: contentflow_builder_runs_trace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_builder_runs_trace_idx ON public.contentflow_builder_runs USING btree (trace_id);


--
-- Name: contentflow_evidence_requirements_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_evidence_requirements_status_idx ON public.contentflow_evidence_requirements USING btree (project_key, status, updated_at);


--
-- Name: contentflow_nexo_request_metrics_recent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_nexo_request_metrics_recent_idx ON public.contentflow_nexo_request_metrics USING btree (created_at DESC, lane);


--
-- Name: contentflow_nexo_request_metrics_task_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_nexo_request_metrics_task_idx ON public.contentflow_nexo_request_metrics USING btree (task_key, created_at DESC);


--
-- Name: contentflow_nexo_slots_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_nexo_slots_active_idx ON public.contentflow_nexo_slots USING btree (lane, expires_at) WHERE (released_at IS NULL);


--
-- Name: contentflow_persistent_change_provenance_incident_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_persistent_change_provenance_incident_idx ON public.contentflow_persistent_change_provenance USING btree (project_key, incident_id, requested_at DESC);


--
-- Name: contentflow_persistent_change_provenance_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_persistent_change_provenance_status_idx ON public.contentflow_persistent_change_provenance USING btree (status, requested_at);


--
-- Name: contentflow_runtime_event_ledger_idem_event_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contentflow_runtime_event_ledger_idem_event_uq ON public.contentflow_runtime_event_ledger USING btree (idempotency_key, event_type) WHERE (idempotency_key IS NOT NULL);


--
-- Name: contentflow_runtime_event_ledger_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_runtime_event_ledger_run_idx ON public.contentflow_runtime_event_ledger USING btree (builder_run_id, created_at);


--
-- Name: contentflow_runtime_event_trace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_runtime_event_trace_idx ON public.contentflow_runtime_event_ledger USING btree (trace_id, created_at);


--
-- Name: contentflow_runtime_evidence_requirement_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contentflow_runtime_evidence_requirement_idx ON public.contentflow_runtime_evidence_ledger USING btree (project_key, requirement_id, created_at DESC);


--
-- Name: director_autonomy_events_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_autonomy_events_idx ON public.director_autonomy_events USING btree (project_key, event_type, created_at DESC);


--
-- Name: director_cycle_runs_trace_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX director_cycle_runs_trace_uq ON public.director_cycle_runs USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: director_error_memory_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_error_memory_lookup_idx ON public.director_error_memory USING btree (project_key, error_class, status, confidence DESC, last_seen_at DESC);


--
-- Name: director_external_evidence_task_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_external_evidence_task_idx ON public.director_external_evidence USING btree (project_key, task_key, status);


--
-- Name: director_external_evidence_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX director_external_evidence_unique_idx ON public.director_external_evidence USING btree (project_key, task_key, evidence_type, COALESCE(engine, ''::text), COALESCE(environment, ''::text));


--
-- Name: director_help_alerts_one_open_fingerprint_task_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX director_help_alerts_one_open_fingerprint_task_uq ON public.director_help_alerts USING btree (project_key, task_key, error_fingerprint) WHERE (status = 'open'::text);


--
-- Name: director_help_alerts_open_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_help_alerts_open_idx ON public.director_help_alerts USING btree (project_key, status, created_at DESC);


--
-- Name: director_help_alerts_unique_open_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX director_help_alerts_unique_open_idx ON public.director_help_alerts USING btree (project_key, error_fingerprint, COALESCE(task_key, ''::text)) WHERE (status = 'open'::text);


--
-- Name: director_recovery_canonical_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_recovery_canonical_lookup_idx ON public.director_recovery_learning_memory USING btree (project_key, canonical_fingerprint) WHERE (enabled AND (NOT recertification_required));


--
-- Name: director_recovery_learning_memory_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_recovery_learning_memory_lookup_idx ON public.director_recovery_learning_memory USING btree (project_key, incident_fingerprint) WHERE enabled;


--
-- Name: director_repair_incidents_one_active_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX director_repair_incidents_one_active_fingerprint ON public.director_repair_incidents USING btree (project_key, error_fingerprint) WHERE (status = ANY (ARRAY['open'::text, 'analyzing'::text, 'repairing'::text, 'validating'::text]));


--
-- Name: director_resilience_checks_project_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_resilience_checks_project_created_idx ON public.director_resilience_checks USING btree (project_key, created_at DESC);


--
-- Name: director_runs_user_project_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_runs_user_project_created_idx ON public.director_runs USING btree (user_id, project_key, created_at DESC);


--
-- Name: director_state_transition_entity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_state_transition_entity_idx ON public.director_state_transition_ledger USING btree (entity_type, entity_key, created_at);


--
-- Name: director_state_transition_trace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX director_state_transition_trace_idx ON public.director_state_transition_ledger USING btree (trace_id, created_at);


--
-- Name: idx_brands_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brands_user_id ON public.brands USING btree (user_id);


--
-- Name: idx_cf_evidence_requirements_backlog_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cf_evidence_requirements_backlog_task_id ON public.contentflow_evidence_requirements USING btree (backlog_task_id);


--
-- Name: idx_cf_evidence_requirements_source_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cf_evidence_requirements_source_run_id ON public.contentflow_evidence_requirements USING btree (source_run_id);


--
-- Name: idx_cf_model_task_quarantine_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cf_model_task_quarantine_active ON public.contentflow_model_task_quarantine USING btree (project_key, expires_at);


--
-- Name: idx_cf_runtime_evidence_backlog_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cf_runtime_evidence_backlog_task_id ON public.contentflow_runtime_evidence_ledger USING btree (backlog_task_id);


--
-- Name: idx_cf_runtime_evidence_builder_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cf_runtime_evidence_builder_run_id ON public.contentflow_runtime_evidence_ledger USING btree (builder_run_id);


--
-- Name: idx_cf_runtime_evidence_requirement_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cf_runtime_evidence_requirement_id ON public.contentflow_runtime_evidence_ledger USING btree (requirement_id);


--
-- Name: idx_content_schedule_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_schedule_project_id ON public.content_schedule USING btree (project_id);


--
-- Name: idx_content_schedule_social_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_schedule_social_account_id ON public.content_schedule USING btree (social_account_id);


--
-- Name: idx_contentflow_builder_dispatches_backlog_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_builder_dispatches_backlog_task_id ON public.contentflow_builder_dispatches USING btree (backlog_task_id);


--
-- Name: idx_contentflow_builder_dispatches_builder_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_builder_dispatches_builder_run_id ON public.contentflow_builder_dispatches USING btree (builder_run_id);


--
-- Name: idx_contentflow_builder_runs_project_id_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_builder_runs_project_id_desc ON public.contentflow_builder_runs USING btree (project_key, id DESC);


--
-- Name: idx_contentflow_builder_runs_project_status_id_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_builder_runs_project_status_id_desc ON public.contentflow_builder_runs USING btree (project_key, status, id DESC);


--
-- Name: idx_contentflow_builder_runs_project_task_id_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_builder_runs_project_task_id_desc ON public.contentflow_builder_runs USING btree (project_key, task_key, id DESC);


--
-- Name: idx_contentflow_capacity_state_active_phase; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_capacity_state_active_phase ON public.contentflow_capacity_state USING btree (active_phase);


--
-- Name: idx_contentflow_nexo_request_metrics_attempt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_nexo_request_metrics_attempt_id ON public.contentflow_nexo_request_metrics USING btree (attempt_id) WHERE (attempt_id IS NOT NULL);


--
-- Name: idx_contentflow_nexo_request_metrics_logical_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_nexo_request_metrics_logical_request_id ON public.contentflow_nexo_request_metrics USING btree (logical_request_id) WHERE (logical_request_id IS NOT NULL);


--
-- Name: idx_contentflow_nexo_request_metrics_nexo_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_nexo_request_metrics_nexo_request_id ON public.contentflow_nexo_request_metrics USING btree (nexo_request_id) WHERE (nexo_request_id IS NOT NULL);


--
-- Name: idx_contentflow_nexo_request_metrics_parent_attempt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_nexo_request_metrics_parent_attempt_id ON public.contentflow_nexo_request_metrics USING btree (parent_attempt_id) WHERE (parent_attempt_id IS NOT NULL);


--
-- Name: idx_contentflow_retry_state_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_retry_state_due ON public.contentflow_retry_state USING btree (project_key, circuit_state, next_retry_at);


--
-- Name: idx_contentflow_retry_state_error_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_retry_state_error_class ON public.contentflow_retry_state USING btree (error_class);


--
-- Name: idx_contentflow_retry_state_last_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_retry_state_last_run_id ON public.contentflow_retry_state USING btree (last_run_id);


--
-- Name: idx_contentflow_runtime_verifications_backlog_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_runtime_verifications_backlog_task_id ON public.contentflow_runtime_verifications USING btree (backlog_task_id);


--
-- Name: idx_contentflow_runtime_verifications_builder_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_runtime_verifications_builder_run_id ON public.contentflow_runtime_verifications USING btree (builder_run_id);


--
-- Name: idx_contentflow_signal_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_signal_lookup ON public.contentflow_durable_signal_ledger USING btree (project_key, task_key, signal_key, created_at DESC);


--
-- Name: idx_contentflow_tool_execution_queue_backlog_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_tool_execution_queue_backlog_task_id ON public.contentflow_tool_execution_queue USING btree (backlog_task_id);


--
-- Name: idx_contentflow_tool_execution_queue_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_tool_execution_queue_state ON public.contentflow_tool_execution_queue USING btree (project_key, state, created_at);


--
-- Name: idx_contentflow_wait_registry_project_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contentflow_wait_registry_project_state ON public.contentflow_wait_registry USING btree (project_key, state, wait_kind, wake_at);


--
-- Name: idx_credit_transactions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_credit_transactions_user_id ON public.credit_transactions USING btree (user_id);


--
-- Name: idx_director_cycle_runs_project_id_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_director_cycle_runs_project_id_desc ON public.director_cycle_runs USING btree (project_key, id DESC);


--
-- Name: idx_director_cycle_runs_started_id_desc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_director_cycle_runs_started_id_desc ON public.director_cycle_runs USING btree (started_at DESC, id DESC);


--
-- Name: idx_director_repair_actions_incident_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_director_repair_actions_incident_id ON public.director_repair_actions USING btree (incident_id);


--
-- Name: idx_director_repair_incidents_project_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_director_repair_incidents_project_open ON public.director_repair_incidents USING btree (project_key, updated_at DESC) WHERE (status = ANY (ARRAY['open'::text, 'analyzing'::text]));


--
-- Name: idx_director_trace_spans_cycle_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_director_trace_spans_cycle_id ON public.director_trace_spans USING btree (cycle_id);


--
-- Name: idx_director_trace_spans_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_director_trace_spans_run ON public.director_trace_spans USING btree (builder_run_id, started_at);


--
-- Name: idx_director_trace_spans_trace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_director_trace_spans_trace ON public.director_trace_spans USING btree (trace_id, started_at);


--
-- Name: idx_durable_task_stages_project_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_durable_task_stages_project_state ON public.contentflow_durable_task_stages USING btree (project_key, stage_state, updated_at);


--
-- Name: idx_generations_orchestrator_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generations_orchestrator_run_id ON public.generations USING btree (orchestrator_run_id);


--
-- Name: idx_generations_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generations_project_id ON public.generations USING btree (project_id);


--
-- Name: idx_generations_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generations_user ON public.generations USING btree (user_id);


--
-- Name: idx_marketing_memory_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_marketing_memory_brand_id ON public.marketing_memory USING btree (brand_id);


--
-- Name: idx_memory_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_memory_user ON public.marketing_memory USING btree (user_id);


--
-- Name: idx_profiles_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_user ON public.profiles USING btree (user_id);


--
-- Name: idx_projects_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_brand_id ON public.projects USING btree (brand_id);


--
-- Name: idx_projects_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_user ON public.projects USING btree (user_id);


--
-- Name: idx_repair_incidents_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_repair_incidents_status ON public.director_repair_incidents USING btree (project_key, status, created_at);


--
-- Name: idx_review_work_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_review_work_pending ON public.contentflow_review_work_queue USING btree (state, available_at, updated_at);


--
-- Name: idx_schedule_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_schedule_user ON public.content_schedule USING btree (user_id);


--
-- Name: idx_social_accounts_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_social_accounts_brand_id ON public.social_accounts USING btree (brand_id);


--
-- Name: idx_social_accounts_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_social_accounts_user ON public.social_accounts USING btree (user_id);


--
-- Name: idx_social_metrics_social_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_social_metrics_social_account_id ON public.social_metrics USING btree (social_account_id);


--
-- Name: idx_social_metrics_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_social_metrics_user ON public.social_metrics USING btree (user_id);


--
-- Name: idx_wallets_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wallets_user ON public.credit_wallets USING btree (user_id);


--
-- Name: orchestrator_runs_user_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orchestrator_runs_user_project_idx ON public.orchestrator_runs USING btree (user_id, project_key, created_at DESC);


--
-- Name: orchestrator_tasks_run_stage_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orchestrator_tasks_run_stage_idx ON public.orchestrator_tasks USING btree (run_id, stage);


--
-- Name: orchestrator_tasks_run_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orchestrator_tasks_run_status_idx ON public.orchestrator_tasks USING btree (run_id, status);


--
-- Name: orchestrator_tasks_user_project_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orchestrator_tasks_user_project_idx ON public.orchestrator_tasks USING btree (user_id, project_key, created_at DESC);


--
-- Name: uq_contentflow_evidence_requirement_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_contentflow_evidence_requirement_active ON public.contentflow_evidence_requirements USING btree (project_key, backlog_task_id, requirement_fingerprint) WHERE (status <> 'obsolete'::text);


--
-- Name: uq_contentflow_evidence_semantic_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_contentflow_evidence_semantic_identity ON public.contentflow_evidence_requirements USING btree (project_key, backlog_task_id, requirement_class) WHERE (status <> 'obsolete'::text);


--
-- Name: academy_whatsapp_handoffs trg_academy_whatsapp_handoff_director_alert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_academy_whatsapp_handoff_director_alert AFTER INSERT ON public.academy_whatsapp_handoffs FOR EACH ROW EXECUTE FUNCTION public.academy_whatsapp_emit_director_help_alert();


--
-- Name: director_runs trg_attach_director_usage_to_orchestrator_task; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_attach_director_usage_to_orchestrator_task AFTER INSERT ON public.director_runs FOR EACH ROW EXECUTE FUNCTION public.attach_director_usage_to_running_orchestrator_task();


--
-- Name: contentflow_build_backlog trg_audit_builder_claim; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_builder_claim AFTER UPDATE OF status ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.audit_builder_claim();


--
-- Name: contentflow_builder_runs trg_builder_review_before_complete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_builder_review_before_complete BEFORE INSERT OR UPDATE OF status, review_approved ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.enforce_builder_review_before_complete();


--
-- Name: contentflow_builder_runs trg_builder_span_identity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_builder_span_identity BEFORE INSERT ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_builder_span_identity();


--
-- Name: contentflow_build_backlog trg_contentflow_autonomy_backlog; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_autonomy_backlog AFTER UPDATE ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.log_contentflow_autonomy_backlog();


--
-- Name: contentflow_build_backlog trg_contentflow_backlog_invariants_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_backlog_invariants_v1 BEFORE INSERT OR UPDATE ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_enforce_backlog_invariants_v1();


--
-- Name: contentflow_build_backlog trg_contentflow_backlog_state_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_backlog_state_guard BEFORE INSERT OR UPDATE OF status, blocked_reason, next_eligible_at ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_backlog_state_guard();


--
-- Name: contentflow_build_backlog trg_contentflow_backlog_transition_ledger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_backlog_transition_ledger AFTER UPDATE OF status ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_log_backlog_transition();


--
-- Name: director_help_alerts trg_contentflow_block_on_help_alert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_block_on_help_alert AFTER INSERT OR UPDATE OF status ON public.director_help_alerts FOR EACH ROW EXECUTE FUNCTION public.contentflow_block_on_help_alert();


--
-- Name: contentflow_builder_runs trg_contentflow_builder_identity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_builder_identity BEFORE INSERT ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_enrich_builder_identity();


--
-- Name: contentflow_builder_runs trg_contentflow_builder_result_identity_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_builder_result_identity_guard BEFORE INSERT OR UPDATE OF result ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_builder_result_identity_guard();


--
-- Name: contentflow_builder_runs trg_contentflow_builder_transition_ledger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_builder_transition_ledger AFTER UPDATE OF status ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_log_builder_transition();


--
-- Name: contentflow_builder_runs trg_contentflow_capability_certification_after_run; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_capability_certification_after_run AFTER UPDATE OF status, review_approved ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_capability_certification_after_run_update();


--
-- Name: contentflow_evidence_requirements trg_contentflow_close_incident_on_evidence_verified; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_close_incident_on_evidence_verified AFTER UPDATE OF status ON public.contentflow_evidence_requirements FOR EACH ROW EXECUTE FUNCTION public.contentflow_close_incident_on_evidence_verified();


--
-- Name: contentflow_build_backlog trg_contentflow_default_artifact_contract_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_default_artifact_contract_v1 BEFORE INSERT OR UPDATE OF description, task_type, workflow_contract ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_default_artifact_contract_v1();


--
-- Name: contentflow_build_backlog trg_contentflow_direct_tool_recipe_autorelease_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_direct_tool_recipe_autorelease_v1 BEFORE UPDATE OF workflow_contract ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_direct_tool_recipe_autorelease_v1();


--
-- Name: contentflow_build_backlog trg_contentflow_dynamic_running_cap; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_dynamic_running_cap BEFORE UPDATE OF status ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_enforce_dynamic_running_cap();


--
-- Name: contentflow_build_backlog trg_contentflow_enforce_learned_evidence_lane; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_enforce_learned_evidence_lane BEFORE INSERT OR UPDATE OF execution_lane, epic, description, status ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_enforce_learned_evidence_lane();


--
-- Name: contentflow_external_executor_registry trg_contentflow_external_executor_autorelease_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_external_executor_autorelease_v1 AFTER INSERT OR UPDATE ON public.contentflow_external_executor_registry FOR EACH ROW EXECUTE FUNCTION public.contentflow_external_executor_autorelease_v1();


--
-- Name: contentflow_build_backlog trg_contentflow_external_media_lane_guard_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_external_media_lane_guard_v1 BEFORE INSERT OR UPDATE OF title, description, acceptance_criteria, execution_lane, epic ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_external_media_lane_guard_v1();


--
-- Name: contentflow_evidence_requirements trg_contentflow_false_rara_evidence_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_false_rara_evidence_v1 BEFORE INSERT OR UPDATE ON public.contentflow_evidence_requirements FOR EACH ROW EXECUTE FUNCTION public.contentflow_guard_false_rara_evidence_v1();


--
-- Name: contentflow_builder_runs trg_contentflow_guard_active_run_protocol; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_guard_active_run_protocol BEFORE INSERT OR UPDATE OF status, lease_token, control_protocol ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_guard_active_run_protocol();


--
-- Name: contentflow_build_backlog trg_contentflow_guard_backlog_completion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_guard_backlog_completion BEFORE INSERT OR UPDATE OF status, runtime_verified ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_guard_backlog_completion();


--
-- Name: contentflow_builder_runs trg_contentflow_guard_builder_completion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_guard_builder_completion BEFORE INSERT OR UPDATE OF status ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_guard_builder_completion();


--
-- Name: contentflow_build_backlog trg_contentflow_guard_dependency_graph; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_guard_dependency_graph BEFORE INSERT OR UPDATE OF task_key, depends_on ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_guard_dependency_graph();


--
-- Name: director_repair_incidents trg_contentflow_incident_learning; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_incident_learning AFTER INSERT OR UPDATE OF status, attempts, error_class, error_fingerprint, outcome, executed_action, root_cause ON public.director_repair_incidents FOR EACH ROW EXECUTE FUNCTION public.contentflow_incident_learning_trigger();


--
-- Name: contentflow_builder_runs trg_contentflow_material_claim_truth_preflight; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_material_claim_truth_preflight BEFORE UPDATE OF status, result ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_enforce_material_claim_truth_preflight();


--
-- Name: contentflow_builder_runs trg_contentflow_materialize_verified_sources_on_review; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_materialize_verified_sources_on_review BEFORE UPDATE OF status, result ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_materialize_verified_sources_on_review();


--
-- Name: contentflow_runtime_event_ledger trg_contentflow_normalize_fractional_judge_score; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_normalize_fractional_judge_score BEFORE INSERT ON public.contentflow_runtime_event_ledger FOR EACH ROW EXECUTE FUNCTION public.contentflow_normalize_fractional_judge_score();


--
-- Name: contentflow_builder_runs trg_contentflow_problem_from_run; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_problem_from_run AFTER UPDATE ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.log_contentflow_problem_from_run();


--
-- Name: contentflow_builder_runs trg_contentflow_research_deliverable_preflight; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_research_deliverable_preflight BEFORE UPDATE OF status ON public.contentflow_builder_runs FOR EACH ROW WHEN ((new.status = 'review_required'::text)) EXECUTE FUNCTION public.contentflow_enforce_research_deliverable_preflight();


--
-- Name: contentflow_builder_runs trg_contentflow_research_submission_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_research_submission_guard BEFORE UPDATE OF status ON public.contentflow_builder_runs FOR EACH ROW WHEN ((new.status = 'review_required'::text)) EXECUTE FUNCTION public.contentflow_research_submission_guard();


--
-- Name: contentflow_builder_runs trg_contentflow_review_pending_backlog; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_review_pending_backlog AFTER INSERT OR UPDATE OF status ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_sync_review_pending_backlog();


--
-- Name: contentflow_runtime_event_ledger trg_contentflow_runtime_event_trace; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_runtime_event_trace BEFORE INSERT OR UPDATE ON public.contentflow_runtime_event_ledger FOR EACH ROW EXECUTE FUNCTION public.contentflow_enrich_runtime_event_trace();


--
-- Name: contentflow_runtime_evidence_ledger trg_contentflow_runtime_evidence_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_runtime_evidence_immutable BEFORE DELETE OR UPDATE ON public.contentflow_runtime_evidence_ledger FOR EACH ROW EXECUTE FUNCTION public.contentflow_guard_runtime_evidence_ledger_immutable();


--
-- Name: contentflow_builder_runs trg_contentflow_seed_bootstrap_deadline; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_seed_bootstrap_deadline BEFORE INSERT OR UPDATE ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_seed_bootstrap_deadline();


--
-- Name: contentflow_build_backlog trg_contentflow_set_execution_lane; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_set_execution_lane BEFORE INSERT OR UPDATE OF task_type, description, acceptance_criteria ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_set_execution_lane();


--
-- Name: contentflow_build_backlog trg_contentflow_sync_help_and_dependents; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_sync_help_and_dependents AFTER UPDATE OF status ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_sync_help_and_dependents();


--
-- Name: contentflow_evidence_requirements trg_contentflow_sync_obsolete_evidence_requirement; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_sync_obsolete_evidence_requirement AFTER INSERT OR UPDATE OF status ON public.contentflow_evidence_requirements FOR EACH ROW EXECUTE FUNCTION public.contentflow_sync_obsolete_evidence_requirement();


--
-- Name: contentflow_builder_runs trg_contentflow_sync_review_work_queue; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_contentflow_sync_review_work_queue AFTER INSERT OR UPDATE OF status ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_sync_review_work_queue();


--
-- Name: director_cycle_runs trg_director_cycle_identity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_director_cycle_identity BEFORE INSERT ON public.director_cycle_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_enrich_cycle_identity();


--
-- Name: director_worker_queue trg_director_worker_transition_ledger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_director_worker_transition_ledger AFTER UPDATE OF status, current_task_key ON public.director_worker_queue FOR EACH ROW EXECUTE FUNCTION public.contentflow_log_worker_transition();


--
-- Name: orchestrator_tasks trg_refresh_orchestrator_run_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_refresh_orchestrator_run_usage AFTER INSERT OR UPDATE OF input_tokens, output_tokens ON public.orchestrator_tasks FOR EACH ROW EXECUTE FUNCTION public.refresh_orchestrator_run_usage();


--
-- Name: contentflow_builder_runs trg_requeue_approved_worker_on_run_finish; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_requeue_approved_worker_on_run_finish AFTER INSERT OR UPDATE OF status, finished_at ON public.contentflow_builder_runs FOR EACH ROW WHEN ((new.status = ANY (ARRAY['review_required'::text, 'completed'::text, 'failed'::text]))) EXECUTE FUNCTION public.requeue_approved_worker_on_run_finish();


--
-- Name: contentflow_builder_runs trg_sync_builder_span; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_builder_span AFTER INSERT OR UPDATE OF status, finished_at, error, quality_score, review_approved, trace_id, span_id ON public.contentflow_builder_runs FOR EACH ROW EXECUTE FUNCTION public.contentflow_sync_builder_span();


--
-- Name: contentflow_primary_source_evidence trg_sync_primary_source_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_primary_source_context AFTER INSERT OR UPDATE ON public.contentflow_primary_source_evidence FOR EACH ROW EXECUTE FUNCTION public.contentflow_sync_primary_source_context();


--
-- Name: contentflow_build_backlog zz_contentflow_obsolete_evidence_tombstone; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_contentflow_obsolete_evidence_tombstone BEFORE UPDATE OF status, workflow_state, completion_phase, blocked_reason, next_eligible_at, selected_model ON public.contentflow_build_backlog FOR EACH ROW EXECUTE FUNCTION public.contentflow_obsolete_evidence_tombstone_guard_v1();


--
-- Name: academy_whatsapp_handoffs academy_whatsapp_handoffs_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_handoffs
    ADD CONSTRAINT academy_whatsapp_handoffs_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.academy_whatsapp_conversations(id) ON DELETE CASCADE;


--
-- Name: academy_whatsapp_messages academy_whatsapp_messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_messages
    ADD CONSTRAINT academy_whatsapp_messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.academy_whatsapp_conversations(id) ON DELETE CASCADE;


--
-- Name: academy_whatsapp_messages academy_whatsapp_messages_knowledge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_messages
    ADD CONSTRAINT academy_whatsapp_messages_knowledge_id_fkey FOREIGN KEY (knowledge_id) REFERENCES public.academy_whatsapp_knowledge(id);


--
-- Name: academy_whatsapp_outbox academy_whatsapp_outbox_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_outbox
    ADD CONSTRAINT academy_whatsapp_outbox_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.academy_whatsapp_conversations(id) ON DELETE CASCADE;


--
-- Name: academy_whatsapp_outbox academy_whatsapp_outbox_source_knowledge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academy_whatsapp_outbox
    ADD CONSTRAINT academy_whatsapp_outbox_source_knowledge_id_fkey FOREIGN KEY (source_knowledge_id) REFERENCES public.academy_whatsapp_knowledge(id);


--
-- Name: brands brands_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: content_schedule content_schedule_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_schedule
    ADD CONSTRAINT content_schedule_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: content_schedule content_schedule_social_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_schedule
    ADD CONSTRAINT content_schedule_social_account_id_fkey FOREIGN KEY (social_account_id) REFERENCES public.social_accounts(id) ON DELETE CASCADE;


--
-- Name: content_schedule content_schedule_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_schedule
    ADD CONSTRAINT content_schedule_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: contentflow_builder_dispatches contentflow_builder_dispatches_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_builder_dispatches
    ADD CONSTRAINT contentflow_builder_dispatches_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE CASCADE;


--
-- Name: contentflow_builder_dispatches contentflow_builder_dispatches_builder_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_builder_dispatches
    ADD CONSTRAINT contentflow_builder_dispatches_builder_run_id_fkey FOREIGN KEY (builder_run_id) REFERENCES public.contentflow_builder_runs(id) ON DELETE CASCADE;


--
-- Name: contentflow_builder_runs contentflow_builder_runs_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_builder_runs
    ADD CONSTRAINT contentflow_builder_runs_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE RESTRICT;


--
-- Name: contentflow_capacity_state contentflow_capacity_state_active_phase_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_capacity_state
    ADD CONSTRAINT contentflow_capacity_state_active_phase_fkey FOREIGN KEY (active_phase) REFERENCES public.contentflow_capacity_phases(phase);


--
-- Name: contentflow_durable_task_stages contentflow_durable_task_stages_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_durable_task_stages
    ADD CONSTRAINT contentflow_durable_task_stages_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE CASCADE;


--
-- Name: contentflow_evidence_requirements contentflow_evidence_requirements_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_evidence_requirements
    ADD CONSTRAINT contentflow_evidence_requirements_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE CASCADE;


--
-- Name: contentflow_evidence_requirements contentflow_evidence_requirements_source_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_evidence_requirements
    ADD CONSTRAINT contentflow_evidence_requirements_source_run_id_fkey FOREIGN KEY (source_run_id) REFERENCES public.contentflow_builder_runs(id) ON DELETE CASCADE;


--
-- Name: contentflow_fresh10_items contentflow_fresh10_items_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_fresh10_items
    ADD CONSTRAINT contentflow_fresh10_items_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.contentflow_fresh10_runs(id) ON DELETE CASCADE;


--
-- Name: contentflow_retry_state contentflow_retry_state_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_retry_state
    ADD CONSTRAINT contentflow_retry_state_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE CASCADE;


--
-- Name: contentflow_retry_state contentflow_retry_state_error_class_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_retry_state
    ADD CONSTRAINT contentflow_retry_state_error_class_fkey FOREIGN KEY (error_class) REFERENCES public.contentflow_retry_policies(error_class);


--
-- Name: contentflow_retry_state contentflow_retry_state_last_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_retry_state
    ADD CONSTRAINT contentflow_retry_state_last_run_id_fkey FOREIGN KEY (last_run_id) REFERENCES public.contentflow_builder_runs(id);


--
-- Name: contentflow_review_work_queue contentflow_review_work_queue_builder_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_review_work_queue
    ADD CONSTRAINT contentflow_review_work_queue_builder_run_id_fkey FOREIGN KEY (builder_run_id) REFERENCES public.contentflow_builder_runs(id) ON DELETE CASCADE;


--
-- Name: contentflow_runtime_event_ledger contentflow_runtime_event_ledger_builder_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_event_ledger
    ADD CONSTRAINT contentflow_runtime_event_ledger_builder_run_id_fkey FOREIGN KEY (builder_run_id) REFERENCES public.contentflow_builder_runs(id) ON DELETE CASCADE;


--
-- Name: contentflow_runtime_evidence_ledger contentflow_runtime_evidence_ledger_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_evidence_ledger
    ADD CONSTRAINT contentflow_runtime_evidence_ledger_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE RESTRICT;


--
-- Name: contentflow_runtime_evidence_ledger contentflow_runtime_evidence_ledger_builder_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_evidence_ledger
    ADD CONSTRAINT contentflow_runtime_evidence_ledger_builder_run_id_fkey FOREIGN KEY (builder_run_id) REFERENCES public.contentflow_builder_runs(id) ON DELETE RESTRICT;


--
-- Name: contentflow_runtime_evidence_ledger contentflow_runtime_evidence_ledger_requirement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_evidence_ledger
    ADD CONSTRAINT contentflow_runtime_evidence_ledger_requirement_id_fkey FOREIGN KEY (requirement_id) REFERENCES public.contentflow_evidence_requirements(id);


--
-- Name: contentflow_runtime_verifications contentflow_runtime_verifications_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_verifications
    ADD CONSTRAINT contentflow_runtime_verifications_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE CASCADE;


--
-- Name: contentflow_runtime_verifications contentflow_runtime_verifications_builder_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_runtime_verifications
    ADD CONSTRAINT contentflow_runtime_verifications_builder_run_id_fkey FOREIGN KEY (builder_run_id) REFERENCES public.contentflow_builder_runs(id) ON DELETE SET NULL;


--
-- Name: contentflow_tool_execution_queue contentflow_tool_execution_queue_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_tool_execution_queue
    ADD CONSTRAINT contentflow_tool_execution_queue_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE CASCADE;


--
-- Name: contentflow_wait_registry contentflow_wait_registry_backlog_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contentflow_wait_registry
    ADD CONSTRAINT contentflow_wait_registry_backlog_task_id_fkey FOREIGN KEY (backlog_task_id) REFERENCES public.contentflow_build_backlog(id) ON DELETE CASCADE;


--
-- Name: credit_transactions credit_transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_transactions
    ADD CONSTRAINT credit_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: credit_wallets credit_wallets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_wallets
    ADD CONSTRAINT credit_wallets_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: director_approved_solutions director_approved_solutions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_approved_solutions
    ADD CONSTRAINT director_approved_solutions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: director_budgets director_budgets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_budgets
    ADD CONSTRAINT director_budgets_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: director_control_incident_strategy_state director_control_incident_strategy_state_incident_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_control_incident_strategy_state
    ADD CONSTRAINT director_control_incident_strategy_state_incident_id_fkey FOREIGN KEY (incident_id) REFERENCES public.director_repair_incidents(id) ON DELETE CASCADE;


--
-- Name: director_model_stats director_model_stats_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_model_stats
    ADD CONSTRAINT director_model_stats_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: director_repair_actions director_repair_actions_incident_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_repair_actions
    ADD CONSTRAINT director_repair_actions_incident_id_fkey FOREIGN KEY (incident_id) REFERENCES public.director_repair_incidents(id) ON DELETE CASCADE;


--
-- Name: director_trace_spans director_trace_spans_builder_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_trace_spans
    ADD CONSTRAINT director_trace_spans_builder_run_id_fkey FOREIGN KEY (builder_run_id) REFERENCES public.contentflow_builder_runs(id);


--
-- Name: director_trace_spans director_trace_spans_cycle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.director_trace_spans
    ADD CONSTRAINT director_trace_spans_cycle_id_fkey FOREIGN KEY (cycle_id) REFERENCES public.director_cycle_runs(id);


--
-- Name: generations generations_orchestrator_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generations
    ADD CONSTRAINT generations_orchestrator_run_id_fkey FOREIGN KEY (orchestrator_run_id) REFERENCES public.orchestrator_runs(id) ON DELETE SET NULL;


--
-- Name: generations generations_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generations
    ADD CONSTRAINT generations_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: generations generations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generations
    ADD CONSTRAINT generations_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: marketing_memory marketing_memory_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_memory
    ADD CONSTRAINT marketing_memory_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: marketing_memory marketing_memory_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_memory
    ADD CONSTRAINT marketing_memory_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: orchestrator_runs orchestrator_runs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_runs
    ADD CONSTRAINT orchestrator_runs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: orchestrator_tasks orchestrator_tasks_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_tasks
    ADD CONSTRAINT orchestrator_tasks_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.orchestrator_runs(id) ON DELETE CASCADE;


--
-- Name: orchestrator_tasks orchestrator_tasks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orchestrator_tasks
    ADD CONSTRAINT orchestrator_tasks_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: projects projects_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE SET NULL;


--
-- Name: projects projects_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: social_accounts social_accounts_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_accounts
    ADD CONSTRAINT social_accounts_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: social_accounts social_accounts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_accounts
    ADD CONSTRAINT social_accounts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: social_metrics social_metrics_social_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_metrics
    ADD CONSTRAINT social_metrics_social_account_id_fkey FOREIGN KEY (social_account_id) REFERENCES public.social_accounts(id) ON DELETE CASCADE;


--
-- Name: social_metrics social_metrics_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_metrics
    ADD CONSTRAINT social_metrics_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: academy_whatsapp_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.academy_whatsapp_config ENABLE ROW LEVEL SECURITY;

--
-- Name: academy_whatsapp_conversations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.academy_whatsapp_conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: academy_whatsapp_handoffs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.academy_whatsapp_handoffs ENABLE ROW LEVEL SECURITY;

--
-- Name: academy_whatsapp_knowledge; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.academy_whatsapp_knowledge ENABLE ROW LEVEL SECURITY;

--
-- Name: academy_whatsapp_messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.academy_whatsapp_messages ENABLE ROW LEVEL SECURITY;

--
-- Name: academy_whatsapp_outbox; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.academy_whatsapp_outbox ENABLE ROW LEVEL SECURITY;

--
-- Name: brands; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;

--
-- Name: brands brands_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brands_insert_own ON public.brands FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: brands brands_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brands_select_own ON public.brands FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: brands brands_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brands_update_own ON public.brands FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: content_schedule; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.content_schedule ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_build_backlog; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_build_backlog ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_builder_dispatches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_builder_dispatches ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_builder_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_builder_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_capability_certifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_capability_certifications ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_capacity_decisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_capacity_decisions ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_capacity_phases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_capacity_phases ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_capacity_state; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_capacity_state ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_continuation_state; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_continuation_state ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_durable_signal_ledger; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_durable_signal_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_durable_task_stages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_durable_task_stages ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_evidence_capability_registry; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_evidence_capability_registry ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_evidence_capability_registry contentflow_evidence_capability_service_role_only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contentflow_evidence_capability_service_role_only ON public.contentflow_evidence_capability_registry TO service_role USING (true) WITH CHECK (true);


--
-- Name: contentflow_evidence_producer_recipes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_evidence_producer_recipes ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_evidence_producer_recipes contentflow_evidence_producer_recipes_service_role_only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contentflow_evidence_producer_recipes_service_role_only ON public.contentflow_evidence_producer_recipes TO service_role USING (true) WITH CHECK (true);


--
-- Name: contentflow_evidence_requirements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_evidence_requirements ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_evidence_requirements contentflow_evidence_requirements_service_role_only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contentflow_evidence_requirements_service_role_only ON public.contentflow_evidence_requirements TO service_role USING (true) WITH CHECK (true);


--
-- Name: contentflow_external_executor_registry; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_external_executor_registry ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_external_reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_external_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_fresh10_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_fresh10_items ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_fresh10_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_fresh10_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_internal_runner_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_internal_runner_config ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_lane_models; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_lane_models ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_legal_governance_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_legal_governance_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_model_task_quarantine; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_model_task_quarantine ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_nexo_request_metrics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_nexo_request_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_nexo_slots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_nexo_slots ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_persistent_change_provenance; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_persistent_change_provenance ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_primary_source_evidence; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_primary_source_evidence ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_retry_policies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_retry_policies ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_retry_state; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_retry_state ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_review_work_queue; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_review_work_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_runtime_event_ledger; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_runtime_event_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_runtime_evidence_ledger; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_runtime_evidence_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_runtime_evidence_ledger contentflow_runtime_evidence_ledger_service_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contentflow_runtime_evidence_ledger_service_insert ON public.contentflow_runtime_evidence_ledger FOR INSERT TO service_role WITH CHECK (true);


--
-- Name: contentflow_runtime_evidence_ledger contentflow_runtime_evidence_ledger_service_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contentflow_runtime_evidence_ledger_service_read ON public.contentflow_runtime_evidence_ledger FOR SELECT TO service_role USING (true);


--
-- Name: contentflow_runtime_verifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_runtime_verifications ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_tenant_security_targets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_tenant_security_targets ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_tool_execution_queue; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_tool_execution_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_wait_registry; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contentflow_wait_registry ENABLE ROW LEVEL SECURITY;

--
-- Name: credit_transactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.credit_transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: credit_wallets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.credit_wallets ENABLE ROW LEVEL SECURITY;

--
-- Name: director_approved_solutions director_approved_delete_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_approved_delete_own ON public.director_approved_solutions FOR DELETE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_approved_solutions director_approved_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_approved_insert_own ON public.director_approved_solutions FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_approved_solutions director_approved_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_approved_select_own ON public.director_approved_solutions FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_approved_solutions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_approved_solutions ENABLE ROW LEVEL SECURITY;

--
-- Name: director_approved_solutions director_approved_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_approved_update_own ON public.director_approved_solutions FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_autonomy_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_autonomy_events ENABLE ROW LEVEL SECURITY;

--
-- Name: director_budgets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_budgets ENABLE ROW LEVEL SECURITY;

--
-- Name: director_budgets director_budgets_delete_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_budgets_delete_own ON public.director_budgets FOR DELETE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_budgets director_budgets_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_budgets_insert_own ON public.director_budgets FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_budgets director_budgets_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_budgets_select_own ON public.director_budgets FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_budgets director_budgets_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_budgets_update_own ON public.director_budgets FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_canary_policy; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_canary_policy ENABLE ROW LEVEL SECURITY;

--
-- Name: director_control_incident_strategy_state; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_control_incident_strategy_state ENABLE ROW LEVEL SECURITY;

--
-- Name: director_control_incident_strategy_state director_control_incident_strategy_state_service_role_only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_control_incident_strategy_state_service_role_only ON public.director_control_incident_strategy_state TO service_role USING (true) WITH CHECK (true);


--
-- Name: director_control_policy; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_control_policy ENABLE ROW LEVEL SECURITY;

--
-- Name: director_cycle_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_cycle_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: director_error_memory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_error_memory ENABLE ROW LEVEL SECURITY;

--
-- Name: director_external_evidence; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_external_evidence ENABLE ROW LEVEL SECURITY;

--
-- Name: director_help_alerts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_help_alerts ENABLE ROW LEVEL SECURITY;

--
-- Name: director_model_stats; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_model_stats ENABLE ROW LEVEL SECURITY;

--
-- Name: director_model_stats director_model_stats_delete_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_model_stats_delete_own ON public.director_model_stats FOR DELETE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_model_stats director_model_stats_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_model_stats_insert_own ON public.director_model_stats FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_model_stats director_model_stats_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_model_stats_select_own ON public.director_model_stats FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_model_stats director_model_stats_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_model_stats_update_own ON public.director_model_stats FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_operating_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_operating_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: director_project_task_scope; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_project_task_scope ENABLE ROW LEVEL SECURITY;

--
-- Name: director_recovery_learning_memory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_recovery_learning_memory ENABLE ROW LEVEL SECURITY;

--
-- Name: director_repair_actions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_repair_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: director_repair_incidents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_repair_incidents ENABLE ROW LEVEL SECURITY;

--
-- Name: director_repair_recipes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_repair_recipes ENABLE ROW LEVEL SECURITY;

--
-- Name: director_resilience_checks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_resilience_checks ENABLE ROW LEVEL SECURITY;

--
-- Name: director_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: director_runs director_runs_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_runs_insert_own ON public.director_runs FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_runs director_runs_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY director_runs_select_own ON public.director_runs FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: director_state_transition_ledger; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_state_transition_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: director_task_decompositions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_task_decompositions ENABLE ROW LEVEL SECURITY;

--
-- Name: director_trace_spans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_trace_spans ENABLE ROW LEVEL SECURITY;

--
-- Name: director_worker_queue; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_worker_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: director_workflow_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.director_workflow_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: contentflow_fresh10_items fresh10_items_read_authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fresh10_items_read_authenticated ON public.contentflow_fresh10_items FOR SELECT TO authenticated USING (true);


--
-- Name: contentflow_fresh10_runs fresh10_runs_read_authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fresh10_runs_read_authenticated ON public.contentflow_fresh10_runs FOR SELECT TO authenticated USING (true);


--
-- Name: generations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.generations ENABLE ROW LEVEL SECURITY;

--
-- Name: generations generations_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY generations_insert_own ON public.generations FOR INSERT TO authenticated WITH CHECK (((( SELECT auth.uid() AS uid) = user_id) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects p
  WHERE ((p.id = generations.project_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))))));


--
-- Name: generations generations_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY generations_select_own ON public.generations FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: generations generations_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY generations_update_own ON public.generations FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK (((( SELECT auth.uid() AS uid) = user_id) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.projects p
  WHERE ((p.id = generations.project_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))))));


--
-- Name: jarvis_device_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.jarvis_device_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: jarvis_pairing_codes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.jarvis_pairing_codes ENABLE ROW LEVEL SECURITY;

--
-- Name: marketing_memory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.marketing_memory ENABLE ROW LEVEL SECURITY;

--
-- Name: marketing_memory memory_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY memory_select_own ON public.marketing_memory FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: orchestrator_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.orchestrator_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: orchestrator_runs orchestrator_runs_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY orchestrator_runs_insert_own ON public.orchestrator_runs FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: orchestrator_runs orchestrator_runs_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY orchestrator_runs_select_own ON public.orchestrator_runs FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: orchestrator_runs orchestrator_runs_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY orchestrator_runs_update_own ON public.orchestrator_runs FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: orchestrator_tasks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.orchestrator_tasks ENABLE ROW LEVEL SECURITY;

--
-- Name: orchestrator_tasks orchestrator_tasks_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY orchestrator_tasks_insert_own ON public.orchestrator_tasks FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: orchestrator_tasks orchestrator_tasks_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY orchestrator_tasks_select_own ON public.orchestrator_tasks FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: orchestrator_tasks orchestrator_tasks_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY orchestrator_tasks_update_own ON public.orchestrator_tasks FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_own ON public.profiles FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: projects; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

--
-- Name: projects projects_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY projects_insert_own ON public.projects FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: projects projects_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY projects_select_own ON public.projects FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: projects projects_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY projects_update_own ON public.projects FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: provider_costs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.provider_costs ENABLE ROW LEVEL SECURITY;

--
-- Name: content_schedule schedule_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY schedule_insert_own ON public.content_schedule FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: content_schedule schedule_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY schedule_select_own ON public.content_schedule FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: content_schedule schedule_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY schedule_update_own ON public.content_schedule FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: social_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.social_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: social_accounts social_accounts_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY social_accounts_insert_own ON public.social_accounts FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: social_accounts social_accounts_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY social_accounts_select_own ON public.social_accounts FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: social_accounts social_accounts_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY social_accounts_update_own ON public.social_accounts FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: social_metrics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.social_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: social_metrics social_metrics_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY social_metrics_select_own ON public.social_metrics FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: subscriptions subscriptions_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY subscriptions_select_own ON public.subscriptions FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: credit_transactions tx_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tx_select_own ON public.credit_transactions FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: credit_wallets wallets_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY wallets_select_own ON public.credit_wallets FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: youtube_oauth_token_vault; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.youtube_oauth_token_vault ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict kXa32Te5YJ8WM2YE7YRN2EgaY2mqRL4tjYuNcjweu7MSrvL3lOeIlb777GIBd3d

