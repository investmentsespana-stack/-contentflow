-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.upsert_meta_oauth_token(
  p_app_id text,
  p_user_id text,
  p_page_id text,
  p_instagram_id text,
  p_scopes text[],
  p_tasks text[],
  p_token_ciphertext text,
  p_token_iv text,
  p_token_tag text,
  p_token_fingerprint text,
  p_expires_at timestamptz
) returns void
language plpgsql
security definer
set search_path = private, public
as $$
begin
  insert into private.meta_oauth_tokens (
    provider, app_id, user_id, page_id, instagram_id, scopes, tasks,
    token_ciphertext, token_iv, token_tag, token_fingerprint, expires_at, updated_at
  ) values (
    'meta', p_app_id, p_user_id, p_page_id, p_instagram_id, coalesce(p_scopes,'{}'), coalesce(p_tasks,'{}'),
    p_token_ciphertext, p_token_iv, p_token_tag, p_token_fingerprint, p_expires_at, now()
  )
  on conflict (provider, app_id, page_id) do update set
    user_id = excluded.user_id,
    instagram_id = excluded.instagram_id,
    scopes = excluded.scopes,
    tasks = excluded.tasks,
    token_ciphertext = excluded.token_ciphertext,
    token_iv = excluded.token_iv,
    token_tag = excluded.token_tag,
    token_fingerprint = excluded.token_fingerprint,
    expires_at = excluded.expires_at,
    updated_at = now();
end;
$$;
revoke all on function public.upsert_meta_oauth_token(text,text,text,text,text[],text[],text,text,text,text,timestamptz) from public, anon, authenticated;
grant execute on function public.upsert_meta_oauth_token(text,text,text,text,text[],text[],text,text,text,text,timestamptz) to service_role;
