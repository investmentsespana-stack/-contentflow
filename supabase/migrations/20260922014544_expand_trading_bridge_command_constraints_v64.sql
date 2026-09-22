-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.


alter table public.trading_sqx_bridge_commands
  drop constraint if exists trading_sqx_bridge_commands_command_type_check;
alter table public.trading_sqx_bridge_commands
  add constraint trading_sqx_bridge_commands_command_type_check
  check (command_type = any (array[
    'cli_help','list_projects','list_databanks','status_project','list_symbols','list_instruments',
    'list_timezones','count_databank','export_databank','list_strategies','get_strategy_stats',
    'save_project_config','run_vibe_nq6_smoke','run_vibe_asset_research','vibe_diagnose','stack_health',
    'run_project','stop_project','pause_project','resume_project','live_project_control',
    'load_project_config','update_data','add_instrument','add_symbol','create_databank',
    'copy_databank','move_databank','freeze_databank','sync_vibe_runtime',
    'start_vibe','stop_vibe','restart_vibe'
  ]::text[]));

alter table public.trading_sqx_director_requests
  drop constraint if exists trading_sqx_director_requests_command_type_check;
alter table public.trading_sqx_director_requests
  add constraint trading_sqx_director_requests_command_type_check
  check (command_type = any (array[
    'cli_help','list_projects','list_databanks','status_project','list_symbols','list_instruments',
    'list_timezones','count_databank','export_databank','list_strategies','get_strategy_stats',
    'save_project_config','run_vibe_nq6_smoke','run_vibe_asset_research','vibe_diagnose','stack_health',
    'run_project','stop_project','pause_project','resume_project','live_project_control',
    'load_project_config','update_data','add_instrument','add_symbol','create_databank',
    'copy_databank','move_databank','freeze_databank','sync_vibe_runtime',
    'start_vibe','stop_vibe','restart_vibe'
  ]::text[]));
