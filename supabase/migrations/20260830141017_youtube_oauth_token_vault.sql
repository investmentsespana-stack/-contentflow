-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create table if not exists public.youtube_oauth_token_vault (
  id uuid primary key default gen_random_uuid(),
  channel_id text not null unique,
  channel_title text,
  scopes text[] not null default '{}',
  access_token_ciphertext text not null,
  access_token_iv text not null,
  access_token_tag text not null,
  refresh_token_ciphertext text,
  refresh_token_iv text,
  refresh_token_tag text,
  token_fingerprint text not null,
  access_expires_at timestamptz,
  refresh_token_received boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.youtube_oauth_token_vault enable row level security;

revoke all on table public.youtube_oauth_token_vault from anon, authenticated;

drop function if exists public.upsert_youtube_oauth_token(text,text,text[],text,text,text,text,text,text,text,timestamptz,boolean);
create function public.upsert_youtube_oauth_token(
  p_channel_id text,
  p_channel_title text,
  p_scopes text[],
  p_access_token_ciphertext text,
  p_access_token_iv text,
  p_access_token_tag text,
  p_refresh_token_ciphertext text,
  p_refresh_token_iv text,
  p_refresh_token_tag text,
  p_token_fingerprint text,
  p_access_expires_at timestamptz,
  p_refresh_token_received boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.youtube_oauth_token_vault (
    channel_id, channel_title, scopes,
    access_token_ciphertext, access_token_iv, access_token_tag,
    refresh_token_ciphertext, refresh_token_iv, refresh_token_tag,
    token_fingerprint, access_expires_at, refresh_token_received, updated_at
  ) values (
    p_channel_id, p_channel_title, coalesce(p_scopes,'{}'),
    p_access_token_ciphertext, p_access_token_iv, p_access_token_tag,
    p_refresh_token_ciphertext, p_refresh_token_iv, p_refresh_token_tag,
    p_token_fingerprint, p_access_expires_at, p_refresh_token_received, now()
  )
  on conflict (channel_id) do update set
    channel_title = excluded.channel_title,
    scopes = excluded.scopes,
    access_token_ciphertext = excluded.access_token_ciphertext,
    access_token_iv = excluded.access_token_iv,
    access_token_tag = excluded.access_token_tag,
    refresh_token_ciphertext = coalesce(excluded.refresh_token_ciphertext, public.youtube_oauth_token_vault.refresh_token_ciphertext),
    refresh_token_iv = coalesce(excluded.refresh_token_iv, public.youtube_oauth_token_vault.refresh_token_iv),
    refresh_token_tag = coalesce(excluded.refresh_token_tag, public.youtube_oauth_token_vault.refresh_token_tag),
    token_fingerprint = excluded.token_fingerprint,
    access_expires_at = excluded.access_expires_at,
    refresh_token_received = public.youtube_oauth_token_vault.refresh_token_received or excluded.refresh_token_received,
    updated_at = now();
end;
$$;

revoke all on function public.upsert_youtube_oauth_token(text,text,text[],text,text,text,text,text,text,text,timestamptz,boolean) from public, anon, authenticated;
grant execute on function public.upsert_youtube_oauth_token(text,text,text[],text,text,text,text,text,text,text,timestamptz,boolean) to service_role;
