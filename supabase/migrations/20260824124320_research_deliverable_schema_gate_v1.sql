-- Current production-equivalent definition captured for recovery lineage.
create or replace function public.contentflow_research_deliverable_preflight(p_task_key text,p_result text)
returns jsonb
language plpgsql
immutable
set search_path to 'public'
as $function$
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
end$function$;

create or replace function public.contentflow_enforce_research_deliverable_preflight()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare chk jsonb;begin
 if new.status='review_required' then
   chk:=public.contentflow_research_deliverable_preflight(new.task_key,new.result);
   if not coalesce((chk->>'ok')::boolean,true) then
     new.status:='failed'; new.finished_at:=now(); new.review_approved:=false; new.error:='STRUCTURAL_PREFLIGHT_REJECT:'||chk::text;
     update public.contentflow_build_backlog set status='ready',selected_model=null,blocked_reason=null,next_eligible_at=now(),updated_at=now() where id=new.backlog_task_id;
     insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
     select project_key,'research_schema_preflight_rejected','research_deliverable_gate','deterministic_pre_review','requeued',false,'run='||new.id||' task='||new.task_key||' check='||chk::text,now() from public.contentflow_build_backlog where id=new.backlog_task_id;
   end if;
 end if;
 return new;
end$function$;

drop trigger if exists trg_contentflow_research_deliverable_preflight on public.contentflow_builder_runs;
create trigger trg_contentflow_research_deliverable_preflight before update of status on public.contentflow_builder_runs for each row when (new.status='review_required') execute function public.contentflow_enforce_research_deliverable_preflight();
