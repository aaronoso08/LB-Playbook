-- =====================================================================
-- Latino Built Team Playbook: update 9 (certifications, grant applications, answer bank, impact). Safe to run again.
-- Run AFTER team_update_8.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- 1) Contractor certifications: BPI, RRP, CCB, COBID, insurance and more, with expiration dates.
-- 2) Grant applications: every grant we chase, from "considering" to won or lost.
-- 3) Grant answer bank: our best reusable answers, in English and Spanish. Starts with drafts to fill in.
-- 4) Impact: yearly numbers pulled from everything above, plus a few numbers typed in by hand.
-- Staff only, like everything else. Nothing here is visible to the public.
-- =====================================================================

-- ---------- 1) Certifications ----------
create table if not exists public.cert_contractors (
  id         uuid primary key default gen_random_uuid(),
  company    text not null,
  contact    text,
  phone      text,
  email      text,
  trade      text,
  area       text,
  is_member  boolean not null default false,
  notes      text,
  active     boolean not null default true,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now()
);
create table if not exists public.cert_items (
  id            uuid primary key default gen_random_uuid(),
  contractor_id uuid not null references public.cert_contractors(id) on delete cascade,
  kind          text not null check (kind in ('BPI','BPI BA-P','Lead RRP','CCB','COBID','Insurance','Bond','Other')),
  label         text,
  number        text,
  issued_on     date,
  expires_on    date,
  notes         text,
  updated_by    text,
  updated_at    timestamptz not null default now()
);
create index if not exists cert_items_contractor_idx on public.cert_items(contractor_id);
alter table public.cert_contractors enable row level security;
alter table public.cert_items enable row level security;
revoke all on public.cert_contractors, public.cert_items from anon, authenticated;

create or replace function public.cert_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'contractors', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('items',
        coalesce((select jsonb_agg(to_jsonb(i) order by i.kind) from public.cert_items i where i.contractor_id = c.id), '[]'::jsonb))
        order by lower(c.company)) from public.cert_contractors c where c.active), '[]'::jsonb)
  );
end; $fn$;

