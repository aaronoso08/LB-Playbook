-- =====================================================================
-- Latino Built Team Playbook: update 12 (team board on Home). Safe to run again.
-- Run AFTER team_update_11.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- 1) Program pulse: one card per program or area with an owner, on track / needs help / stuck,
--    a one-line update, a few numbers and the next date. Some numbers fill in on their own.
-- 2) Wins: anyone shares a win (a home finished, a contractor certified). Others can cheer.
-- 3) Deadlines: one list of grant due dates, funder reports, events and meetings.
-- 4) Where's everyone: office, field, remote or out, just for today.
-- 5) Page owners and "checked on" dates, plus "Was this helpful?" on every page.
-- 6) Ask the team: questions anyone can ask; answers stay for the next person.
-- Staff only, like everything else.
-- =====================================================================

-- ---------- 1) Program pulse ----------
create table if not exists public.pulse_cards (
  key        text primary key,
  title      text not null,
  owner      text,
  status     text check (status in ('good','help','stuck')),
  note       text,
  numbers    jsonb not null default '[]'::jsonb,
  next_label text,
  next_on    date,
  sort       int not null default 100,
  active     boolean not null default true,
  updated_by text,
  updated_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.pulse_cards enable row level security;
revoke all on public.pulse_cards from anon, authenticated;

insert into public.pulse_cards(key, title, sort) values
  ('hhgp','Healthy Homes (HHGP)',10), ('nhe','Nuestro Hogar - Electric (PCEF)',20), ('nhg','Nuestro Hogar - Gas',30),
  ('homes','HOMES / HEAR',40), ('cpf','CPF (Energy Trust)',50), ('members','Membership',60),
  ('training','Trainings and classes',70), ('jobs','Bid board and contractor jobs',80),
  ('swwa','SW Washington',90), ('grants','Grants and funding',100)
on conflict (key) do nothing;

-- Numbers we can count on our own, by card
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
                           where c.active and i.expires_on between (now() at time zone 'America/Los_Angeles')::date and (now() at time zone 'America/Los_Angeles')::date + 60)))
  );
end; $fn$;

create or replace function public.pulse_save(tok text, p jsonb) returns timestamptz
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_key text := nullif(trim(coalesce(p->>'key','')),''); v_owner text := nullif(trim(coalesce(p->>'owner','')),'');
        v_status text := nullif(p->>'status',''); v_at timestamptz := now(); v_nums jsonb;
begin
  m := public.team_need();
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  if v_status is not null and v_status not in ('good','help','stuck') then raise exception 'Pick a status.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('label', left(trim(e->>'label'),40), 'value', left(trim(e->>'value'),30)) order by i), '[]'::jsonb) into v_nums
    from jsonb_array_elements(case when jsonb_typeof(p->'numbers')='array' then p->'numbers' else '[]'::jsonb end) with ordinality x(e, i)
   where i <= 4 and coalesce(trim(e->>'label'),'') <> '' and coalesce(trim(e->>'value'),'') <> '';
  if v_key is null then
    if not m.is_admin then raise exception 'Only an admin can add a card.'; end if;
    if coalesce(trim(p->>'title'),'') = '' then raise exception 'Give the card a name.'; end if;
    v_key := 'c' || substr(md5(random()::text), 1, 8);
    insert into public.pulse_cards(key, title, sort) values (v_key, left(trim(p->>'title'),80),
      coalesce((select max(sort) + 10 from public.pulse_cards), 10));
  end if;
  update public.pulse_cards set
    title = case when m.is_admin and coalesce(trim(p->>'title'),'') <> '' then left(trim(p->>'title'),80) else title end,
    owner = v_owner, status = v_status, note = nullif(left(trim(coalesce(p->>'note','')),400),''),
    numbers = v_nums, next_label = nullif(left(trim(coalesce(p->>'next_label','')),120),''), next_on = nullif(p->>'next_on','')::date,
    active = case when m.is_admin and p ? 'active' then coalesce((p->>'active')::boolean, active) else active end,
    updated_by = m.name, updated_at = v_at
  where key = v_key;
  if not found then raise exception 'That card is gone. Refresh the page.'; end if;
  return v_at;
end; $fn$;

