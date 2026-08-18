-- Sandbox-only recovery certification schema. Do not apply to Stable production.
create schema if not exists recovery_director;
revoke all on schema recovery_director from public, anon, authenticated;

create table if not exists recovery_director.tasks (
  task_id uuid primary key default gen_random_uuid(),
  project_id text not null check (project_id in ('contentflow','opc')),
  state text not null default 'queued',
  desired_state text not null default 'completed',
  payload jsonb not null default '{}'::jsonb,
  attempt int not null default 0,
  generation bigint not null default 1,
  lease_id uuid,
  fencing_token bigint not null default 0,
  lease_expires_at timestamptz,
  worker_id text,
  evidence jsonb,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists recovery_director.events (
  event_id bigint generated always as identity primary key,
  task_id uuid references recovery_director.tasks(task_id) on delete cascade,
  event_type text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists recovery_director_events_task_idx on recovery_director.events(task_id);

-- The deployed sandbox adds service-role-only RPC wrappers around deterministic
-- create/claim/reconcile/submit/get operations. The invariant under test is:
-- expired lease => recovery_required => new claim increments fencing token =>
-- stale worker result rejected => current worker evidence accepted => completed.
