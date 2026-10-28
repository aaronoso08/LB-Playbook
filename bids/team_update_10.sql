-- =====================================================================
-- Latino Built Team Playbook: update 10 (better meeting notes). Safe to run again.
-- Run AFTER team_update_9.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- 1) Note taker: each meeting has a named note taker. An optional weekly rotation
--    picks the next person for Monday staff meetings automatically.
-- 2) Any kind of meeting, not just Monday staff: Board, partner (Earth Advantage, PCEF...),
--    program, member/quarterly, other. More than one meeting per day is fine.
-- 3) Notes in sections: program updates (HHGP, Nuestro Hogar, HOMES/HEAR, CPF),
--    events and classes, contractors, office/admin, other, plus general notes.
-- 4) Archive with search and tags, so old meetings are easy to find.
-- Existing meeting notes and action items are kept and moved over automatically.
-- =====================================================================

-- ---------- Table changes (keeps everything already saved) ----------
alter table public.team_meetings add column if not exists id uuid default gen_random_uuid();
update public.team_meetings set id = gen_random_uuid() where id is null;
alter table public.team_meetings alter column id set not null;
alter table public.team_meetings add column if not exists kind       text not null default 'staff';
alter table public.team_meetings add column if not exists note_taker text;
alter table public.team_meetings add column if not exists sections   jsonb not null default '{}'::jsonb;
alter table public.team_meetings add column if not exists tags       text[] not null default '{}';
alter table public.team_meetings add column if not exists created_by text;
alter table public.team_meetings add column if not exists created_at timestamptz not null default now();

do $do$
begin
  -- the old key was the date (one meeting per day); now each meeting has its own id
  if exists (select 1 from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
             where c.conrelid = 'public.team_meetings'::regclass and c.contype = 'p' and a.attname = 'meet_on') then
    execute (select format('alter table public.team_meetings drop constraint %I', conname)
             from pg_constraint where conrelid = 'public.team_meetings'::regclass and contype = 'p');
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.team_meetings'::regclass and contype = 'p') then
    alter table public.team_meetings add primary key (id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'team_meetings_kind_ok') then
    alter table public.team_meetings add constraint team_meetings_kind_ok
      check (kind in ('staff','board','partner','program','member','other'));
  end if;
end $do$;
alter table public.team_meetings alter column meet_on set not null;
create index if not exists team_meetings_on_idx on public.team_meetings(meet_on desc);

-- Action items now point at a meeting by id (the old date link is filled in for past items)
alter table public.team_tasks add column if not exists meeting_id uuid;
update public.team_tasks t set meeting_id = m.id
  from public.team_meetings m
 where t.meeting_id is null and t.meeting_on is not null and m.meet_on = t.meeting_on and m.kind = 'staff';

-- Small settings table (note taker rotation lives here)
create table if not exists public.team_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.team_settings enable row level security;
revoke all on public.team_settings from anon, authenticated;

