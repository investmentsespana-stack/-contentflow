create or replace function public.contentflow_clear_completed_block_residue(p_project_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
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
revoke all on function public.contentflow_clear_completed_block_residue(text) from public, anon, authenticated;
grant execute on function public.contentflow_clear_completed_block_residue(text) to service_role;
