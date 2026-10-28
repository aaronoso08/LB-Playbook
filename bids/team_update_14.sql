-- =====================================================================
-- Latino Built Team Playbook: update 14 (Growth path support log). Safe to run again.
-- Run AFTER team_update_13.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- 1) Support log: every time Latino Built helps someone on the Growth path
--    (a class, advising, a referral, a job lead, a call), it's saved with the date.
--    That's the "how we helped" story for each person, and numbers for funders.
-- 2) Steps can be checked off without a date, for things done before we met them.
-- Staff only, like everything else.
-- =====================================================================

create table if not exists public.growth_support (
  id         uuid primary key default gen_random_uuid(),
  person_id  uuid not null references public.growth_people(id) on delete cascade,
  kind       text not null check (kind in ('class','advising','referral','job','call','event','other')),
  note       text,
  on_date    date not null,
  created_by text not null,
  created_at timestamptz not null default now()
);
create index if not exists growth_support_person_idx on public.growth_support(person_id);
alter table public.growth_support enable row level security;
revoke all on public.growth_support from anon, authenticated;

-- Steps: same as before, plus "no_date" for steps done before we met them
create or replace function public.growth_step(tok text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_pid uuid := (p->>'person_id')::uuid; v_key text := left(nullif(trim(coalesce(p->>'step_key','')),''),40);
        v_status text := nullif(p->>'status',''); v_nodate boolean := coalesce((p->>'no_date')::boolean, false);
begin
  m := public.team_need();
  if v_key is null or v_key !~ '^[a-z0-9_]+$' then raise exception 'Missing step.'; end if;
  if not exists (select 1 from public.growth_people where id = v_pid and active) then raise exception 'That person is gone. Refresh the page.'; end if;
  if v_status is null then
    delete from public.growth_steps where person_id = v_pid and step_key = v_key;
  else
    if v_status not in ('done','skip') then raise exception 'Pick done or does not apply.'; end if;
    insert into public.growth_steps(person_id, step_key, status, done_on, note, updated_by, updated_at)
    values (v_pid, v_key, v_status,
            case when v_status = 'done' and not v_nodate then coalesce(nullif(p->>'done_on','')::date, (now() at time zone 'America/Los_Angeles')::date) end,
            nullif(left(trim(coalesce(p->>'note','')),300),''), m.name, now())
    on conflict (person_id, step_key) do update set status = excluded.status, done_on = excluded.done_on,
      note = coalesce(excluded.note, growth_steps.note), updated_by = m.name, updated_at = now();
  end if;
  update public.growth_people set updated_by = m.name, updated_at = now() where id = v_pid;
  return true;
end; $fn$;

create or replace function public.growth_support_add(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid; v_kind text := coalesce(nullif(p->>'kind',''),'other');
begin
  m := public.team_need();
  if v_kind not in ('class','advising','referral','job','call','event','other') then raise exception 'Pick what kind of help.'; end if;
  if not exists (select 1 from public.growth_people where id = (p->>'person_id')::uuid and active) then raise exception 'That person is gone. Refresh the page.'; end if;
  if coalesce(trim(p->>'note'),'') = '' then raise exception 'Write a few words about how we helped.'; end if;
  insert into public.growth_support(person_id, kind, note, on_date, created_by)
  values ((p->>'person_id')::uuid, v_kind, left(trim(p->>'note'),500),
          coalesce(nullif(p->>'on_date','')::date, (now() at time zone 'America/Los_Angeles')::date), m.name)
  returning id into v_id;
  update public.growth_people set updated_by = m.name, updated_at = now() where id = (p->>'person_id')::uuid;
  return v_id;
end; $fn$;

create or replace function public.growth_support_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.growth_support where id = p_id and (m.is_admin or created_by = m.name);
  if not found then raise exception 'Only the person who added it, or an admin, can remove it.'; end if;
  return true;
end; $fn$;

-- The list now includes each person's support log (newest first)
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
        'certs', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'label', i.label, 'issued_on', i.issued_on, 'expires_on', i.expires_on, 'number', i.number))
                           from public.cert_items i where g.cert_id is not null and i.contractor_id = g.cert_id), '[]'::jsonb),
        'support', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'note', x.note, 'on_date', x.on_date, 'by', x.created_by)
                           order by x.on_date desc, x.created_at desc) from public.growth_support x where x.person_id = g.id), '[]'::jsonb))
        order by lower(g.name)) from public.growth_people g where g.active), '[]'::jsonb),
    'unlinked_certs', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'company', c.company, 'contact', c.contact, 'trade', c.trade, 'area', c.area,
        'phone', c.phone, 'email', c.email, 'is_member', c.is_member) order by lower(c.company))
        from public.cert_contractors c where c.active and not exists (select 1 from public.growth_people g where g.active and g.cert_id = c.id)), '[]'::jsonb)
  );
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['growth_list(text)','growth_step(text,jsonb)','growth_support_add(text,jsonb)','growth_support_delete(text,uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
