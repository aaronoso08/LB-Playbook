-- =====================================================================
-- Latino Built Team Playbook: update 13 (Growth path). Safe to run again.
-- Run AFTER team_update_12.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- The Growth path tracks people and businesses as they move up:
-- new to the trades > learning a trade > skilled worker > lead or foreman >
-- starting a business > licensed contractor > growing contractor > general contractor and mentor.
-- Each step is a checklist item with the date it was done. The steps themselves live in the page,
-- so they can change without a database update. Certifications already on the Certifications page
-- check their steps off automatically.
-- Do not record immigration status, Social Security numbers, income or health details here.
-- Staff only, like everything else.
-- =====================================================================

create table if not exists public.growth_people (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  company     text,
  start_track text not null default 'worker' check (start_track in ('worker','business')),
  trade       text,
  area        text,
  phone       text,
  email       text,
  language    text,
  staff_owner text,
  goal        text,
  notes       text,
  cert_id     uuid,
  is_member   boolean not null default false,
  active      boolean not null default true,
  created_by  text not null,
  created_at  timestamptz not null default now(),
  updated_by  text,
  updated_at  timestamptz not null default now()
);
create table if not exists public.growth_steps (
  person_id  uuid not null references public.growth_people(id) on delete cascade,
  step_key   text not null,
  status     text not null default 'done' check (status in ('done','skip')),
  done_on    date,
  note       text,
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (person_id, step_key)
);
alter table public.growth_people enable row level security;
alter table public.growth_steps enable row level security;
revoke all on public.growth_people, public.growth_steps from anon, authenticated;

create or replace function public.growth_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'persons', coalesce((select jsonb_agg(to_jsonb(g) || jsonb_build_object(
        'steps', coalesce((select jsonb_object_agg(s.step_key, jsonb_build_object('status', s.status, 'done_on', s.done_on, 'note', s.note, 'by', s.updated_by))
                           from public.growth_steps s where s.person_id = g.id), '{}'::jsonb),
        'certs', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'issued_on', i.issued_on, 'expires_on', i.expires_on, 'number', i.number))
                           from public.cert_items i where g.cert_id is not null and i.contractor_id = g.cert_id), '[]'::jsonb))
        order by lower(g.name)) from public.growth_people g where g.active), '[]'::jsonb),
    'unlinked_certs', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'company', c.company, 'contact', c.contact, 'trade', c.trade, 'area', c.area,
        'phone', c.phone, 'email', c.email, 'is_member', c.is_member) order by lower(c.company))
        from public.cert_contractors c where c.active and not exists (select 1 from public.growth_people g where g.active and g.cert_id = c.id)), '[]'::jsonb)
  );
end; $fn$;

create or replace function public.growth_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_owner text := nullif(trim(coalesce(p->>'staff_owner','')),'');
        v_track text := case when p->>'start_track' = 'business' then 'business' else 'worker' end; v_cert uuid := nullif(p->>'cert_id','')::uuid;
begin
  m := public.team_need();
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'Add a name.'; end if;
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  if v_cert is not null and not exists (select 1 from public.cert_contractors where id = v_cert) then v_cert := null; end if;
  if v_id is null then
    insert into public.growth_people(name, company, start_track, trade, area, phone, email, language, staff_owner, goal, notes, cert_id, is_member, created_by, updated_by)
    values (left(trim(p->>'name'),120), left(p->>'company',160), v_track, left(p->>'trade',120), left(p->>'area',120), left(p->>'phone',60),
            left(p->>'email',200), left(p->>'language',20), v_owner, left(p->>'goal',300), left(p->>'notes',2000), v_cert,
            coalesce((p->>'is_member')::boolean,false), m.name, m.name)
    returning id into v_id;
  else
    update public.growth_people set name = left(trim(p->>'name'),120), company = left(p->>'company',160), start_track = v_track,
      trade = left(p->>'trade',120), area = left(p->>'area',120), phone = left(p->>'phone',60), email = left(p->>'email',200),
      language = left(p->>'language',20), staff_owner = v_owner, goal = left(p->>'goal',300), notes = left(p->>'notes',2000),
      cert_id = v_cert, is_member = coalesce((p->>'is_member')::boolean, is_member), updated_by = m.name, updated_at = now()
    where id = v_id and active;
    if not found then raise exception 'That person is gone. Refresh the page.'; end if;
  end if;
  return v_id;
end; $fn$;

