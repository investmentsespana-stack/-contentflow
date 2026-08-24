-- Current production-equivalent definition captured for recovery lineage.
create or replace function public.contentflow_strip_internal_execution_identity(p_run_id bigint, p_text text)
returns text
language plpgsql
immutable
set search_path to 'public'
as $function$
declare out_text text; rid text:=p_run_id::text;begin
 select string_agg(line,E'\n' order by ord) into out_text
 from unnest(string_to_array(coalesce(p_text,''),E'\n')) with ordinality as t(line,ord)
 where not (
   line ~ ('(^|[^0-9])'||rid||'([^0-9]|$)')
   and lower(line) ~ '(builder|constructor|run|corrida|ejecuci[oó]n|execution|source[_ ]?run|correlation|correlaci[oó]n|evidence|evidencia|trace|traza|identificador|\bid\b)'
 );
 return coalesce(out_text,'');
end$function$;

create or replace function public.contentflow_builder_result_identity_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare cleaned text;begin
 if new.result is not null and new.id is not null then
   cleaned:=public.contentflow_strip_internal_execution_identity(new.id,new.result);
   if cleaned is distinct from new.result then new.result:=cleaned; end if;
 end if;
 return new;
end$function$;

drop trigger if exists trg_contentflow_builder_result_identity_guard on public.contentflow_builder_runs;
create trigger trg_contentflow_builder_result_identity_guard before insert or update of result on public.contentflow_builder_runs for each row execute function public.contentflow_builder_result_identity_guard();
