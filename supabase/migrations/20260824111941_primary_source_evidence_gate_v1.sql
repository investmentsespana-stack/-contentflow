-- Current production-equivalent definition captured for recovery lineage.
create table if not exists public.contentflow_primary_source_evidence (
  id bigserial primary key,
  project_key text not null,
  task_key text not null,
  provider text not null,
  source_title text not null,
  source_url text not null,
  source_domain text not null,
  source_type text not null default 'official_primary',
  verification_status text not null default 'verified',
  verification_method text not null default 'manual_or_tool_verified',
  accessed_at timestamptz not null default now(),
  publication_or_update_date text,
  claim_scope text,
  notes text,
  created_at timestamptz not null default now(),
  unique(project_key,task_key,source_url)
);

create or replace function public.contentflow_primary_source_gate(p_project_key text,p_task_key text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare c int; domains int;begin
 select count(*),count(distinct source_domain) into c,domains
 from public.contentflow_primary_source_evidence
 where project_key=p_project_key and task_key=p_task_key and verification_status='verified' and source_type='official_primary';
 return jsonb_build_object('ok',c>=5 and domains>=4,'verified_primary_sources',c,'distinct_official_domains',domains,'minimum_sources',5,'minimum_domains',4,'architecture','PRIMARY_SOURCE_EVIDENCE_GATE_V1');
end$function$;