-- ---------- Helpers ----------
-- Next Monday staff meeting (today if it's Monday), Pacific time
create or replace function public.team_next_monday() returns date
language sql stable as $fn$
  select d + ((8 - extract(isodow from d)::int) % 7)
  from (select (now() at time zone 'America/Los_Angeles')::date d) x;
$fn$;

-- Who the rotation says should take notes at the staff meeting on a given date (null if rotation is off)
create or replace function public.team_rotation_pick(p_on date) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare r jsonb; ppl text[]; start date; n int; k int;
begin
  select value into r from public.team_settings where key = 'note_rotation';
  if r is null or not coalesce((r->>'on')::boolean, false) then return null; end if;
  select array_agg(x order by i) into ppl from jsonb_array_elements_text(coalesce(r->'people','[]'::jsonb)) with ordinality e(x, i)
   where exists (select 1 from public.team_member m where m.active and m.name = e.x);
  n := coalesce(array_length(ppl,1),0);
  if n = 0 then return null; end if;
  start := coalesce(nullif(r->>'start','')::date, p_on);
  k := (((p_on - start) / 7) % n + n) % n;
  return ppl[k + 1];
end; $fn$;

-- ---------- Archive: list, search and filter ----------
create or replace function public.team_meeting_list(tok text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; q text := lower(trim(coalesce(p->>'q',''))); v_kind text := nullif(p->>'kind','');
        v_tag text := lower(nullif(trim(coalesce(p->>'tag','')),'')); nxt date := public.team_next_monday();
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'rotation', coalesce((select value from public.team_settings where key = 'note_rotation'), '{}'::jsonb),
    'next', jsonb_build_object('meet_on', nxt,
       'id', (select id from public.team_meetings where kind = 'staff' and meet_on = nxt order by created_at limit 1),
       'note_taker', coalesce((select note_taker from public.team_meetings where kind = 'staff' and meet_on = nxt
                               and note_taker is not null order by created_at limit 1), public.team_rotation_pick(nxt))),
    'tags', coalesce((select jsonb_agg(t order by t) from (select distinct unnest(tags) t from public.team_meetings) s), '[]'::jsonb),
    'meetings', coalesce((select jsonb_agg(r order by (r->>'meet_on') desc, (r->>'created_at') desc) from (
       select jsonb_build_object('id', x.id, 'meet_on', x.meet_on, 'title', x.title, 'kind', x.kind,
                'note_taker', x.note_taker, 'tags', to_jsonb(x.tags), 'created_at', x.created_at,
                'open', (select count(*) from public.team_tasks t where t.meeting_id = x.id and t.status = 'open'),
                'actions', (select count(*) from public.team_tasks t where t.meeting_id = x.id),
                'snip', case when q = '' then null else (
                   select substr(txt, greatest(1, strpos(lower(txt), q) - 70), 200)
                   from (select concat_ws(' · ', x.title, x.agenda, x.notes, x.decisions,
                          (select string_agg(value, ' · ') from jsonb_each_text(x.sections)),
                          (select string_agg(t.title, ' · ') from public.team_tasks t where t.meeting_id = x.id)) txt) z
                   where strpos(lower(txt), q) > 0) end) r
       from public.team_meetings x
       where (v_kind is null or x.kind = v_kind)
         and (v_tag is null or v_tag = any(x.tags))
         and (q = '' or strpos(lower(concat_ws(' ', x.title, x.agenda, x.notes, x.decisions, x.note_taker,
                array_to_string(x.tags,' '), x.sections::text,
                (select string_agg(t.title, ' ') from public.team_tasks t where t.meeting_id = x.id))), q) > 0)
       order by x.meet_on desc, x.created_at desc
       limit 300) s), '[]'::jsonb)
  );
end; $fn$;

-- ---------- One meeting with its action items and last meeting's open items ----------
create or replace function public.team_meeting_get(tok text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; x public.team_meetings; prev uuid;
begin
  m := public.team_need();
  select * into x from public.team_meetings where id = p_id;
  if x.id is null then raise exception 'That meeting is gone. Refresh the page.'; end if;
  select id into prev from public.team_meetings
   where kind = x.kind and id <> x.id and (meet_on < x.meet_on or (meet_on = x.meet_on and created_at < x.created_at))
     and (x.kind <> 'other' or lower(title) = lower(x.title))
   order by meet_on desc, created_at desc limit 1;
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'meeting', to_jsonb(x),
    'suggest_taker', case when x.kind = 'staff' then public.team_rotation_pick(x.meet_on) end,
    'actions', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.team_tasks t where t.meeting_id = x.id), '[]'::jsonb),
    'prev', (select jsonb_build_object('id', id, 'meet_on', meet_on, 'title', title) from public.team_meetings where id = prev),
    'carry', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.team_tasks t
                       where prev is not null and t.meeting_id = prev and t.status = 'open'), '[]'::jsonb)
  );
end; $fn$;

