create or replace function public.rara_safe_requeue_failed_task(p_task_key text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_requeued boolean := false;
begin
  if p_task_key like 'gap_gap_%' then return false; end if;

  update public.contentflow_build_backlog b
  set status='ready',
      selected_model=null,
      quality_score=0,
      blocked_reason=null,
      next_eligible_at=now(),
      updated_at=now(),
      result=coalesce(result,'')||E'\n[RARA] safe requeue after diagnosed failure/timeout'
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
    );
  v_requeued := found;

  if v_requeued then
    update public.contentflow_retry_state s
       set circuit_state='closed',
           circuit_open_until=null,
           next_retry_at=now(),
           updated_at=now()
     where s.project_key='contentflow'
       and s.task_key=p_task_key;
  end if;

  return v_requeued;
end
$function$;
