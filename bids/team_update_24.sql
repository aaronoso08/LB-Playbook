-- team_update_24: Quarterly meeting planner. Applied in Supabase on 2026-10-30.
-- Each quarterly member meeting gets: day-of role slots staff can claim (instead of reply-all email),
-- a planning checklist with owners and due dates (assigned tasks also show on Team to-do), and a recap.
-- A new meeting copies last quarter's slots and checklist, with due dates moved to the new date.
-- Chris (Membership & Community Engagement Manager) and admins set up meetings, slots and tasks and
-- write the recap. Everyone signed in can claim slots, take open tasks and check tasks off.

create table if not exists public.qm_events (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Quarterly member meeting',
  meet_on date not null,
  start_time text, end_time text, place text, wa_url text, notes text,
  recap jsonb not null default '{}'::jsonb,
  deadline_id uuid,
  created_by text not null, created_at timestamptz not null default now(),
  updated_by text, updated_at timestamptz
);
create table if not exists public.qm_slots (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.qm_events(id) on delete cascade,
  role text not null, starts text, ends text,
  need int not null default 1 check (need between 0 and 30),
  people text[] not null default '{}', notes text, sort int not null default 0
);
create table if not exists public.qm_tasks (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.qm_events(id) on delete cascade,
  title text not null, phase text, due_on date, owner text, link text,
  done boolean not null default false, done_by text, done_at timestamptz,
  task_id uuid, sort int not null default 0
);
create index if not exists qm_slots_event_idx on public.qm_slots(event_id, sort);
create index if not exists qm_tasks_event_idx on public.qm_tasks(event_id, due_on);
alter table public.qm_events enable row level security; revoke all on public.qm_events from anon, authenticated;
alter table public.qm_slots enable row level security;  revoke all on public.qm_slots from anon, authenticated;
alter table public.qm_tasks enable row level security;  revoke all on public.qm_tasks from anon, authenticated;

create or replace function public.qm_can_manage(m public.team_member) returns boolean
language sql stable set search_path = public as $$ select coalesce(m.is_admin,false) or m.role_id = 'mem'; $$;
revoke all on function public.qm_can_manage(public.team_member) from public, anon, authenticated;

-- Keep a Team to-do task in step with a checklist task that has an owner
create or replace function public.qm_sync_task(p_id uuid, p_by text) returns void
language plpgsql security definer set search_path = public as $fn$
declare t public.qm_tasks; e public.qm_events; v_tid uuid;
begin
  select * into t from public.qm_tasks where id = p_id; if not found then return; end if;
  select * into e from public.qm_events where id = t.event_id;
  if t.owner is null then
    if t.task_id is not null then delete from public.team_tasks where id = t.task_id and status = 'open'; update public.qm_tasks set task_id = null where id = p_id; end if;
    return;
  end if;
  if t.task_id is not null and exists (select 1 from public.team_tasks where id = t.task_id) then
    update public.team_tasks set title = left('Quarterly meeting: ' || t.title, 200), owner = t.owner, due_on = t.due_on,
      status = case when t.done then 'done' else 'open' end,
      done_by = case when t.done then coalesce(t.done_by, p_by) else null end,
      done_at = case when t.done then coalesce(t.done_at, now()) else null end
    where id = t.task_id;
  else
    insert into public.team_tasks(title, notes, owner, due_on, status, done_by, done_at, created_by)
    values (left('Quarterly meeting: ' || t.title, 200), 'From the Quarterly meeting planner (' || to_char(e.meet_on, 'Mon DD') || ').',
            t.owner, t.due_on, case when t.done then 'done' else 'open' end, case when t.done then coalesce(t.done_by, p_by) end,
            case when t.done then coalesce(t.done_at, now()) end, p_by)
    returning id into v_tid;
    update public.qm_tasks set task_id = v_tid where id = p_id;
  end if;
end; $fn$;
revoke all on function public.qm_sync_task(uuid, text) from public, anon, authenticated;

create or replace function public.qm_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object('can_manage', public.qm_can_manage(m), 'me', m.name,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'meet_on', e.meet_on, 'start_time', e.start_time, 'end_time', e.end_time, 'place', e.place,
        'spots_total', (select coalesce(sum(greatest(s.need,0)),0) from public.qm_slots s where s.event_id = e.id),
        'spots_open', (select coalesce(sum(greatest(s.need - coalesce(array_length(s.people,1),0),0)),0) from public.qm_slots s where s.event_id = e.id and s.need > 0),
        'my_slots', (select coalesce(jsonb_agg(s.role || coalesce(' (' || s.starts || coalesce(' to ' || s.ends,'') || ')','') order by s.sort), '[]'::jsonb) from public.qm_slots s where s.event_id = e.id and m.name = any(s.people)),
        'tasks_total', (select count(*) from public.qm_tasks t where t.event_id = e.id),
        'tasks_done', (select count(*) from public.qm_tasks t left join public.team_tasks tt on tt.id = t.task_id where t.event_id = e.id and coalesce(tt.status = 'done', t.done)),
        'my_open_tasks', (select count(*) from public.qm_tasks t left join public.team_tasks tt on tt.id = t.task_id where t.event_id = e.id and t.owner = m.name and not coalesce(tt.status = 'done', t.done))
      ) order by e.meet_on desc) from public.qm_events e), '[]'::jsonb));