-- ---------- Start a meeting (or open the one that already exists for that day and type) ----------
create or replace function public.team_meeting_start(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_on date := nullif(p->>'meet_on','')::date; v_kind text := coalesce(nullif(p->>'kind',''),'staff');
        v_title text := nullif(left(trim(coalesce(p->>'title','')),120),''); v_id uuid;
begin
  m := public.team_need();
  if v_on is null then raise exception 'Pick a meeting date.'; end if;
  if v_kind not in ('staff','board','partner','program','member','other') then raise exception 'Pick a meeting type.'; end if;
  if v_kind = 'staff' then
    select id into v_id from public.team_meetings where kind = 'staff' and meet_on = v_on order by created_at limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  insert into public.team_meetings(meet_on, kind, title, note_taker, created_by, updated_by)
  values (v_on, v_kind,
          coalesce(v_title, case v_kind when 'staff' then 'Staff meeting' when 'board' then 'Board meeting'
                                       when 'partner' then 'Partner meeting' when 'program' then 'Program meeting'
                                       when 'member' then 'Member meeting' else 'Meeting' end),
          case when v_kind = 'staff' then public.team_rotation_pick(v_on) end, m.name, m.name)
  returning id into v_id;
  return v_id;
end; $fn$;

-- ---------- Save (last save wins; the page shows who saved last) ----------
create or replace function public.team_meeting_save2(tok text, p jsonb) returns timestamptz
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_at timestamptz := now();
        v_taker text := nullif(trim(coalesce(p->>'note_taker','')),''); v_kind text := coalesce(nullif(p->>'kind',''),'staff');
        v_tags text[];
begin
  m := public.team_need();
  if v_id is null then raise exception 'Open a meeting first.'; end if;
  if nullif(p->>'meet_on','') is null then raise exception 'Pick a meeting date.'; end if;
  if v_kind not in ('staff','board','partner','program','member','other') then raise exception 'Pick a meeting type.'; end if;
  if v_taker is not null and not exists (select 1 from public.team_member where active and name = v_taker) then
    raise exception 'That person is not on the team list.'; end if;
  select coalesce(array_agg(distinct t), '{}') into v_tags from (
    select left(lower(trim(x)),40) t from jsonb_array_elements_text(case when jsonb_typeof(p->'tags')='array' then p->'tags' else '[]'::jsonb end) x
  ) s where t <> '';
  update public.team_meetings set
    meet_on = (p->>'meet_on')::date, kind = v_kind,
    title = coalesce(nullif(left(trim(p->>'title'),120),''), title),
    note_taker = v_taker,
    attendees = case when jsonb_typeof(p->'attendees') = 'array' then p->'attendees' else '[]'::jsonb end,
    agenda = left(p->>'agenda',20000), notes = left(p->>'notes',50000), decisions = left(p->>'decisions',20000),
    sections = case when jsonb_typeof(p->'sections') = 'object' then
                 (select coalesce(jsonb_object_agg(key, left(value,20000)), '{}'::jsonb) from jsonb_each_text(p->'sections')
                   where key ~ '^[a-z_]{1,20}$' and trim(value) <> '')
               else '{}'::jsonb end,
    tags = v_tags[1:12],
    updated_by = m.name, updated_at = v_at
  where id = v_id;
  if not found then raise exception 'That meeting is gone. Refresh the page.'; end if;
  return v_at;
end; $fn$;

-- ---------- Delete a meeting (admins, or the person who started it) ----------
create or replace function public.team_meeting_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; x public.team_meetings;
begin
  m := public.team_need();
  select * into x from public.team_meetings where id = p_id;
  if x.id is null then return false; end if;
  if not m.is_admin and coalesce(x.created_by, x.updated_by, '') <> m.name then
    raise exception 'Only an admin or the person who started this meeting can delete it.'; end if;
  update public.team_tasks set meeting_id = null where meeting_id = p_id;
  delete from public.team_meetings where id = p_id;
  return true;
end; $fn$;

-- ---------- Note taker rotation (admins set it up) ----------
create or replace function public.team_rotation_save(tok text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; ppl jsonb;
begin
  m := public.team_need();
  if not m.is_admin then raise exception 'Only an admin can change the rotation.'; end if;
  select coalesce(jsonb_agg(x order by i), '[]'::jsonb) into ppl
    from jsonb_array_elements_text(case when jsonb_typeof(p->'people')='array' then p->'people' else '[]'::jsonb end) with ordinality e(x, i)
   where exists (select 1 from public.team_member t where t.active and t.name = e.x)
     and i = (select min(i2) from jsonb_array_elements_text(p->'people') with ordinality e2(x2, i2) where e2.x2 = e.x);
  insert into public.team_settings(key, value, updated_by, updated_at)
  values ('note_rotation', jsonb_build_object('on', coalesce((p->>'on')::boolean,false), 'people', ppl,
          'start', coalesce(nullif(p->>'start','')::date, public.team_next_monday())), m.name, now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  -- fill in the note taker on upcoming staff meetings that don't have one yet
  update public.team_meetings set note_taker = public.team_rotation_pick(meet_on)
   where kind = 'staff' and meet_on >= (now() at time zone 'America/Los_Angeles')::date and note_taker is null;
  return true;
end; $fn$;

-- ---------- Action items: same as before, plus the meeting id ----------
create or replace function public.team_task_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_owner text := nullif(trim(coalesce(p->>'owner','')),''); v_rep text;
        v_mid uuid := nullif(p->>'meeting_id','')::uuid; v_mon date := nullif(p->>'meeting_on','')::date;
begin
  m := public.team_need();
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'Give the task a name.'; end if;
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  v_rep := case when p->>'repeat' = 'weekly' then 'weekly' else null end;
  if v_mid is not null then select meet_on into v_mon from public.team_meetings where id = v_mid; end if;
  if v_mid is null and v_mon is not null then
    select id into v_mid from public.team_meetings where kind = 'staff' and meet_on = v_mon order by created_at limit 1;
  end if;
  if v_id is null then
    insert into public.team_tasks(title, notes, owner, due_on, repeat, keep_owner, week_of, created_by, meeting_on, meeting_id)
    values (left(trim(p->>'title'),140), left(p->>'notes',1000), v_owner, nullif(p->>'due_on','')::date, v_rep,
            coalesce((p->>'keep_owner')::boolean,false) and v_owner is not null, public.team_week(), m.name, v_mon, v_mid)
    returning id into v_id;
  else
    update public.team_tasks set title = left(trim(p->>'title'),140), notes = left(p->>'notes',1000), owner = v_owner,
      due_on = nullif(p->>'due_on','')::date, repeat = v_rep,
      keep_owner = coalesce((p->>'keep_owner')::boolean,false) and v_owner is not null
    where id = v_id;
    if not found then raise exception 'That task is gone. Refresh the board.'; end if;
  end if;
  return v_id;
end; $fn$;

-- ---------- Old page versions keep working (a phone may still have the old page saved) ----------
create or replace function public.team_meeting(tok text, p_on date) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; x public.team_meetings; prev date;
begin
  m := public.team_need();
  select * into x from public.team_meetings where kind = 'staff' and meet_on = p_on order by created_at limit 1;
  select max(meet_on) into prev from public.team_meetings where kind = 'staff' and meet_on < p_on;
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'meeting', case when x.id is null then null else to_jsonb(x) end,
    'actions', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.team_tasks t
                         where x.id is not null and t.meeting_id = x.id), '[]'::jsonb),
    'prev_on', prev,
    'carry', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.team_tasks t
                       join public.team_meetings pm on pm.id = t.meeting_id
                       where pm.kind = 'staff' and pm.meet_on = prev and t.status = 'open'), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('meet_on', r.meet_on, 'title', r.title) order by r.meet_on desc)
                        from (select meet_on, title from public.team_meetings where kind = 'staff' order by meet_on desc limit 12) r), '[]'::jsonb)
  );
