-- =====================================================================
-- Latino Built Team Playbook: update 5 (staff meeting notes + monthly report). Safe to run again.
-- Run AFTER team_update_4.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- Shared notes for the Monday staff meeting: who came, agenda, notes, decisions.
-- Action items are saved as tasks on the team to-do board, linked to the meeting.
-- Also adds team_month_stats() for the one-click monthly report.
-- =====================================================================

create table if not exists public.team_meetings (
  meet_on     date primary key,
  title       text not null default 'Staff meeting',
  attendees   jsonb not null default '[]'::jsonb,
  agenda      text,
  notes       text,
  decisions   text,
  updated_by  text,
  updated_at  timestamptz not null default now()
);
alter table public.team_meetings enable row level security;
revoke all on public.team_meetings from anon, authenticated;

alter table public.team_tasks add column if not exists meeting_on date;

-- One meeting with its action items, plus the open items from the meeting before it
create or replace function public.team_meeting(tok text, p_on date) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; prev date;
begin
  m := public.team_need();
  select max(meet_on) into prev from public.team_meetings where meet_on < p_on;
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'meeting', (select to_jsonb(x) from public.team_meetings x where x.meet_on = p_on),
    'actions', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.team_tasks t where t.meeting_on = p_on), '[]'::jsonb),
    'prev_on', prev,
    'carry', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.team_tasks t
                       where t.meeting_on = prev and t.status = 'open'), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('meet_on', r.meet_on, 'title', r.title) order by r.meet_on desc)
                        from (select meet_on, title from public.team_meetings order by meet_on desc limit 12) r), '[]'::jsonb)
  );
end; $fn$;

-- Save the notes (last save wins; the page shows who saved last)
create or replace function public.team_meeting_save(tok text, p jsonb) returns timestamptz
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_on date := (p->>'meet_on')::date; v_at timestamptz := now();
begin
  m := public.team_need();
  if v_on is null then raise exception 'Pick a meeting date.'; end if;
  insert into public.team_meetings(meet_on, title, attendees, agenda, notes, decisions, updated_by, updated_at)
  values (v_on, coalesce(nullif(left(trim(p->>'title'),120),''),'Staff meeting'),
          case when jsonb_typeof(p->'attendees') = 'array' then p->'attendees' else '[]'::jsonb end,
          left(p->>'agenda',20000), left(p->>'notes',50000), left(p->>'decisions',20000), m.name, v_at)
  on conflict (meet_on) do update set title = excluded.title, attendees = excluded.attendees, agenda = excluded.agenda,
    notes = excluded.notes, decisions = excluded.decisions, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return v_at;
end; $fn$;

-- Same as before, plus an optional link to the meeting the task came from
create or replace function public.team_task_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_owner text := nullif(trim(coalesce(p->>'owner','')),''); v_rep text;
begin
  m := public.team_need();
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'Give the task a name.'; end if;
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  v_rep := case when p->>'repeat' = 'weekly' then 'weekly' else null end;
  if v_id is null then
    insert into public.team_tasks(title, notes, owner, due_on, repeat, keep_owner, week_of, created_by, meeting_on)
    values (left(trim(p->>'title'),140), left(p->>'notes',1000), v_owner, nullif(p->>'due_on','')::date, v_rep,
            coalesce((p->>'keep_owner')::boolean,false) and v_owner is not null, public.team_week(), m.name,
            nullif(p->>'meeting_on','')::date)
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

-- Numbers for the monthly report (month = any date in that month)
create or replace function public.team_month_stats(tok text, p_month date) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; a timestamptz; b timestamptz;
begin
  m := public.team_need();
  a := date_trunc('month', p_month)::timestamptz; b := (date_trunc('month', p_month) + interval '1 month')::timestamptz;
  return jsonb_build_object(
    'tasks_done', (select count(*) from public.team_tasks where done_at >= a and done_at < b),
    'tasks_added', (select count(*) from public.team_tasks where created_at >= a and created_at < b),
    'meetings', (select count(*) from public.team_meetings where meet_on >= a::date and meet_on < b::date),
    'jobs_posted', (select count(*) from public.bid_jobs where created_at >= a and created_at < b and status <> 'draft'),
    'bids', (select count(*) from public.bid_submissions where created_at >= a and created_at < b),
    'bidders', (select count(distinct lower(company)) from public.bid_submissions where created_at >= a and created_at < b),
    'awarded', (select count(*) from public.bid_submissions where status = 'awarded' and updated_at >= a and updated_at < b),
    'awarded_total', (select coalesce(sum(total),0) from public.bid_submissions where status = 'awarded' and updated_at >= a and updated_at < b),
    'signups', (select count(*) from public.bid_alert_subs where created_at >= a and created_at < b),
    'signups_total', (select count(*) from public.bid_alert_subs where active)
  );
end; $fn$;

revoke all on function public.team_meeting(text, date) from public, anon;
revoke all on function public.team_meeting_save(text, jsonb) from public, anon;
revoke all on function public.team_month_stats(text, date) from public, anon;
grant execute on function public.team_meeting(text, date) to authenticated;
grant execute on function public.team_meeting_save(text, jsonb) to authenticated;
grant execute on function public.team_month_stats(text, date) to authenticated;
grant execute on function public.team_task_save(text, jsonb) to authenticated;