end; $fn$;

create or replace function public.qm_get(tok text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; e public.qm_events; prev public.qm_events;
begin
  m := public.team_need();
  select * into e from public.qm_events where id = p_id; if not found then raise exception 'That meeting was removed.'; end if;
  select * into prev from public.qm_events where meet_on < e.meet_on order by meet_on desc limit 1;
  return jsonb_build_object('can_manage', public.qm_can_manage(m), 'me', m.name,
    'event', to_jsonb(e) - 'deadline_id',
    'prev', case when prev.id is null then null else jsonb_build_object('title', prev.title, 'meet_on', prev.meet_on, 'change_next', prev.recap->>'change_next') end,
    'members', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'slots', coalesce((select jsonb_agg(to_jsonb(s) - 'event_id' order by s.sort, s.starts) from public.qm_slots s where s.event_id = e.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'phase', t.phase, 'due_on', t.due_on, 'owner', t.owner, 'link', t.link,
        'done', coalesce(tt.status = 'done', t.done), 'done_by', coalesce(tt.done_by, t.done_by)) order by t.due_on nulls last, t.sort)
      from public.qm_tasks t left join public.team_tasks tt on tt.id = t.task_id where t.event_id = e.id), '[]'::jsonb));
end; $fn$;

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
    insert into public.qm_events(title, meet_on, start_time, end_time, place, wa_url, notes, created_by)
    values (v_title, v_on, nullif(left(trim(coalesce(p->>'start_time','')),20),''), nullif(left(trim(coalesce(p->>'end_time','')),20),''),
            nullif(left(trim(coalesce(p->>'place','')),200),''), nullif(left(trim(coalesce(p->>'wa_url','')),500),''), nullif(left(trim(coalesce(p->>'notes','')),2000),''), m.name)
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
      notes = nullif(left(trim(coalesce(p->>'notes','')),2000),''), updated_by = m.name, updated_at = now()
    where id = v_id;
    if v_on <> old.meet_on then
      update public.qm_tasks set due_on = due_on + (v_on - old.meet_on) where event_id = v_id and due_on is not null;
      for r in select id from public.qm_tasks where event_id = v_id and task_id is not null loop perform public.qm_sync_task(r.id, m.name); end loop;
    end if;
    if old.deadline_id is not null then update public.team_deadlines set title = v_title, due_on = v_on, updated_by = m.name, updated_at = now() where id = old.deadline_id; end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.qm_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; e public.qm_events;
begin
  m := public.team_need();
  if not public.qm_can_manage(m) then raise exception 'Only Chris or an admin can remove a meeting.'; end if;
  select * into e from public.qm_events where id = p_id; if not found then return true; end if;
  delete from public.team_tasks where status = 'open' and id in (select task_id from public.qm_tasks where event_id = p_id and task_id is not null);
  if e.deadline_id is not null then delete from public.team_deadlines where id = e.deadline_id; end if;
  delete from public.qm_events where id = p_id;
  return true;
end; $fn$;

create or replace function public.qm_slot_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_role text := left(trim(coalesce(p->>'role','')),80);
begin
  m := public.team_need();
  if not public.qm_can_manage(m) then raise exception 'Only Chris or an admin can change the roles.'; end if;
  if v_role = '' then raise exception 'Name the role, like Greeting station.'; end if;
  if v_id is null then
    insert into public.qm_slots(event_id, role, starts, ends, need, notes, sort)
    values ((p->>'event_id')::uuid, v_role, nullif(left(trim(coalesce(p->>'starts','')),20),''), nullif(left(trim(coalesce(p->>'ends','')),20),''),
            least(greatest(coalesce(nullif(p->>'need','')::int,1),0),30), nullif(left(trim(coalesce(p->>'notes','')),300),''),
            coalesce((select max(sort)+1 from public.qm_slots where event_id = (p->>'event_id')::uuid),0))
    returning id into v_id;
  else
    update public.qm_slots set role = v_role, starts = nullif(left(trim(coalesce(p->>'starts','')),20),''), ends = nullif(left(trim(coalesce(p->>'ends','')),20),''),
      need = least(greatest(coalesce(nullif(p->>'need','')::int,1),0),30), notes = nullif(left(trim(coalesce(p->>'notes','')),300),'')
    where id = v_id;
  end if;
  return v_id;
end; $fn$;

create or replace function public.qm_slot_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not public.qm_can_manage(m) then raise exception 'Only Chris or an admin can change the roles.'; end if;
  delete from public.qm_slots where id = p_id; return true;
