-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.


alter table public.trading_sqx_bridge_commands
  drop constraint if exists trading_sqx_bridge_commands_command_type_check;

alter table public.trading_sqx_bridge_commands
  add constraint trading_sqx_bridge_commands_command_type_check
  check (command_type = any(array[
    'cli_help'::text,
    'list_projects'::text,
    'list_databanks'::text,
    'status_project'::text,
    'list_symbols'::text,
    'list_instruments'::text,
    'list_timezones'::text,
    'count_databank'::text,
    'export_databank'::text,
    'list_strategies'::text,
    'get_strategy_stats'::text,
    'save_project_config'::text,
    'run_vibe_nq6_smoke'::text,
    'run_vibe_asset_research'::text,
    'run_project'::text,
    'stop_project'::text,
    'pause_project'::text,
    'resume_project'::text,
    'live_project_control'::text,
    'load_project_config'::text,
    'update_data'::text,
    'add_instrument'::text,
    'add_symbol'::text,
    'create_databank'::text,
    'copy_databank'::text,
    'move_databank'::text,
    'freeze_databank'::text
  ]));
