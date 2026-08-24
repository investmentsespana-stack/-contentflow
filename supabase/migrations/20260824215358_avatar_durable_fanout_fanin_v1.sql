-- Versioned from the current production definition for recovery lineage.

create or replace function public.avatar_product_progress_v1()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
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
$function$;

-- The verified Recovery Snapshot V2 remains authoritative for any additional
-- schema/data state applied by this production migration that is not safely
-- introspectable as a standalone DDL object.
