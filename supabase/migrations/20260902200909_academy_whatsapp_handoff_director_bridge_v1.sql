-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.academy_whatsapp_emit_director_help_alert()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
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

drop trigger if exists trg_academy_whatsapp_handoff_director_alert on public.academy_whatsapp_handoffs;
create trigger trg_academy_whatsapp_handoff_director_alert
after insert on public.academy_whatsapp_handoffs
for each row execute function public.academy_whatsapp_emit_director_help_alert();

revoke all on function public.academy_whatsapp_emit_director_help_alert() from public, anon, authenticated;
