-- team_update_26: Events planner. The Quarterly meeting planner now plans any event.
-- Each event has a type (quarterly meeting, class, community outreach, workshop, celebration or fundraiser,
-- party, other) and a lead. Anyone signed in can create an event and becomes its lead.
-- The lead, Chris and admins can change the event, its roles and its checklist and write the recap.
-- Everyone signed in can still claim day-of roles, take open tasks and check tasks off.
-- A new event copies the roles and checklist of the last event of the same type (due dates moved),
-- or starts from that type's template.

alter table public.qm_events add column if not exists kind text not null default 'quarterly';
alter table public.qm_events add column if not exists lead text;
update public.qm_events set lead = coalesce(lead, 'Chris Hughes') where kind = 'quarterly' and lead is null;
create index if not exists qm_events_kind_idx on public.qm_events(kind, meet_on);

create or replace function public.qm_can_edit(m public.team_member, e public.qm_events) returns boolean
language sql stable set search_path = public as $$
  select coalesce(m.is_admin,false) or m.role_id = 'mem' or m.name = e.lead or m.name = e.created_by;
$$;
revoke all on function public.qm_can_edit(public.team_member, public.qm_events) from public, anon, authenticated;

create or replace function public.qm_need_edit(m public.team_member, p_event uuid) returns public.qm_events
language plpgsql stable set search_path = public as $fn$
declare e public.qm_events;
begin
  select * into e from public.qm_events where id = p_event; if not found then raise exception 'That event was removed.'; end if;
  if not public.qm_can_edit(m, e) then raise exception 'Only the event lead (%), Chris or an admin can change this event.', coalesce(e.lead, e.created_by); end if;
  return e;
end; $fn$;
revoke all on function public.qm_need_edit(public.team_member, uuid) from public, anon, authenticated;

create or replace function public.qm_sync_task(p_id uuid, p_by text) returns void
language plpgsql security definer set search_path = public as $fn$
declare t public.qm_tasks; e public.qm_events; v_tid uuid; v_title text;
begin
  select * into t from public.qm_tasks where id = p_id; if not found then return; end if;
  select * into e from public.qm_events where id = t.event_id;
  v_title := left(coalesce(e.title,'Event') || ': ' || t.title, 200);
  if t.owner is null then
    if t.task_id is not null then delete from public.team_tasks where id = t.task_id and status = 'open'; update public.qm_tasks set task_id = null where id = p_id; end if;
    return;
  end if;
  if t.task_id is not null and exists (select 1 from public.team_tasks where id = t.task_id) then
    update public.team_tasks set title = v_title, owner = t.owner, due_on = t.due_on,
      status = case when t.done then 'done' else 'open' end,
      done_by = case when t.done then coalesce(t.done_by, p_by) else null end,
      done_at = case when t.done then coalesce(t.done_at, now()) else null end
    where id = t.task_id;
  else
    insert into public.team_tasks(title, notes, owner, due_on, status, done_by, done_at, created_by)
    values (v_title, 'From the Events planner (' || to_char(e.meet_on, 'Mon DD') || ').',
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
  return jsonb_build_object('can_manage', true, 'me', m.name,
    'members', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'kind', e.kind, 'lead', coalesce(e.lead, e.created_by),
        'meet_on', e.meet_on, 'start_time', e.start_time, 'end_time', e.end_time, 'place', e.place, 'can_edit', public.qm_can_edit(m, e),
        'spots_total', (select coalesce(sum(greatest(s.need,0)),0) from public.qm_slots s where s.event_id = e.id),
        'spots_open', (select coalesce(sum(greatest(s.need - coalesce(array_length(s.people,1),0),0)),0) from public.qm_slots s where s.event_id = e.id and s.need > 0),
        'my_slots', (select coalesce(jsonb_agg(s.role || coalesce(' (' || s.starts || coalesce(' to ' || s.ends,'') || ')','') order by s.sort), '[]'::jsonb) from public.qm_slots s where s.event_id = e.id and m.name = any(s.people)),
        'tasks_total', (select count(*) from public.qm_tasks t where t.event_id = e.id),
        'tasks_done', (select count(*) from public.qm_tasks t left join public.team_tasks tt on tt.id = t.task_id where t.event_id = e.id and coalesce(tt.status = 'done', t.done)),
        'tasks_open_nobody', (select count(*) from public.qm_tasks t left join public.team_tasks tt on tt.id = t.task_id where t.event_id = e.id and t.owner is null and not coalesce(tt.status = 'done', t.done)),
        'my_open_tasks', (select count(*) from public.qm_tasks t left join public.team_tasks tt on tt.id = t.task_id where t.event_id = e.id and t.owner = m.name and not coalesce(tt.status = 'done', t.done))
      ) order by e.meet_on desc) from public.qm_events e), '[]'::jsonb));
end; $fn$;