-- Check off a step (status done or skip), or clear it (status empty)
create or replace function public.growth_step(tok text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_pid uuid := (p->>'person_id')::uuid; v_key text := left(nullif(trim(coalesce(p->>'step_key','')),''),40);
        v_status text := nullif(p->>'status','');
begin
  m := public.team_need();
  if v_key is null or v_key !~ '^[a-z0-9_]+$' then raise exception 'Missing step.'; end if;
  if not exists (select 1 from public.growth_people where id = v_pid and active) then raise exception 'That person is gone. Refresh the page.'; end if;
  if v_status is null then
    delete from public.growth_steps where person_id = v_pid and step_key = v_key;
  else
    if v_status not in ('done','skip') then raise exception 'Pick done or does not apply.'; end if;
    insert into public.growth_steps(person_id, step_key, status, done_on, note, updated_by, updated_at)
    values (v_pid, v_key, v_status, case when v_status = 'done' then coalesce(nullif(p->>'done_on','')::date, (now() at time zone 'America/Los_Angeles')::date) end,
            nullif(left(trim(coalesce(p->>'note','')),300),''), m.name, now())
    on conflict (person_id, step_key) do update set status = excluded.status, done_on = excluded.done_on,
      note = coalesce(excluded.note, growth_steps.note), updated_by = m.name, updated_at = now();
  end if;
  update public.growth_people set updated_by = m.name, updated_at = now() where id = v_pid;
  return true;
end; $fn$;

-- Remove someone from the path (kept in the database, just hidden)
create or replace function public.growth_remove(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  update public.growth_people set active = false, updated_by = m.name, updated_at = now()
   where id = p_id and (m.is_admin or created_by = m.name or staff_owner = m.name);
  if not found then raise exception 'Only an admin, the person''s staff contact, or whoever added them can remove them.'; end if;
  return true;
end; $fn$;

-- Bring in contractors from the Certifications page (as businesses), skipping ones already on the path
create or replace function public.growth_import_certs(tok text) returns int
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; n int;
begin
  m := public.team_need();
  insert into public.growth_people(name, company, start_track, trade, area, phone, email, cert_id, is_member, created_by, updated_by)
  select coalesce(nullif(trim(c.contact),''), c.company), c.company, 'business', c.trade, c.area, c.phone, c.email, c.id, c.is_member, m.name, m.name
    from public.cert_contractors c
   where c.active and not exists (select 1 from public.growth_people g where g.active and g.cert_id = c.id);
  get diagnostics n = row_count;
  return n;
end; $fn$;

-- Program pulse: the Membership card now also counts people on the Growth path
create or replace function public.pulse_auto() returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare y date := date_trunc('year', (now() at time zone 'America/Los_Angeles'))::date;
        mo timestamptz := date_trunc('month', now());
        done_stages text[] := array['paid','closed','noteligible','noanswer','referredout'];
begin
  return jsonb_build_object(
    'hhgp', jsonb_build_array(
       jsonb_build_object('label','Homes in progress','value',(select count(*) from hhgp_homes where not archived and program='HHGP' and stage <> all(done_stages) and stage <> 'hold')),
       jsonb_build_object('label','Paid this year','value',(select count(*) from hhgp_homes where program='HHGP' and stage='paid' and coalesce(paid_on, updated_at::date) >= y)),
       jsonb_build_object('label','$ paid this year','value','$'||to_char((select coalesce(sum(paid_amt),0) from hhgp_homes where program='HHGP' and stage='paid' and coalesce(paid_on, updated_at::date) >= y),'FM999,999,990'))),
    'nhe', jsonb_build_array(
       jsonb_build_object('label','Homes in progress','value',(select count(*) from hhgp_homes where not archived and program='PCEF' and stage <> all(done_stages) and stage <> 'hold')),
       jsonb_build_object('label','Homes done','value',(select count(*) from hhgp_homes where program='PCEF' and stage='paid'))),
    'jobs', jsonb_build_array(
       jsonb_build_object('label','Jobs taking bids','value',(select count(*) from bid_jobs where status='open' and due_at > now())),
       jsonb_build_object('label','Bids this month','value',(select count(*) from bid_submissions where created_at >= mo)),
       jsonb_build_object('label','On job alerts','value',(select count(*) from bid_alert_subs where active))),
    'grants', jsonb_build_array(
       jsonb_build_object('label','Working on','value',(select count(*) from grant_apps where not archived and status in ('considering','applying'))),
       jsonb_build_object('label','Waiting to hear','value',(select count(*) from grant_apps where not archived and status='submitted')),
       jsonb_build_object('label','Won this year','value',(select count(*) from grant_apps where status='won' and coalesce(decided_on, updated_at::date) >= y))),
    'training', jsonb_build_array(
       jsonb_build_object('label','Certs expiring in 60 days','value',(select count(*) from cert_items i join cert_contractors c on c.id=i.contractor_id
                           where c.active and i.expires_on between (now() at time zone 'America/Los_Angeles')::date and (now() at time zone 'America/Los_Angeles')::date + 60))),
    'members', jsonb_build_array(
       jsonb_build_object('label','On the growth path','value',(select count(*) from growth_people where active)),
       jsonb_build_object('label','Steps reached this year','value',(select count(*) from growth_steps s join growth_people g on g.id = s.person_id
                           where g.active and s.status = 'done' and s.done_on >= y)))
  );
end; $fn$;

revoke all on function public.pulse_auto() from public, anon, authenticated;
do $do$
declare f text;
begin
  foreach f in array array['growth_list(text)','growth_save(text,jsonb)','growth_step(text,jsonb)','growth_remove(text,uuid)','growth_import_certs(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