end; $fn$;

create or replace function public.team_meeting_save(tok text, p jsonb) returns timestamptz
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_on date := (p->>'meet_on')::date; v_at timestamptz := now(); v_id uuid;
begin
  m := public.team_need();
  if v_on is null then raise exception 'Pick a meeting date.'; end if;
  select id into v_id from public.team_meetings where kind = 'staff' and meet_on = v_on order by created_at limit 1;
  if v_id is null then
    insert into public.team_meetings(meet_on, kind, title, created_by, updated_by)
    values (v_on, 'staff', 'Staff meeting', m.name, m.name) returning id into v_id;
  end if;
  update public.team_meetings set title = coalesce(nullif(left(trim(p->>'title'),120),''), title),
    attendees = case when jsonb_typeof(p->'attendees') = 'array' then p->'attendees' else attendees end,
    agenda = left(p->>'agenda',20000), notes = left(p->>'notes',50000), decisions = left(p->>'decisions',20000),
    updated_by = m.name, updated_at = v_at
  where id = v_id;
  return v_at;
end; $fn$;

-- ---------- Permissions ----------
revoke all on function public.team_rotation_pick(date) from public, anon, authenticated;
revoke all on function public.team_meeting_list(text, jsonb) from public, anon;
revoke all on function public.team_meeting_get(text, uuid) from public, anon;
revoke all on function public.team_meeting_start(text, jsonb) from public, anon;
revoke all on function public.team_meeting_save2(text, jsonb) from public, anon;
revoke all on function public.team_meeting_delete(text, uuid) from public, anon;
revoke all on function public.team_rotation_save(text, jsonb) from public, anon;
revoke all on function public.team_meeting(text, date) from public, anon;
revoke all on function public.team_meeting_save(text, jsonb) from public, anon;
revoke all on function public.team_task_save(text, jsonb) from public, anon;
grant execute on function public.team_meeting_list(text, jsonb) to authenticated;
grant execute on function public.team_meeting_get(text, uuid) to authenticated;
grant execute on function public.team_meeting_start(text, jsonb) to authenticated;
grant execute on function public.team_meeting_save2(text, jsonb) to authenticated;
grant execute on function public.team_meeting_delete(text, uuid) to authenticated;
grant execute on function public.team_rotation_save(text, jsonb) to authenticated;
grant execute on function public.team_meeting(text, date) to authenticated;
grant execute on function public.team_meeting_save(text, jsonb) to authenticated;
grant execute on function public.team_task_save(text, jsonb) to authenticated;
