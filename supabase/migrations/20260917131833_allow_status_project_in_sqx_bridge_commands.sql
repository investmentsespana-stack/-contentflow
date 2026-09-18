-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

alter table public.trading_sqx_bridge_commands
  drop constraint if exists trading_sqx_bridge_commands_command_type_check;

alter table public.trading_sqx_bridge_commands
  add constraint trading_sqx_bridge_commands_command_type_check
  check (command_type = any (array[
    'list_projects'::text,
    'list_strategies'::text,
    'list_databanks'::text,
    'get_strategy_stats'::text,
    'status_project'::text,
    'run_project'::text,
    'stop_project'::text
  ]));