create or replace function public.cert_save_contractor(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid;
begin
  m := public.team_need();
  if coalesce(trim(p->>'company'),'') = '' then raise exception 'Add the company name.'; end if;
  if v_id is null then
    insert into public.cert_contractors(company, contact, phone, email, trade, area, is_member, notes, created_by, updated_by)
    values (left(trim(p->>'company'),160), left(p->>'contact',160), left(p->>'phone',120), left(p->>'email',200), left(p->>'trade',160),
            left(p->>'area',160), coalesce((p->>'is_member')::boolean,false), left(p->>'notes',2000), m.name, m.name)
    returning id into v_id;
  else
    update public.cert_contractors set company = left(trim(p->>'company'),160), contact = left(p->>'contact',160), phone = left(p->>'phone',120),
      email = left(p->>'email',200), trade = left(p->>'trade',160), area = left(p->>'area',160),
      is_member = coalesce((p->>'is_member')::boolean,false), notes = left(p->>'notes',2000),
      active = coalesce((p->>'active')::boolean, active), updated_by = m.name, updated_at = now()
    where id = v_id;
    if not found then raise exception 'That contractor is gone. Refresh the page.'; end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.cert_save_item(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid;
begin
  m := public.team_need();
  if v_id is null then
    insert into public.cert_items(contractor_id, kind, label, number, issued_on, expires_on, notes, updated_by)
    values ((p->>'contractor_id')::uuid, p->>'kind', left(p->>'label',120), left(p->>'number',80),
            nullif(p->>'issued_on','')::date, nullif(p->>'expires_on','')::date, left(p->>'notes',1000), m.name)
    returning id into v_id;
  else
    update public.cert_items set kind = p->>'kind', label = left(p->>'label',120), number = left(p->>'number',80),
      issued_on = nullif(p->>'issued_on','')::date, expires_on = nullif(p->>'expires_on','')::date, notes = left(p->>'notes',1000),
      updated_by = m.name, updated_at = now()
    where id = v_id;
    if not found then raise exception 'That certification is gone. Refresh the page.'; end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.cert_delete_item(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.cert_items where id = p_id;
  return found;
end; $fn$;

-- Bring in the contractors already on the Playbook's contractor list (skips ones already added)
create or replace function public.cert_import(tok text, p jsonb) returns int
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; r jsonb; it jsonb; v_id uuid; n int := 0;
begin
  m := public.team_need();
  for r in select * from jsonb_array_elements(p) loop
    continue when coalesce(trim(r->>'company'),'') = '';
    continue when exists (select 1 from public.cert_contractors where lower(company) = lower(trim(r->>'company')));
    insert into public.cert_contractors(company, contact, phone, email, trade, area, notes, created_by, updated_by)
    values (left(trim(r->>'company'),160), left(r->>'contact',160), left(r->>'phone',120), left(r->>'email',200), left(r->>'trade',160),
            left(r->>'area',160), left(r->>'notes',2000), m.name, m.name)
    returning id into v_id;
    for it in select * from jsonb_array_elements(coalesce(r->'items','[]'::jsonb)) loop
      insert into public.cert_items(contractor_id, kind, number, notes, updated_by)
      values (v_id, it->>'kind', left(it->>'number',80), left(it->>'notes',1000), m.name);
    end loop;
    n := n + 1;
  end loop;
  return n;
end; $fn$;

-- ---------- 2) Grant applications ----------
create table if not exists public.grant_apps (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  funder       text,
  opp_ref      text,
  status       text not null default 'considering' check (status in ('considering','applying','submitted','won','lost','passed')),
  owner        text,
  amount_req   numeric,
  amount_won   numeric,
  due_on       date,
  submitted_on date,
  decided_on   date,
  url          text,
  notes        text,
  archived     boolean not null default false,
  created_by   text not null,
  created_at   timestamptz not null default now(),
  updated_by   text,
  updated_at   timestamptz not null default now()
);
alter table public.grant_apps enable row level security;
revoke all on public.grant_apps from anon, authenticated;

-- ---------- 3) Answer bank ----------
create table if not exists public.grant_answers (
  id         uuid primary key default gen_random_uuid(),
  topic      text not null,
  category   text not null default 'About us',
  body_en    text,
  body_es    text,
  is_draft   boolean not null default true,
  sort       int not null default 100,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.grant_answers enable row level security;
revoke all on public.grant_answers from anon, authenticated;

create or replace function public.grant_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'apps', coalesce((select jsonb_agg(to_jsonb(a) order by a.due_on nulls last, a.created_at) from public.grant_apps a where not a.archived), '[]'::jsonb),
    'answers', coalesce((select jsonb_agg(to_jsonb(x) order by x.sort, x.topic) from public.grant_answers x), '[]'::jsonb)
  );
end; $fn$;

create or replace function public.grant_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_owner text; v_status text; old public.grant_apps;
begin
  m := public.team_need();
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'Add a name for the grant.'; end if;
  v_owner := nullif(trim(coalesce(p->>'owner','')),'');
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  v_status := coalesce(nullif(p->>'status',''),'considering');
  if v_status not in ('considering','applying','submitted','won','lost','passed') then raise exception 'Unknown status.'; end if;
  if v_id is null then
    if nullif(p->>'opp_ref','') is not null and exists (select 1 from public.grant_apps where opp_ref = p->>'opp_ref' and not archived) then
      raise exception 'ALREADY: This one is already on the applications board.'; end if;
    insert into public.grant_apps(title, funder, opp_ref, status, owner, amount_req, amount_won, due_on, submitted_on, decided_on, url, notes, created_by, updated_by)
    values (left(trim(p->>'title'),300), left(p->>'funder',200), left(p->>'opp_ref',200), v_status, v_owner,
            nullif(p->>'amount_req','')::numeric, nullif(p->>'amount_won','')::numeric, nullif(p->>'due_on','')::date,
            coalesce(nullif(p->>'submitted_on','')::date, case when v_status = 'submitted' then current_date end),
            coalesce(nullif(p->>'decided_on','')::date, case when v_status in ('won','lost') then current_date end),
            left(p->>'url',600), left(p->>'notes',4000), m.name, m.name)
    returning id into v_id;
  else
    select * into old from public.grant_apps where id = v_id;
    if old.id is null then raise exception 'That application is gone. Refresh the page.'; end if;
    update public.grant_apps set title = left(trim(p->>'title'),300), funder = left(p->>'funder',200), status = v_status, owner = v_owner,
      amount_req = nullif(p->>'amount_req','')::numeric, amount_won = nullif(p->>'amount_won','')::numeric,
      due_on = nullif(p->>'due_on','')::date,
      submitted_on = coalesce(nullif(p->>'submitted_on','')::date, case when v_status = 'submitted' and old.status <> 'submitted' then current_date else old.submitted_on end),
      decided_on = coalesce(nullif(p->>'decided_on','')::date, case when v_status in ('won','lost') and old.status not in ('won','lost') then current_date else old.decided_on end),
      url = left(p->>'url',600), notes = left(p->>'notes',4000),
      archived = coalesce((p->>'archived')::boolean, archived), updated_by = m.name, updated_at = now()
    where id = v_id;
  end if;
  return v_id;
end; $fn$;

create or replace function public.answer_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid;
begin
  m := public.team_need();
  if coalesce(trim(p->>'topic'),'') = '' then raise exception 'Add a topic.'; end if;
  if v_id is null then
    insert into public.grant_answers(topic, category, body_en, body_es, is_draft, sort, updated_by)
    values (left(trim(p->>'topic'),200), coalesce(nullif(p->>'category',''),'About us'), left(p->>'body_en',8000), left(p->>'body_es',8000),
            coalesce((p->>'is_draft')::boolean,false), coalesce(nullif(p->>'sort','')::int,100), m.name)
    returning id into v_id;
  else
    update public.grant_answers set topic = left(trim(p->>'topic'),200), category = coalesce(nullif(p->>'category',''),'About us'),
      body_en = left(p->>'body_en',8000), body_es = left(p->>'body_es',8000), is_draft = coalesce((p->>'is_draft')::boolean,false),
      updated_by = m.name, updated_at = now()
    where id = v_id;
    if not found then raise exception 'That answer is gone. Refresh the page.'; end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.answer_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not m.is_admin then raise exception 'Only an admin can delete answers. You can edit them instead.'; end if;
  delete from public.grant_answers where id = p_id;
  return found;
end; $fn$;

-- Starter answers (only added once, if the bank is empty). Words in [brackets] need to be filled in or checked.
do $seed$
begin
  if not exists (select 1 from public.grant_answers) then
    insert into public.grant_answers(topic, category, sort, is_draft, updated_by, body_en, body_es) values
    ('Mission statement (short)','About us',10,true,'Playbook',
     'Latino Built is a trade association that helps Latino contractors in the Portland metro area and Southwest Washington grow strong, licensed and certified businesses, and connects Latino and low-income homeowners with healthy, safe and energy-efficient home repairs. [Check this against our official mission statement.]',
     'Latino Built es una asociación de contratistas que ayuda a los contratistas latinos del área metropolitana de Portland y el suroeste de Washington a crecer con negocios sólidos, con licencia y certificados, y conecta a familias latinas y de bajos ingresos con reparaciones de vivienda sanas, seguras y eficientes. [Compara con nuestra misión oficial.]'),
    ('Organization history','About us',20,true,'Playbook',
     'Latino Built was founded in [year] by [founders] to [why it started]. Since then we have grown to [number] staff and a network of more than 300 Latino contractors across Portland metro and Southwest Washington. [Add 2 or 3 milestones.]',
     'Latino Built se fundó en [año] por [fundadores] para [por qué empezó]. Desde entonces hemos crecido a [número] empleados y una red de más de 300 contratistas latinos en Portland metro y el suroeste de Washington. [Agrega 2 o 3 logros.]'),
    ('Who we serve','About us',30,true,'Playbook',
     'We serve two groups. First, Latino-owned contracting businesses, many of them small and family-run, who face language barriers, limited access to certifications, and little access to public and program work. Second, Latino and low-income homeowners, many of them Spanish-speaking, who live in older homes with health, safety and energy problems and have trouble navigating repair and energy programs. [Add numbers: members, homeowners served last year.]',
     'Servimos a dos grupos. Primero, negocios de construcción de dueños latinos, muchos pequeños y familiares, que enfrentan barreras de idioma, poco acceso a certificaciones y poco acceso a trabajos públicos y de programas. Segundo, familias latinas y de bajos ingresos, muchas de habla hispana, que viven en casas antiguas con problemas de salud, seguridad y energía y a quienes se les dificulta usar los programas de reparación y energía. [Agrega números: miembros, familias atendidas el año pasado.]'),
    ('Programs we run','Programs',40,true,'Playbook',
     'Healthy Homes Grant Program (HHGP): health, safety, accessibility and weatherization repairs for income-qualified homeowners, with Healthy Homes Assessments done by our BPI-trained assessor. Nuestro Hogar - Electric: whole-home electrification and energy upgrades for 20 Portland homes, funded by a $1,526,915 PCEF grant. Nuestro Hogar - Gas: energy efficiency work for Latino NW Natural customers. Community Heat Pump Deployment Program and Oregon HOMES/HEAR rebates as a delivery partner with Earth Advantage. Contractor support: trainings like Lead RRP, a bid board that sends job leads to member contractors, job alerts, and quarterly member meetings. [Update numbers each year.]',
     'Healthy Homes Grant Program (HHGP): reparaciones de salud, seguridad, accesibilidad y climatización para dueños que califican por ingresos, con evaluaciones Healthy Homes hechas por nuestro evaluador capacitado en BPI. Nuestro Hogar - Electric: electrificación y mejoras energéticas de 20 casas en Portland, con una beca de $1,526,915 de PCEF. Nuestro Hogar - Gas: eficiencia energética para clientes latinos de NW Natural. Community Heat Pump Deployment Program y reembolsos HOMES/HEAR de Oregón como aliado de Earth Advantage. Apoyo a contratistas: capacitaciones como Lead RRP, un tablero de ofertas que manda trabajos a contratistas miembros, alertas de trabajos y reuniones trimestrales. [Actualiza los números cada año.]'),
    ('Culturally specific approach and language access','Programs',50,true,'Playbook',
     'Everything we do is bilingual and built by and for the Latino community. Staff speak Spanish, homeowners get texts, calls and forms in Spanish, and contractor trainings are taught in Spanish. Because we are a trusted community organization, families who would not answer a utility or government program reach out to us. [Add a short example or quote.]',
     'Todo lo que hacemos es bilingüe y hecho por y para la comunidad latina. El personal habla español, las familias reciben mensajes, llamadas y formularios en español, y las capacitaciones para contratistas son en español. Como somos una organización de confianza, familias que no responderían a una compañía o programa del gobierno nos buscan a nosotros. [Agrega un ejemplo o cita breve.]'),
    ('Workforce and contractor development','Programs',60,true,'Playbook',
     'We help Latino contractors get licensed, certified and ready for program work: Lead RRP and BPI trainings, help with CCB licensing and COBID certification, a bid board and job alerts for member contractors, and one-on-one support to bid and complete program jobs. We track every member''s certifications and expiration dates, so programs can count on a ready network of certified Latino contractors. [Add how many contractors were trained or certified this year.]',
     'Ayudamos a contratistas latinos a obtener licencias y certificaciones y a prepararse para trabajos de programas: capacitaciones de Lead RRP y BPI, ayuda con la licencia CCB y la certificación COBID, un tablero de ofertas y alertas de trabajo para miembros, y apoyo personal para ofertar y terminar trabajos. Llevamos el registro de las certificaciones de cada miembro y sus vencimientos, para que los programas cuenten con una red lista de contratistas latinos certificados. [Agrega cuántos contratistas se capacitaron o certificaron este año.]'),
    ('Staff and capacity','Organization',70,true,'Playbook',
     'Our team of [number] includes an Executive Director, Operations, a Program Director, a Green Program Manager, a Home Energy Assessor working toward BPI certifications, a Program Navigator, membership and business technical assistance staff, and outreach and communications staff. [Add names and short bios as needed.]',
     'Nuestro equipo de [número] incluye una Directora Ejecutiva, Operaciones, un Director de Programas, un Gerente de Programas Verdes, un Evaluador de Energía en el Hogar que avanza en certificaciones BPI, una Navegadora de Programas, personal de membresía y asistencia técnica a negocios, y personal de alcance y comunicaciones. [Agrega nombres y biografías breves si hace falta.]'),
    ('Partnerships','Organization',80,true,'Playbook',
     'We partner with the Oregon Health Authority (Healthy Homes Grant Program), the Portland Clean Energy Fund (Nuestro Hogar - Electric), NW Natural (Nuestro Hogar - Gas), Earth Advantage (HOMES/HEAR and PCEF quality assurance), and community home repair organizations we refer families to when another program is a better fit. [Add letters of support you can ask for.]',
     'Trabajamos con la Oregon Health Authority (Healthy Homes Grant Program), el Portland Clean Energy Fund (Nuestro Hogar - Electric), NW Natural (Nuestro Hogar - Gas), Earth Advantage (HOMES/HEAR y control de calidad de PCEF) y organizaciones comunitarias de reparación de casas a las que referimos familias cuando otro programa les queda mejor. [Agrega cartas de apoyo que podemos pedir.]'),
    ('How we measure results','Organization',90,true,'Playbook',
     'We track every home from intake to paid in a shared pipeline, every contractor job and bid on our bid board, every contractor certification and its expiration, and every grant we apply for. Each month we report homes assessed, homes completed, dollars spent, contractors engaged and new members, and each year we publish an impact report. [Add the main outcome numbers the funder cares about.]',
     'Seguimos cada casa desde la admisión hasta el pago en un sistema compartido, cada trabajo y oferta de contratistas en nuestro tablero de ofertas, cada certificación y su vencimiento, y cada beca que solicitamos. Cada mes reportamos casas evaluadas, casas terminadas, dinero gastado, contratistas activos y nuevos miembros, y cada año publicamos un informe de impacto. [Agrega los resultados que le importan al financiador.]'),
    ('Budget and sustainability','Organization',100,true,'Playbook',
     'Our funding comes from program contracts (HHGP, PCEF, NW Natural, HOMES/HEAR), membership dues, sponsorships and grants. [Add annual budget and percent by source.] This grant would [what it pays for], and we will sustain the work by [plan].',
     'Nuestros fondos vienen de contratos de programas (HHGP, PCEF, NW Natural, HOMES/HEAR), cuotas de membresía, patrocinios y becas. [Agrega el presupuesto anual y el porcentaje por fuente.] Esta beca pagaría [qué], y sostendremos el trabajo con [plan].'),
    ('Equity statement','Organization',110,true,'Playbook',
     'Latino Built is led by and accountable to the Latino community. [Add board and staff demographics if the funder asks.] We focus our work on families and contractors who have been left out of energy and housing programs because of language, income, immigration-related fears or lack of access to information.',
     'Latino Built está dirigida por y responde a la comunidad latina. [Agrega datos de la junta y el personal si el financiador los pide.] Enfocamos el trabajo en familias y contratistas que han quedado fuera de los programas de energía y vivienda por idioma, ingresos, miedos relacionados con la inmigración o falta de información.'),
    ('Attachments checklist','Attachments',120,true,'Playbook',
     'Most funders ask for: IRS 501(c)(3) determination letter; W-9; latest Form 990 or audit; current year budget; board list with affiliations; certificate of insurance; organization chart; 1 to 3 letters of support. [Add where each file lives in SharePoint.]',
     'La mayoría de los financiadores piden: carta de determinación 501(c)(3) del IRS; W-9; el último Formulario 990 o auditoría; presupuesto del año; lista de la junta con afiliaciones; certificado de seguro; organigrama; 1 a 3 cartas de apoyo. [Agrega dónde está cada archivo en SharePoint.]');
  end if;
end $seed$;

-- ---------- 4) Impact ----------
create table if not exists public.impact_year (
  year       int primary key,
  data       jsonb not null default '{}'::jsonb,
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.impact_year enable row level security;
revoke all on public.impact_year from anon, authenticated;

create or replace function public.impact_get(tok text, p_year int) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; a timestamptz; b timestamptz;
begin
  m := public.team_need();
  a := make_date(p_year,1,1)::timestamptz; b := make_date(p_year+1,1,1)::timestamptz;
  return jsonb_build_object(
    'year', p_year,
    'manual', coalesce((select data from public.impact_year where year = p_year), '{}'::jsonb),
    'manual_by', (select updated_by from public.impact_year where year = p_year),
    'hhgp', jsonb_build_object(
      'added', (select count(*) from public.hhgp_homes where created_at >= a and created_at < b),
      'assessed', (select count(distinct e.home_id) from public.hhgp_events e join public.hhgp_homes h on h.id = e.home_id
                    where e.at >= a and e.at < b and e.what like 'Moved to assessed%' and h.stage <> 'noteligible'),
      'forward', (select count(distinct home_id) from public.hhgp_events where at >= a and at < b and what like 'Moved to reservation%'),
      'paid', (select count(*) from public.hhgp_homes where paid_on >= a::date and paid_on < b::date),
      'paid_usd', (select coalesce(sum(paid_amt),0) from public.hhgp_homes where paid_on >= a::date and paid_on < b::date)),
    'bids', jsonb_build_object(
      'jobs', (select count(*) from public.bid_jobs where created_at >= a and created_at < b and status <> 'draft'),
      'bids', (select count(*) from public.bid_submissions where created_at >= a and created_at < b),
      'bidders', (select count(distinct lower(company)) from public.bid_submissions where created_at >= a and created_at < b),
      'awarded', (select count(*) from public.bid_submissions where status = 'awarded' and updated_at >= a and updated_at < b),
      'awarded_usd', (select coalesce(sum(total),0) from public.bid_submissions where status = 'awarded' and updated_at >= a and updated_at < b),
      'alert_signups', (select count(*) from public.bid_alert_subs where created_at >= a and created_at < b),
      'alert_total', (select count(*) from public.bid_alert_subs where active)),
    'grants', jsonb_build_object(
      'submitted', (select count(*) from public.grant_apps where not archived and submitted_on >= a::date and submitted_on < b::date),
      'requested_usd', (select coalesce(sum(amount_req),0) from public.grant_apps where not archived and submitted_on >= a::date and submitted_on < b::date),
      'won', (select count(*) from public.grant_apps where not archived and status = 'won' and decided_on >= a::date and decided_on < b::date),
      'won_usd', (select coalesce(sum(amount_won),0) from public.grant_apps where not archived and status = 'won' and decided_on >= a::date and decided_on < b::date),
      'funders', coalesce((select jsonb_agg(distinct funder) from public.grant_apps where not archived and status = 'won' and decided_on >= a::date and decided_on < b::date and funder is not null), '[]'::jsonb)),
    'certs', jsonb_build_object(
      'contractors', (select count(*) from public.cert_contractors where active),
      'by_kind', coalesce((select jsonb_object_agg(kind, n) from (select i.kind, count(distinct i.contractor_id) n from public.cert_items i
                    join public.cert_contractors c on c.id = i.contractor_id and c.active
                    where i.expires_on is null or i.expires_on >= current_date group by i.kind) x), '{}'::jsonb)),
    'team', jsonb_build_object(
      'tasks_done', (select count(*) from public.team_tasks where done_at >= a and done_at < b),
      'meetings', (select count(*) from public.team_meetings where meet_on >= a::date and meet_on < b::date))
  );
end; $fn$;

create or replace function public.impact_save(tok text, p_year int, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if p_year < 2015 or p_year > 2100 then raise exception 'Pick a real year.'; end if;
  if length(p::text) > 30000 then raise exception 'That is too much text.'; end if;
  insert into public.impact_year(year, data, updated_by) values (p_year, coalesce(p,'{}'::jsonb), m.name)
  on conflict (year) do update set data = excluded.data, updated_by = m.name, updated_at = now();
  return true;
end; $fn$;

revoke all on function public.cert_list(text) from public, anon;
revoke all on function public.cert_save_contractor(text, jsonb) from public, anon;
revoke all on function public.cert_save_item(text, jsonb) from public, anon;
revoke all on function public.cert_delete_item(text, uuid) from public, anon;
revoke all on function public.cert_import(text, jsonb) from public, anon;
revoke all on function public.grant_list(text) from public, anon;
revoke all on function public.grant_save(text, jsonb) from public, anon;
revoke all on function public.answer_save(text, jsonb) from public, anon;
revoke all on function public.answer_delete(text, uuid) from public, anon;
revoke all on function public.impact_get(text, int) from public, anon;
revoke all on function public.impact_save(text, int, jsonb) from public, anon;
grant execute on function public.cert_list(text) to authenticated;
grant execute on function public.cert_save_contractor(text, jsonb) to authenticated;
grant execute on function public.cert_save_item(text, jsonb) to authenticated;
grant execute on function public.cert_delete_item(text, uuid) to authenticated;
grant execute on function public.cert_import(text, jsonb) to authenticated;
grant execute on function public.grant_list(text) to authenticated;
grant execute on function public.grant_save(text, jsonb) to authenticated;
grant execute on function public.answer_save(text, jsonb) to authenticated;
grant execute on function public.answer_delete(text, uuid) to authenticated;
grant execute on function public.impact_get(text, int) to authenticated;
grant execute on function public.impact_save(text, int, jsonb) to authenticated;
