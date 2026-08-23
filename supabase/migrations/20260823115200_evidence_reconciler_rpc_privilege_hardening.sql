revoke all on function public.contentflow_gc_evidence_dependencies(text) from public, anon, authenticated;
revoke all on function public.contentflow_reconcile_ready_after_evidence(text) from public, anon, authenticated;
revoke all on function public.contentflow_evidence_first_reconcile(text,integer) from public, anon, authenticated;

grant execute on function public.contentflow_gc_evidence_dependencies(text) to service_role;
grant execute on function public.contentflow_reconcile_ready_after_evidence(text) to service_role;
grant execute on function public.contentflow_evidence_first_reconcile(text,integer) to service_role;
