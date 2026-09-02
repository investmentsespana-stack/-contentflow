create or replace function public.contentflow_external_media_lane_guard_v1()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if new.epic='external_handoff'
     and (coalesce(new.title,'')||' '||coalesce(new.description,'')||' '||coalesce(new.acceptance_criteria,'')) ~* '(video|render|master|pieza profesional)'
     and (coalesce(new.title,'')||' '||coalesce(new.description,'')||' '||coalesce(new.acceptance_criteria,'')) ~* '(sha-?256|keyframe|subt[ií]tul|evidencia aut[eé]ntica|evidencia real|artefact)' then
    new.execution_lane := 'evidence_producer';
  end if;
  return new;
end
$function$;

drop trigger if exists trg_contentflow_external_media_lane_guard_v1 on public.contentflow_build_backlog;
create trigger trg_contentflow_external_media_lane_guard_v1
before insert or update of title,description,acceptance_criteria,execution_lane,epic
on public.contentflow_build_backlog
for each row execute function public.contentflow_external_media_lane_guard_v1();

update public.contentflow_build_backlog
set execution_lane='evidence_producer', updated_at=now()
where project_key='contentflow'
  and task_key in (
    'socialops_today_warmup_f02_v1','socialops_today_warmup_f03_v1','socialops_today_warmup_f04_v1','socialops_today_warmup_f05_v1',
    'socialops_today_warmup_f06_v1','socialops_today_warmup_f07_v1','socialops_today_warmup_f08_v1','socialops_today_warmup_f09_v1'
  );

update public.contentflow_build_backlog
set status='blocked', selected_model=null, quality_score=0,
    blocked_reason='EVIDENCE_INTEGRITY_MISMATCH_NO_VERIFIED_MEDIA',
    next_eligible_at=null, updated_at=now()
where project_key='contentflow' and task_key='socialops_today_warmup_f02_v1'
  and status='completed'
  and not exists (
    select 1 from public.director_external_evidence e
    where e.project_key='contentflow' and e.task_key='socialops_today_warmup_f02_v1' and e.verified=true and e.status='pass'
  );

update public.contentflow_build_backlog
set status='blocked', selected_model=null,
    blocked_reason='EVIDENCE_PRODUCER_REQUIRED_MEDIA_ARTIFACTS',
    next_eligible_at=null, updated_at=now()
where project_key='contentflow' and task_key='socialops_today_warmup_f09_v1'
  and status in ('ready','planned','failed')
  and not exists (
    select 1 from public.director_external_evidence e
    where e.project_key='contentflow' and e.task_key='socialops_today_warmup_f09_v1' and e.verified=true and e.status='pass'
  );

update public.contentflow_retry_state
set circuit_state='closed', circuit_open_until=null, next_retry_at=null, updated_at=now()
where project_key='contentflow' and task_key='socialops_today_warmup_f09_v1';