-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: schema
-- Recovered verbatim from production migration ledger to restore Git/production lineage.

create table if not exists public.jarvis_chatgpt_channel_context (
    channel_id text primary key,
    channel_name text not null,
    project_name text,
    context_summary text not null default '',
    recent_messages jsonb not null default '[]'::jsonb,
    source text not null default 'chatgpt_authorized_sync',
    source_updated_at timestamptz,
    synced_at timestamptz not null default now(),
    metadata jsonb not null default '{}'::jsonb
  );
  alter table public.jarvis_chatgpt_channel_context enable row level security;
  revoke all on table public.jarvis_chatgpt_channel_context from anon, authenticated;
  create index if not exists jarvis_chatgpt_channel_context_name_idx on public.jarvis_chatgpt_channel_context (lower(channel_name));
