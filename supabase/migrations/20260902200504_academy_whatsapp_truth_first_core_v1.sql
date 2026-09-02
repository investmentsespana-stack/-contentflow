-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create extension if not exists pgcrypto;

create table if not exists public.academy_whatsapp_config (
  id smallint primary key default 1 check (id=1),
  phone_e164 text not null,
  waba_id text,
  phone_number_id text,
  verified_name text,
  status text not null default 'meta_binding_required' check (status in ('prepared','meta_binding_required','registered','active','paused','error')),
  enabled boolean not null default false,
  webhook_verified boolean not null default false,
  access_token_configured boolean not null default false,
  app_secret_configured boolean not null default false,
  verify_token_configured boolean not null default false,
  graph_version_configured boolean not null default false,
  last_verified_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.academy_whatsapp_config(id,phone_e164,status,enabled,metadata)
values(1,'+18433041495','meta_binding_required',false,jsonb_build_object('channel','WhatsApp Business — Cygnus','mode','truth_first_verified_information','created_for','Cygnus Academy AI'))
on conflict (id) do update set phone_e164=excluded.phone_e164, updated_at=now();

create table if not exists public.academy_whatsapp_knowledge (
  id uuid primary key default gen_random_uuid(),
  intent text not null,
  language text not null default 'es',
  topic text not null,
  answer_text text not null,
  source_type text not null,
  source_ref text not null,
  source_verified_at timestamptz not null,
  requires_human boolean not null default false,
  active boolean not null default true,
  priority integer not null default 50,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(intent,language)
);

create table if not exists public.academy_whatsapp_conversations (
  id uuid primary key default gen_random_uuid(),
  wa_id text not null unique,
  display_name text,
  language text not null default 'es',
  status text not null default 'open' check(status in ('open','human_required','human_active','closed')),
  last_intent text,
  human_required boolean not null default false,
  opened_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  closed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.academy_whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.academy_whatsapp_conversations(id) on delete cascade,
  whatsapp_message_id text unique,
  direction text not null check(direction in ('inbound','outbound')),
  message_type text not null default 'text',
  body text,
  intent text,
  knowledge_id uuid references public.academy_whatsapp_knowledge(id),
  confidence numeric(4,3),
  status text not null default 'received',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.academy_whatsapp_outbox (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.academy_whatsapp_conversations(id) on delete cascade,
  recipient_wa_id text not null,
  body text not null,
  source_knowledge_id uuid references public.academy_whatsapp_knowledge(id),
  status text not null default 'pending' check(status in ('pending','sent','failed','blocked')),
  whatsapp_message_id text,
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create table if not exists public.academy_whatsapp_handoffs (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.academy_whatsapp_conversations(id) on delete cascade,
  reason text not null,
  user_question text,
  status text not null default 'open' check(status in ('open','assigned','resolved','closed')),
  requested_at timestamptz not null default now(),
  assigned_at timestamptz,
  resolved_at timestamptz,
  resolution_note text,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists academy_whatsapp_messages_conversation_idx on public.academy_whatsapp_messages(conversation_id,created_at desc);
create index if not exists academy_whatsapp_outbox_status_idx on public.academy_whatsapp_outbox(status,created_at);
create index if not exists academy_whatsapp_handoffs_status_idx on public.academy_whatsapp_handoffs(status,requested_at);

alter table public.academy_whatsapp_config enable row level security;
alter table public.academy_whatsapp_knowledge enable row level security;
alter table public.academy_whatsapp_conversations enable row level security;
alter table public.academy_whatsapp_messages enable row level security;
alter table public.academy_whatsapp_outbox enable row level security;
alter table public.academy_whatsapp_handoffs enable row level security;

revoke all on public.academy_whatsapp_config from anon, authenticated;
revoke all on public.academy_whatsapp_knowledge from anon, authenticated;
revoke all on public.academy_whatsapp_conversations from anon, authenticated;
revoke all on public.academy_whatsapp_messages from anon, authenticated;
revoke all on public.academy_whatsapp_outbox from anon, authenticated;
revoke all on public.academy_whatsapp_handoffs from anon, authenticated;

delete from public.academy_whatsapp_knowledge where language='es' and intent in ('greeting','identity','methodology','website','support','pricing','enrollment','courses','certification','unknown');

insert into public.academy_whatsapp_knowledge(intent,language,topic,answer_text,source_type,source_ref,source_verified_at,requires_human,priority,metadata) values
('greeting','es','Bienvenida','Hola. Soy el sistema de información verificada de Cygnus Academy AI. Puedo ayudarte con información oficial sobre la Academia, su metodología y sus canales de contacto. Si algo no está confirmado en nuestra base oficial, no lo inventaré y lo pasaré a soporte humano.','institutional_contract','Cygnus WhatsApp truth-first contract v1',now(),false,100,'{}'),
('identity','es','Identidad institucional','Cygnus Academy AI es una academia de formación práctica en inteligencia artificial orientada al trabajo. Su principio institucional es “Aprendiendo Haciendo — Formación para el trabajo”.','public_website','https://www.cygnusacademyai.com/',now(),false,100,'{}'),
('methodology','es','Metodología','En Cygnus se aprende ejecutando: teoría necesaria, demostración, práctica, feedback, evaluación y proyectos. La arquitectura académica prioriza aproximadamente 20% teoría, 30% demostración y 50% práctica.','academic_contract','Cygnus academic master architecture',now(),false,95,'{}'),
('website','es','Sitio oficial','El sitio oficial de Cygnus Academy AI es https://www.cygnusacademyai.com/.','public_website','https://www.cygnusacademyai.com/',now(),false,100,'{}'),
('support','es','Soporte','El canal de contacto institucional publicado actualmente es social@investmentsespana.space. También puedo dejar tu consulta marcada para atención humana si necesitas una respuesta que no esté confirmada en nuestra base.','public_website','https://www.cygnusacademyai.com/',now(),false,90,'{}'),
('pricing','es','Precios y membresías','No tengo un precio vigente certificado para darte en este momento. Para evitar darte información incorrecta, voy a dejar esta consulta para atención humana.','approval_required','Pricing requires current approved offer',now(),true,100,'{}'),
('enrollment','es','Inscripción y acceso','La ruta exacta de inscripción o acceso debe corresponder a la oferta vigente. Como todavía no tengo un enlace de inscripción certificado en esta base, voy a dejar tu consulta para atención humana.','approval_required','Enrollment destination requires verified current link',now(),true,100,'{}'),
('courses','es','Cursos disponibles','Puedo explicarte la metodología de Cygnus, pero no debo afirmar que un curso específico está disponible hasta que su estado de publicación esté certificado. Voy a dejar tu consulta para atención humana para darte la oferta vigente.','approval_required','Course availability must be runtime-certified',now(),true,100,'{}'),
('certification','es','Certificación','Cygnus está diseñado con evaluación por competencias y una arquitectura de certificación, pero no debo prometer una certificación específica sin verificar el curso y las condiciones vigentes. Voy a dejar tu consulta para atención humana.','academic_contract','Certification architecture requires course-specific verification',now(),true,90,'{}'),
('unknown','es','Consulta no verificada','No tengo una respuesta oficial suficientemente verificada para esa pregunta. Prefiero no inventarla. Voy a dejar la consulta registrada para que una persona de Cygnus pueda responderte con información correcta.','truth_first_policy','Cygnus WhatsApp truth-first contract v1',now(),true,100,'{}');

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
  if v ~ '(hola|buenas|buenos días|buenos dias|buenas tardes|buenas noches|hello|hi)' then v_intent:='greeting'; v_conf:=0.95;
  elsif v ~ '(qué es cygnus|que es cygnus|quienes son|quiénes son|academia|cygnus academy)' then v_intent:='identity'; v_conf:=0.90;
  elsif v ~ '(método|metodo|cómo enseñan|como enseñan|aprendiendo haciendo|práctica|practica)' then v_intent:='methodology'; v_conf:=0.90;
  elsif v ~ '(página|pagina|web|sitio|website|url)' then v_intent:='website'; v_conf:=0.92;
  elsif v ~ '(soporte|contacto|correo|email|ayuda|hablar con alguien|persona)' then v_intent:='support'; v_conf:=0.90;
  elsif v ~ '(precio|cuánto cuesta|cuanto cuesta|costo|mensualidad|pago|premium|membresía|membresia)' then v_intent:='pricing'; v_conf:=0.95;
  elsif v ~ '(inscrib|registro|registrar|entrar|acceso|unirme|unir|skool)' then v_intent:='enrollment'; v_conf:=0.90;
  elsif v ~ '(curso|cursos|clase|clases|programa|programas)' then v_intent:='courses'; v_conf:=0.88;
  elsif v ~ '(certificado|certificación|certificacion|diploma)' then v_intent:='certification'; v_conf:=0.93;
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