create or replace function public.qm_get(tok text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; e public.qm_events; prev public.qm_events;
begin
  m := public.team_need();
  select * into e from public.qm_events where id = p_id; if not found then raise exception 'That event was removed.'; end if;
  select * into prev from public.qm_events where kind = e.kind and meet_on < e.meet_on order by meet_on desc limit 1;
  return jsonb_build_object('can_manage', public.qm_can_edit(m, e), 'me', m.name,
    'event', (to_jsonb(e) - 'deadline_id') || jsonb_build_object('lead', coalesce(e.lead, e.created_by)),
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
        v_kind text := coalesce(nullif(p->>'kind',''), 'quarterly');
        v_title text := coalesce(nullif(left(trim(coalesce(p->>'title','')),120),''), 'Event');
        v_lead text := nullif(trim(coalesce(p->>'lead','')),''); v_dl uuid; x jsonb; r record;
begin
  m := public.team_need();
  if v_kind not in ('quarterly','class','outreach','workshop','celebration','party','other') then v_kind := 'other'; end if;
  if v_lead is not null and not exists (select 1 from public.team_member where name = v_lead and active) then raise exception 'Pick the lead from the team.'; end if;
  begin v_on := (p->>'meet_on')::date; exception when others then v_on := null; end;
  if v_on is null then raise exception 'Pick the event date.'; end if;
  if v_id is null then
    v_lead := coalesce(v_lead, m.name);
    select * into prev from public.qm_events where kind = v_kind order by meet_on desc limit 1;
    insert into public.qm_events(title, kind, lead, meet_on, start_time, end_time, place, wa_url, notes, agenda, slides_url, created_by)
    values (v_title, v_kind, v_lead, v_on, nullif(left(trim(coalesce(p->>'start_time','')),20),''), nullif(left(trim(coalesce(p->>'end_time','')),20),''),
            nullif(left(trim(coalesce(p->>'place','')),200),''), nullif(left(trim(coalesce(p->>'wa_url','')),500),''), nullif(left(trim(coalesce(p->>'notes','')),2000),''),
            nullif(left(trim(coalesce(p->>'agenda','')),4000),''), nullif(left(trim(coalesce(p->>'slides_url','')),500),''), m.name)
    returning id into v_id;
    if prev.id is not null and coalesce((p->>'fresh')::boolean, false) = false then
      insert into public.qm_slots(event_id, role, starts, ends, need, notes, sort)
        select v_id, role, starts, ends, need, notes, sort from public.qm_slots where event_id = prev.id;
      insert into public.qm_tasks(event_id, title, phase, due_on, link, sort)
        select v_id, title, phase, case when due_on is null then null else v_on + (due_on - prev.meet_on) end, link, sort from public.qm_tasks where event_id = prev.id;
    else
      for x in select * from jsonb_array_elements(coalesce(p->'template_slots','[]'::jsonb)) loop
        insert into public.qm_slots(event_id, role, starts, ends, need, sort)
        values (v_id, left(x->>'role',80), x->>'starts', x->>'ends', least(greatest(coalesce((x->>'need')::int,1),0),30), coalesce((x->>'sort')::int,0));
      end loop;
      for x in select * from jsonb_array_elements(coalesce(p->'template_tasks','[]'::jsonb)) loop
        insert into public.qm_tasks(event_id, title, phase, due_on, link, sort)
        values (v_id, left(x->>'title',200), x->>'phase', v_on + coalesce((x->>'offset')::int,0), nullif(x->>'link',''), coalesce((x->>'sort')::int,0));
      end loop;
    end if;
    insert into public.team_deadlines(title, due_on, kind, owner, notes, created_by)
    values (v_title, v_on, 'event', v_lead, 'From the Events planner.', m.name) returning id into v_dl;
    update public.qm_events set deadline_id = v_dl where id = v_id;
  else
    old := public.qm_need_edit(m, v_id);
    update public.qm_events set title = v_title, kind = v_kind, lead = coalesce(v_lead, old.lead, old.created_by), meet_on = v_on,
      start_time = nullif(left(trim(coalesce(p->>'start_time','')),20),''), end_time = nullif(left(trim(coalesce(p->>'end_time','')),20),''),
      place = nullif(left(trim(coalesce(p->>'place','')),200),''), wa_url = nullif(left(trim(coalesce(p->>'wa_url','')),500),''),
      notes = nullif(left(trim(coalesce(p->>'notes','')),2000),''),
      agenda = case when p ? 'agenda' then nullif(left(trim(coalesce(p->>'agenda','')),4000),'') else agenda end,
      slides_url = case when p ? 'slides_url' then nullif(left(trim(coalesce(p->>'slides_url','')),500),'') else slides_url end,
      updated_by = m.name, updated_at = now()
    where id = v_id;
    if v_on <> old.meet_on then
      update public.qm_tasks set due_on = due_on + (v_on - old.meet_on) where event_id = v_id and due_on is not null;
    end if;
    for r in select id from public.qm_tasks where event_id = v_id and task_id is not null loop perform public.qm_sync_task(r.id, m.name); end loop;
    if old.deadline_id is not null then
      update public.team_deadlines set title = v_title, due_on = v_on, owner = coalesce(v_lead, old.lead, owner), updated_by = m.name, updated_at = now() where id = old.deadline_id;
    end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.qm_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; e public.qm_events;
begin
  m := public.team_need();
  if not exists (select 1 from public.qm_events where id = p_id) then return true; end if;
  e := public.qm_need_edit(m, p_id);
  delete from public.team_tasks where status = 'open' and id in (select task_id from public.qm_tasks where event_id = p_id and task_id is not null);
  if e.deadline_id is not null then delete from public.team_deadlines where id = e.deadline_id; end if;
  delete from public.qm_events where id = p_id;
  return true;
end; $fn$;

create or replace function public.qm_slot_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_role text := left(trim(coalesce(p->>'role','')),80); v_ev uuid; e public.qm_events;
begin
  m := public.team_need();
  if v_id is null then v_ev := (p->>'event_id')::uuid; else select event_id into v_ev from public.qm_slots where id = v_id; end if;
  e := public.qm_need_edit(m, v_ev);
  if v_role = '' then raise exception 'Name the role, like Greeting station.'; end if;
  if v_id is null then
    insert into public.qm_slots(event_id, role, starts, ends, need, notes, sort)
    values (v_ev, v_role, nullif(left(trim(coalesce(p->>'starts','')),20),''), nullif(left(trim(coalesce(p->>'ends','')),20),''),
            least(greatest(coalesce(nullif(p->>'need','')::int,1),0),30), nullif(left(trim(coalesce(p->>'notes','')),300),''),
            coalesce((select max(sort)+1 from public.qm_slots where event_id = v_ev),0))
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
declare m public.team_member; v_ev uuid; e public.qm_events;
begin
  m := public.team_need();
  select event_id into v_ev from public.qm_slots where id = p_id; if v_ev is null then return true; end if;
  e := public.qm_need_edit(m, v_ev);
  delete from public.qm_slots where id = p_id; return true;
end; $fn$;

create or replace function public.qm_task_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; mg boolean; t public.qm_tasks; e public.qm_events; v_owner text := nullif(trim(coalesce(p->>'owner','')),'');
        v_title text := left(trim(coalesce(p->>'title','')),200); v_due date;
begin
  m := public.team_need();
  if v_owner is not null and not exists (select 1 from public.team_member where name = v_owner and active) then raise exception 'Pick someone from the team.'; end if;
  if v_id is null then
    e := public.qm_need_edit(m, (p->>'event_id')::uuid);
    if v_title = '' then raise exception 'Write the task.'; end if;
    begin v_due := nullif(p->>'due_on','')::date; exception when others then v_due := null; end;
    insert into public.qm_tasks(event_id, title, phase, due_on, owner, link, sort)
    values (e.id, v_title, nullif(p->>'phase',''), v_due, v_owner, nullif(p->>'link',''),
            coalesce((select max(sort)+1 from public.qm_tasks where event_id = e.id),0))
    returning id into v_id;
  else
    select * into t from public.qm_tasks where id = v_id; if not found then raise exception 'That task was removed.'; end if;
    select * into e from public.qm_events where id = t.event_id; mg := public.qm_can_edit(m, e);
    if mg then
      if v_title = '' then v_title := t.title; end if;
      begin v_due := case when p ? 'due_on' then nullif(p->>'due_on','')::date else t.due_on end; exception when others then v_due := t.due_on; end;
      update public.qm_tasks set title = v_title, due_on = v_due, owner = case when p ? 'owner' then v_owner else owner end,
        link = case when p ? 'link' then nullif(p->>'link','') else link end where id = v_id;
    else
      if v_owner = m.name and t.owner is null then update public.qm_tasks set owner = m.name where id = v_id;
      elsif v_owner is null and t.owner = m.name then update public.qm_tasks set owner = null where id = v_id;
      else raise exception 'Only the event lead, Chris or an admin can assign this task to someone else.'; end if;
    end if;
  end if;
  perform public.qm_sync_task(v_id, m.name);
  return v_id;
end; $fn$;

create or replace function public.qm_task_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_ev uuid; e public.qm_events;
begin
  m := public.team_need();
  select event_id into v_ev from public.qm_tasks where id = p_id; if v_ev is null then return true; end if;
  e := public.qm_need_edit(m, v_ev);
  delete from public.team_tasks where status = 'open' and id = (select task_id from public.qm_tasks where id = p_id);
  delete from public.qm_tasks where id = p_id; return true;
end; $fn$;

create or replace function public.qm_recap_save(tok text, p_id uuid, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; r jsonb := '{}'::jsonb; k text; e public.qm_events;
begin
  m := public.team_need();
  e := public.qm_need_edit(m, p_id);
  foreach k in array array['attendance','new_members','leads'] loop
    if coalesce(p->>k,'') ~ '^\d{1,5}$' then r := r || jsonb_build_object(k, (p->>k)::int); end if;
  end loop;
  foreach k in array array['raffle','went_well','change_next','notes'] loop
    if nullif(trim(coalesce(p->>k,'')),'') is not null then r := r || jsonb_build_object(k, left(trim(p->>k), 2000)); end if;
  end loop;
  update public.qm_events set recap = r || jsonb_build_object('by', m.name, 'at', now()), updated_by = m.name, updated_at = now() where id = p_id;
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