-- ---------- 2) Wins ----------
create table if not exists public.team_wins (
  id         uuid primary key default gen_random_uuid(),
  body       text not null,
  program    text,
  cheers     text[] not null default '{}',
  created_by text not null,
  created_at timestamptz not null default now()
);
alter table public.team_wins enable row level security;
revoke all on public.team_wins from anon, authenticated;

create or replace function public.win_add(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid;
begin
  m := public.team_need();
  if coalesce(trim(p->>'body'),'') = '' then raise exception 'Write the win first.'; end if;
  insert into public.team_wins(body, program, created_by) values (left(trim(p->>'body'),300), nullif(left(p->>'program',20),''), m.name)
  returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.win_cheer(tok text, p_id uuid) returns int
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; n int;
begin
  m := public.team_need();
  update public.team_wins set cheers = case when m.name = any(cheers) then array_remove(cheers, m.name) else array_append(cheers, m.name) end
   where id = p_id returning coalesce(array_length(cheers,1),0) into n;
  return coalesce(n,0);
end; $fn$;

create or replace function public.win_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.team_wins where id = p_id and (m.is_admin or created_by = m.name);
  if not found then raise exception 'Only the person who shared it, or an admin, can remove it.'; end if;
  return true;
end; $fn$;

-- ---------- 3) Deadlines ----------
create table if not exists public.team_deadlines (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  due_on     date not null,
  kind       text not null default 'other' check (kind in ('grant','report','event','meeting','training','other')),
  program    text,
  owner      text,
  url        text,
  notes      text,
  done       boolean not null default false,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.team_deadlines enable row level security;
revoke all on public.team_deadlines from anon, authenticated;

create or replace function public.deadline_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_owner text := nullif(trim(coalesce(p->>'owner','')),'');
        v_kind text := coalesce(nullif(p->>'kind',''),'other'); v_url text := nullif(trim(coalesce(p->>'url','')),'');
begin
  m := public.team_need();
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'Name the deadline.'; end if;
  if nullif(p->>'due_on','') is null then raise exception 'Pick the date.'; end if;
  if v_kind not in ('grant','report','event','meeting','training','other') then raise exception 'Pick a type.'; end if;
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  if v_url is not null and v_url !~* '^https?://' then v_url := 'https://' || v_url; end if;
  if v_id is null then
    insert into public.team_deadlines(title, due_on, kind, program, owner, url, notes, created_by, updated_by)
    values (left(trim(p->>'title'),140), (p->>'due_on')::date, v_kind, nullif(left(p->>'program',20),''), v_owner, left(v_url,500),
            left(p->>'notes',1000), m.name, m.name)
    returning id into v_id;
  else
    update public.team_deadlines set title = left(trim(p->>'title'),140), due_on = (p->>'due_on')::date, kind = v_kind,
      program = nullif(left(p->>'program',20),''), owner = v_owner, url = left(v_url,500), notes = left(p->>'notes',1000),
      done = coalesce((p->>'done')::boolean, done), updated_by = m.name, updated_at = now()
    where id = v_id;
    if not found then raise exception 'That deadline is gone. Refresh the page.'; end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.deadline_done(tok text, p_id uuid, p_done boolean) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  update public.team_deadlines set done = coalesce(p_done,true), updated_by = m.name, updated_at = now() where id = p_id;
  return found;
end; $fn$;

create or replace function public.deadline_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.team_deadlines where id = p_id and (m.is_admin or created_by = m.name);
  if not found then raise exception 'Only the person who added it, or an admin, can delete it.'; end if;
  return true;
end; $fn$;

-- Everything with a date coming up: our deadlines, grant due dates, and non-staff meetings
create or replace function public.deadlines_upcoming(p_days int) returns jsonb
language sql stable security definer set search_path = public as $fn$
  with t as (select (now() at time zone 'America/Los_Angeles')::date d)
  select coalesce(jsonb_agg(x order by (x->>'due_on'), (x->>'title')), '[]'::jsonb) from (
    select jsonb_build_object('id', id, 'src', 'deadline', 'title', title, 'due_on', due_on, 'kind', kind, 'program', program,
             'owner', owner, 'url', url, 'notes', notes, 'done', done, 'created_by', created_by) x
      from team_deadlines, t where not done and due_on >= t.d - 14 and due_on <= t.d + p_days
    union all
    select jsonb_build_object('id', id, 'src', 'grant', 'title', title || coalesce(' (' || funder || ')',''), 'due_on', due_on, 'kind', 'grant',
             'owner', owner, 'url', url, 'status', status)
      from grant_apps, t where not archived and status in ('considering','applying') and due_on between t.d - 7 and t.d + p_days
    union all
    select jsonb_build_object('id', id, 'src', 'meeting', 'title', title, 'due_on', meet_on, 'kind', 'meeting')
      from team_meetings, t where kind <> 'staff' and meet_on between t.d and t.d + p_days
  ) s;
$fn$;

-- ---------- 4) Where's everyone (today only) ----------
create table if not exists public.team_presence (
  name       text primary key,
  status     text not null check (status in ('office','field','remote','out')),
  note       text,
  on_date    date not null,
  updated_at timestamptz not null default now()
);
alter table public.team_presence enable row level security;
revoke all on public.team_presence from anon, authenticated;

