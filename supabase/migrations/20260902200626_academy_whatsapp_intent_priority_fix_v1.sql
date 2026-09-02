-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.academy_whatsapp_resolve_answer(p_text text, p_language text default 'es')
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v text := lower(coalesce(p_text,''));
  v_intent text := 'unknown';
  k public.academy_whatsapp_knowledge%rowtype;
  v_conf numeric := 0.40;
begin
  -- Specific user intents first. Generic identity/greeting are intentionally last
  -- so phrases such as “cuánto cuesta la academia” cannot be swallowed by “academia”.
  if v ~ '(precio|cuánto cuesta|cuanto cuesta|costo|mensualidad|pago|premium|membresía|membresia)' then v_intent:='pricing'; v_conf:=0.95;
  elsif v ~ '(inscrib|registro|registrar|entrar|acceso|unirme|unir|skool)' then v_intent:='enrollment'; v_conf:=0.90;
  elsif v ~ '(certificado|certificación|certificacion|diploma)' then v_intent:='certification'; v_conf:=0.93;
  elsif v ~ '(curso|cursos|clase|clases|programa|programas)' then v_intent:='courses'; v_conf:=0.88;
  elsif v ~ '(soporte|contacto|correo|email|ayuda|hablar con alguien|persona)' then v_intent:='support'; v_conf:=0.90;
  elsif v ~ '(página|pagina|web|sitio|website|url)' then v_intent:='website'; v_conf:=0.92;
  elsif v ~ '(método|metodo|cómo enseñan|como enseñan|aprendiendo haciendo|práctica|practica)' then v_intent:='methodology'; v_conf:=0.90;
  elsif v ~ '(qué es cygnus|que es cygnus|quienes son|quiénes son|qué es la academia|que es la academia|cygnus academy)' then v_intent:='identity'; v_conf:=0.90;
  elsif v ~ '(hola|buenas|buenos días|buenos dias|buenas tardes|buenas noches|hello|hi)' then v_intent:='greeting'; v_conf:=0.95;
  end if;

  select * into k from public.academy_whatsapp_knowledge
  where intent=v_intent and language=coalesce(nullif(p_language,''),'es') and active
  order by priority desc, updated_at desc limit 1;

  if not found then
    select * into k from public.academy_whatsapp_knowledge
    where intent='unknown' and language='es' and active order by priority desc limit 1;
    v_intent:='unknown'; v_conf:=0.30;
  end if;

  return jsonb_build_object(
    'intent',v_intent,
    'confidence',v_conf,
    'answer',k.answer_text,
    'knowledge_id',k.id,
    'requires_human',k.requires_human,
    'source_type',k.source_type,
    'source_ref',k.source_ref,
    'source_verified_at',k.source_verified_at
  );
end;
$$;
revoke all on function public.academy_whatsapp_resolve_answer(text,text) from public, anon, authenticated;
grant execute on function public.academy_whatsapp_resolve_answer(text,text) to service_role;
