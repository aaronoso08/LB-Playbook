-- team_update_25: Quarterly meeting agenda and slides link, and "Need a hand" help requests.
-- Applied in Supabase on 2026-10-30.
-- 1) Quarterly meetings get an agenda (one item per line) and a link to the slides. Chris and admins edit them.
-- 2) Need a hand: anyone signed in can ask the team for help with something (what, by when) and teammates
--    tap "I can help". The person who asked (or an admin) marks it done or removes it.

alter table public.qm_events add column if not exists agenda text;
alter table public.qm_events add column if not exists slides_url text;

create or replace function public.qm_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_on date; old public.qm_events; prev public.qm_events;
        v_title text := coalesce(nullif(left(trim(coalesce(p->>'title','')),120),''), 'Quarterly member meeting'); v_dl uuid; x jsonb; r record;
begin
  m := public.team_need();
  if not public.qm_can_manage(m) then raise exception 'Only Chris or an admin can set up quarterly meetings.'; end if;
  begin v_on := (p->>'meet_on')::date; exception when others then v_on := null; end;
  if v_on is null then raise exception 'Pick the meeting date.'; end if;
  if v_id is null then
    select * into prev from public.qm_events order by meet_on desc limit 1;
    insert into public.qm_events(title, meet_on, start_time, end_time, place, wa_url, notes, agenda, slides_url, created_by)
    values (v_title, v_on, nullif(left(trim(coalesce(p->>'start_time','')),20),''), nullif(left(trim(coalesce(p->>'end_time','')),20),''),
            nullif(left(trim(coalesce(p->>'place','')),200),''), nullif(left(trim(coalesce(p->>'wa_url','')),500),''), nullif(left(trim(coalesce(p->>'notes','')),2000),''),
            nullif(left(trim(coalesce(p->>'agenda','')),4000),''), nullif(left(trim(coalesce(p->>'slides_url','')),500),''), m.name)
    returning id into v_id;
    if prev.id is not null then
      insert into public.qm_slots(event_id, role, starts, ends, need, notes, sort)
        select v_id, role, starts, ends, need, notes, sort from public.qm_slots where event_id = prev.id;
      insert into public.qm_tasks(event_id, title, phase, due_on, link, sort)
        select v_id, title, phase, case when due_on is null then null else v_on + (due_on - prev.meet_on) end, link, sort from public.qm_tasks where event_id = prev.id;
    else
      for x in select * from jsonb_array_elements(coalesce(p->'template_slots','[]'::jsonb)) loop
        insert into public.qm_slots(event_id, role, starts, ends, need, sort)
        values (v_id, left(x->>'role',80), x->>'starts', x->>'ends', coalesce((x->>'need')::int,1), coalesce((x->>'sort')::int,0));
      end loop;
      for x in select * from jsonb_array_elements(coalesce(p->'template_tasks','[]'::jsonb)) loop
        insert into public.qm_tasks(event_id, title, phase, due_on, link, sort)
        values (v_id, left(x->>'title',200), x->>'phase', v_on + coalesce((x->>'offset')::int,0), nullif(x->>'link',''), coalesce((x->>'sort')::int,0));
      end loop;
    end if;
    insert into public.team_deadlines(title, due_on, kind, owner, notes, created_by)
    values (v_title, v_on, 'event', 'Chris Hughes', 'From the Quarterly meeting planner.', m.name) returning id into v_dl;
    update public.qm_events set deadline_id = v_dl where id = v_id;
  else
    select * into old from public.qm_events where id = v_id; if not found then raise exception 'That meeting was removed.'; end if;
    update public.qm_events set title = v_title, meet_on = v_on,
      start_time = nullif(left(trim(coalesce(p->>'start_time','')),20),''), end_time = nullif(left(trim(coalesce(p->>'end_time','')),20),''),
      place = nullif(left(trim(coalesce(p->>'place','')),200),''), wa_url = nullif(left(trim(coalesce(p->>'wa_url','')),500),''),
      notes = nullif(left(trim(coalesce(p->>'notes','')),2000),''),
      agenda = case when p ? 'agenda' then nullif(left(trim(coalesce(p->>'agenda','')),4000),'') else agenda end,
      slides_url = case when p ? 'slides_url' then nullif(left(trim(coalesce(p->>'slides_url','')),500),'') else slides_url end,
      updated_by = m.name, updated_at = now()
    where id = v_id;
    if v_on <> old.meet_on then
      update public.qm_tasks set due_on = due_on + (v_on - old.meet_on) where event_id = v_id and due_on is not null;
      for r in select id from public.qm_tasks where event_id = v_id and task_id is not null loop perform public.qm_sync_task(r.id, m.name); end loop;
    end if;
    if old.deadline_id is not null then update public.team_deadlines set title = v_title, due_on = v_on, updated_by = m.name, updated_at = now() where id = old.deadline_id; end if;
  end if;
  return v_id;
end; $fn$;

create table if not exists public.team_help (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  details text,
  needed_on date,
  helpers text[] not null default '{}',
  status text not null default 'open' check (status in ('open','done')),
  created_by text not null,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
alter table public.team_help enable row level security;
revoke all on public.team_help from anon, authenticated;

create or replace function public.help_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object('me', m.name, 'is_admin', m.is_admin,
    'items', coalesce((select jsonb_agg(to_jsonb(h) order by (h.status = 'done'), h.needed_on nulls last, h.created_at desc)
      from public.team_help h where h.status = 'open' or h.done_at > now() - interval '7 days'), '[]'::jsonb));
end; $fn$;

create or replace function public.help_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid; v_on date; v_t text := left(trim(coalesce(p->>'title','')),160);
begin
  m := public.team_need();
  if v_t = '' then raise exception 'Say what you need help with.'; end if;
  begin v_on := nullif(p->>'needed_on','')::date; exception when others then v_on := null; end;
  insert into public.team_help(title, details, needed_on, created_by)
  values (v_t, nullif(left(trim(coalesce(p->>'details','')),1000),''), v_on, m.name) returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.help_offer(tok text, p_id uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  update public.team_help set helpers = case when p_on then (case when m.name = any(helpers) then helpers else array_append(helpers, m.name) end)
                                             else array_remove(helpers, m.name) end
   where id = p_id;
  if not found then raise exception 'That request was removed.'; end if;
  return true;
end; $fn$;

create or replace function public.help_close(tok text, p_id uuid, p_delete boolean) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if p_delete then
    delete from public.team_help where id = p_id and (created_by = m.name or m.is_admin);
  else
    update public.team_help set status = 'done', done_at = now() where id = p_id and (created_by = m.name or m.is_admin);
  end if;
  if not found then raise exception 'Only the person who asked, or an admin, can close this.'; end if;
  return true;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['qm_save(text,jsonb)','help_list(text)','help_save(text,jsonb)','help_offer(text,uuid,boolean)','help_close(text,uuid,boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