create or replace function public.presence_set(tok text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_s text := nullif(p->>'status','');
begin
  m := public.team_need();
  if v_s is null then delete from public.team_presence where name = m.name; return true; end if;
  if v_s not in ('office','field','remote','out') then raise exception 'Pick office, field, remote or out.'; end if;
  insert into public.team_presence(name, status, note, on_date, updated_at)
  values (m.name, v_s, nullif(left(trim(coalesce(p->>'note','')),80),''), (now() at time zone 'America/Los_Angeles')::date, now())
  on conflict (name) do update set status = excluded.status, note = excluded.note, on_date = excluded.on_date, updated_at = now();
  return true;
end; $fn$;

-- ---------- 5) Page owners, checked dates and feedback ----------
create table if not exists public.page_meta (
  page_id    text primary key,
  owner      text,
  checked_on date,
  checked_by text,
  updated_at timestamptz not null default now()
);
create table if not exists public.page_feedback (
  id         uuid primary key default gen_random_uuid(),
  page_id    text not null,
  helpful    boolean not null,
  note       text,
  who        text not null,
  created_at timestamptz not null default now()
);
alter table public.page_meta enable row level security;
alter table public.page_feedback enable row level security;
revoke all on public.page_meta, public.page_feedback from anon, authenticated;

create or replace function public.page_meta_all(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'meta', coalesce((select jsonb_object_agg(page_id, jsonb_build_object('owner', owner, 'checked_on', checked_on, 'checked_by', checked_by)) from public.page_meta), '{}'::jsonb),
    'votes', coalesce((select jsonb_object_agg(page_id, jsonb_build_object('up', up, 'down', down, 'notes', notes)) from (
        select page_id, count(*) filter (where helpful) up, count(*) filter (where not helpful) down,
               coalesce(jsonb_agg(jsonb_build_object('note', note, 'who', who, 'at', created_at) order by created_at desc)
                        filter (where note is not null), '[]'::jsonb) notes
          from public.page_feedback where created_at > now() - interval '180 days' group by page_id) v), '{}'::jsonb)
  );
end; $fn$;

