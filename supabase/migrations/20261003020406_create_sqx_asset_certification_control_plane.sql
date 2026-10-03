-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create table if not exists public.trading_sqx_asset_certification (
  asset_key text primary key,
  project_name text not null,
  final_databank text not null default 'Final',
  status text not null default 'PENDING' check (status in ('PENDING','RUNNING','VERIFYING','CERTIFIED','NO_SURVIVOR','BLOCKED')),
  final_count integer not null default 0 check (final_count >= 0),
  evidence_command_id uuid references public.trading_sqx_bridge_commands(id) on delete set null,
  last_error text,
  live_money boolean not null default false check (live_money = false),
  updated_at timestamptz not null default now()
);
alter table public.trading_sqx_asset_certification enable row level security;
insert into public.trading_sqx_asset_certification(asset_key,project_name,final_databank,status,final_count)
values
 ('DJ','DJ CFD - Dukascopy','Final','VERIFYING',2),
 ('NQ_CFD','NQ CFD H1 - Dukascopy','Final','VERIFYING',24),
 ('GOLD_H1','GOLD H1 CFD - Dukascopy','Final strategies','VERIFYING',357),
 ('EW','EW FUTURES BREAKOUT H1 - Tradestation','Final','VERIFYING',112),
 ('DXY','DXY CFD H1 - Dukascopy','Final','PENDING',0),
 ('NQ_FUTURES','NQ BREAKOUT FUTURES  H1 - Tradestation','Final','PENDING',0)
on conflict (asset_key) do update set
 project_name=excluded.project_name, final_databank=excluded.final_databank,
 final_count=excluded.final_count,
 status=case when trading_sqx_asset_certification.status in ('CERTIFIED','NO_SURVIVOR') then trading_sqx_asset_certification.status else excluded.status end,
 updated_at=now();
