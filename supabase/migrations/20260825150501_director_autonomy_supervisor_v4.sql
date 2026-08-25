-- Reconstructed from live production catalog on 2026-08-25.
create or replace function public.contentflow_autonomy_supervisor(p_project_key text default 'contentflow',p_max_dispatch integer default 10)
returns jsonb language sql security definer set search_path to 'public' as $function$
  select public.contentflow_director_core_cycle(p_project_key,p_max_dispatch);
$function$;
revoke all on function public.contentflow_autonomy_supervisor(text,integer) from public,anon,authenticated;
grant execute on function public.contentflow_autonomy_supervisor(text,integer) to service_role;