create or replace function public.page_meta_save(tok text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_page text := left(nullif(trim(coalesce(p->>'page_id','')),''),60); v_owner text := nullif(trim(coalesce(p->>'owner','')),'');
        cur public.page_meta;
begin
  m := public.team_need();
  if v_page is null then raise exception 'Missing page.'; end if;
  select * into cur from public.page_meta where page_id = v_page;
  if p ? 'owner' then
    if not m.is_admin and coalesce(cur.owner,'') <> m.name and not (cur.owner is null and v_owner = m.name) then
      raise exception 'Only an admin or the page owner can change the owner.'; end if;
    if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
      raise exception 'That person is not on the team list.'; end if;
  end if;
  insert into public.page_meta(page_id, owner, checked_on, checked_by, updated_at)
  values (v_page, case when p ? 'owner' then v_owner else cur.owner end,
          case when coalesce((p->>'checked')::boolean,false) then (now() at time zone 'America/Los_Angeles')::date else cur.checked_on end,
          case when coalesce((p->>'checked')::boolean,false) then m.name else cur.checked_by end, now())
  on conflict (page_id) do update set owner = excluded.owner, checked_on = excluded.checked_on, checked_by = excluded.checked_by, updated_at = now();
  return true;
end; $fn$;

create or replace function public.page_feedback_add(tok text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if nullif(p->>'page_id','') is null then raise exception 'Missing page.'; end if;
  insert into public.page_feedback(page_id, helpful, note, who)
  values (left(p->>'page_id',60), coalesce((p->>'helpful')::boolean, true), nullif(left(trim(coalesce(p->>'note','')),500),''), m.name);
  return true;
end; $fn$;

-- ---------- 6) Ask the team ----------
create table if not exists public.team_questions (
  id          uuid primary key default gen_random_uuid(),
  question    text not null,
  page_id     text,
  asked_by    text not null,
  answer      text,
  answered_by text,
  answered_at timestamptz,
  link_page   text,
  created_at  timestamptz not null default now()
);
alter table public.team_questions enable row level security;
revoke all on public.team_questions from anon, authenticated;

create or replace function public.questions_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object('me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'questions', coalesce((select jsonb_agg(to_jsonb(q) order by (q.answer is not null), q.created_at desc) from (select * from public.team_questions order by created_at desc limit 300) q), '[]'::jsonb));
end; $fn$;

create or replace function public.question_ask(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid;
begin
  m := public.team_need();
  if coalesce(trim(p->>'question'),'') = '' then raise exception 'Type your question.'; end if;
  insert into public.team_questions(question, page_id, asked_by) values (left(trim(p->>'question'),500), nullif(left(p->>'page_id',60),''), m.name)
  returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.question_answer(tok text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if coalesce(trim(p->>'answer'),'') = '' then raise exception 'Type the answer.'; end if;
  update public.team_questions set answer = left(trim(p->>'answer'),3000), answered_by = m.name, answered_at = now(),
    link_page = nullif(left(p->>'link_page',60),'')
  where id = (p->>'id')::uuid;
  if not found then raise exception 'That question is gone. Refresh the page.'; end if;
  return true;
end; $fn$;

create or replace function public.question_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.team_questions where id = p_id and (m.is_admin or asked_by = m.name);
  if not found then raise exception 'Only the person who asked, or an admin, can remove it.'; end if;
  return true;
end; $fn$;

-- ---------- Everything the Home page needs, in one call ----------
create or replace function public.home_board(tok text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; today date := (now() at time zone 'America/Los_Angeles')::date;
        v_days int := least(greatest(coalesce((p->>'days')::int, 45), 7), 400);
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'today', today,
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'pulse', coalesce((select jsonb_agg(to_jsonb(c) order by c.sort, c.title) from public.pulse_cards c where c.active or coalesce((p->>'all')::boolean,false)), '[]'::jsonb),
    'auto', public.pulse_auto(),
    'wins', coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at desc) from (select * from public.team_wins
                       where created_at > now() - interval '45 days' order by created_at desc limit 40) w), '[]'::jsonb),
    'deadlines', public.deadlines_upcoming(v_days),
    'presence', coalesce((select jsonb_object_agg(name, jsonb_build_object('status', status, 'note', note)) from public.team_presence where on_date = today), '{}'::jsonb),
    'open_questions', (select count(*) from public.team_questions where answer is null)
  );
end; $fn$;

-- ---------- Permissions ----------
revoke all on function public.pulse_auto() from public, anon, authenticated;
revoke all on function public.deadlines_upcoming(int) from public, anon, authenticated;
do $do$
declare f text;
begin
  foreach f in array array['pulse_save(text,jsonb)','win_add(text,jsonb)','win_cheer(text,uuid)','win_delete(text,uuid)',
    'deadline_save(text,jsonb)','deadline_done(text,uuid,boolean)','deadline_delete(text,uuid)','presence_set(text,jsonb)',
    'page_meta_all(text)','page_meta_save(text,jsonb)','page_feedback_add(text,jsonb)','questions_list(text)',
    'question_ask(text,jsonb)','question_answer(text,jsonb)','question_delete(text,uuid)','home_board(text,jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
