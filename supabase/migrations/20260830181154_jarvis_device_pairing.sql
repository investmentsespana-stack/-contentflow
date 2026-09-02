-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create table if not exists public.jarvis_pairing_codes (
  code_hash text primary key,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.jarvis_device_tokens (
  token_hash text primary key,
  label text not null default 'jarvis-desktop',
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
alter table public.jarvis_pairing_codes enable row level security;
alter table public.jarvis_device_tokens enable row level security;
revoke all on public.jarvis_pairing_codes from anon, authenticated;
revoke all on public.jarvis_device_tokens from anon, authenticated;
