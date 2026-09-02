-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create table if not exists private.meta_oauth_tokens (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'meta',
  app_id text not null,
  user_id text,
  page_id text not null,
  instagram_id text,
  scopes text[] not null default '{}',
  tasks text[] not null default '{}',
  token_ciphertext text not null,
  token_iv text not null,
  token_tag text not null,
  token_fingerprint text not null,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, app_id, page_id)
);
revoke all on table private.meta_oauth_tokens from anon, authenticated;
comment on table private.meta_oauth_tokens is 'Encrypted Meta OAuth tokens for server-side ContentFlow use. Never expose ciphertext or credentials to clients.';