end; $fn$;

create or replace function public.qm_slot_claim(tok text, p_id uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; s public.qm_slots;
begin
  m := public.team_need();
  select * into s from public.qm_slots where id = p_id for update; if not found then raise exception 'That role was removed.'; end if;
  if p_on then
    if m.name = any(s.people) then return true; end if;
    if s.need > 0 and coalesce(array_length(s.people,1),0) >= s.need then raise exception 'That spot is already full. Pick another one.'; end if;
    update public.qm_slots set people = array_append(people, m.name) where id = p_id;
  else
    update public.qm_slots set people = array_remove(people, m.name) where id = p_id;
  end if;
  return true;
end; $fn$;

create or replace function public.qm_task_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; mg boolean; t public.qm_tasks; v_owner text := nullif(trim(coalesce(p->>'owner','')),'');
        v_title text := left(trim(coalesce(p->>'title','')),200); v_due date;
begin
  m := public.team_need(); mg := public.qm_can_manage(m);
  if v_owner is not null and not exists (select 1 from public.team_member where name = v_owner and active) then raise exception 'Pick someone from the team.'; end if;
  if v_id is null then
    if not mg then raise exception 'Only Chris or an admin can add tasks.'; end if;
    if v_title = '' then raise exception 'Write the task.'; end if;
    begin v_due := nullif(p->>'due_on','')::date; exception when others then v_due := null; end;
    insert into public.qm_tasks(event_id, title, phase, due_on, owner, link, sort)
    values ((p->>'event_id')::uuid, v_title, nullif(p->>'phase',''), v_due, v_owner, nullif(p->>'link',''),
            coalesce((select max(sort)+1 from public.qm_tasks where event_id = (p->>'event_id')::uuid),0))
    returning id into v_id;
  else
    select * into t from public.qm_tasks where id = v_id; if not found then raise exception 'That task was removed.'; end if;
    if mg then
      if v_title = '' then v_title := t.title; end if;
      begin v_due := case when p ? 'due_on' then nullif(p->>'due_on','')::date else t.due_on end; exception when others then v_due := t.due_on; end;
      update public.qm_tasks set title = v_title, due_on = v_due, owner = case when p ? 'owner' then v_owner else owner end,
        link = case when p ? 'link' then nullif(p->>'link','') else link end where id = v_id;
    else
      -- teammates can take an open task, or hand back their own
      if v_owner = m.name and t.owner is null then update public.qm_tasks set owner = m.name where id = v_id;
      elsif v_owner is null and t.owner = m.name then update public.qm_tasks set owner = null where id = v_id;
      else raise exception 'Only Chris or an admin can assign this task to someone else.'; end if;
    end if;
  end if;
  perform public.qm_sync_task(v_id, m.name);
  return v_id;
end; $fn$;

create or replace function public.qm_task_done(tok text, p_id uuid, p_done boolean) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  update public.qm_tasks set done = p_done, done_by = case when p_done then m.name end, done_at = case when p_done then now() end,
    owner = case when p_done then coalesce(owner, m.name) else owner end where id = p_id;
  if not found then raise exception 'That task was removed.'; end if;
  perform public.qm_sync_task(p_id, m.name);
  return true;
end; $fn$;

create or replace function public.qm_task_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not public.qm_can_manage(m) then raise exception 'Only Chris or an admin can remove tasks.'; end if;
  delete from public.team_tasks where status = 'open' and id = (select task_id from public.qm_tasks where id = p_id);
  delete from public.qm_tasks where id = p_id; return true;
end; $fn$;

create or replace function public.qm_recap_save(tok text, p_id uuid, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; r jsonb := '{}'::jsonb; k text;
begin
  m := public.team_need();
  if not public.qm_can_manage(m) then raise exception 'Only Chris or an admin can write the recap.'; end if;
  foreach k in array array['attendance','new_members','leads'] loop
    if coalesce(p->>k,'') ~ '^\d{1,5}$' then r := r || jsonb_build_object(k, (p->>k)::int); end if;
  end loop;
  foreach k in array array['raffle','went_well','change_next','notes'] loop
    if nullif(trim(coalesce(p->>k,'')),'') is not null then r := r || jsonb_build_object(k, left(trim(p->>k), 2000)); end if;
  end loop;
  update public.qm_events set recap = r || jsonb_build_object('by', m.name, 'at', now()), updated_by = m.name, updated_at = now() where id = p_id;
  if not found then raise exception 'That meeting was removed.'; end if;
  return true;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['qm_list(text)','qm_get(text,uuid)','qm_save(text,jsonb)','qm_delete(text,uuid)','qm_slot_save(text,jsonb)',
    'qm_slot_delete(text,uuid)','qm_slot_claim(text,uuid,boolean)','qm_task_save(text,jsonb)','qm_task_done(text,uuid,boolean)',
    'qm_task_delete(text,uuid)','qm_recap_save(text,uuid,jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
