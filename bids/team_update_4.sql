-- =====================================================================
-- Latino Built Team Playbook: update 4 (team to-do board). Safe to run again.
-- Run AFTER team_update_3.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- A shared to-do board for staff: anyone signed in can add a task, take it,
-- assign it to a teammate, give it back, or mark it done. Weekly tasks
-- (like cleaning the office) reset every Monday: they go back to "up for grabs"
-- unless "same person every week" is on. Done one-time tasks drop off after 14 days.
-- =====================================================================

create table if not exists public.team_tasks (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  notes       text,
  owner       text,                         -- teammate's name, null = up for grabs
  due_on      date,
  repeat      text check (repeat in ('weekly')),
  keep_owner  boolean not null default false,
  status      text not null default 'open' check (status in ('open','done')),
  done_by     text,
  done_at     timestamptz,
  week_of     date,                         -- Monday of the week a weekly task was last reset
  created_by  text not null,
  created_at  timestamptz not null default now()
);
alter table public.team_tasks enable row level security;
revoke all on public.team_tasks from anon, authenticated;   -- only reachable through the functions below

-- Monday of the current week, Pacific time
create or replace function public.team_week() returns date
language sql stable as $fn$
  select date_trunc('week', now() at time zone 'America/Los_Angeles')::date;
$fn$;

-- The board: resets weekly tasks for the new week, then returns everything to show
create or replace function public.team_tasks(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; wk date := public.team_week();
begin
  m := public.team_need();
  update public.team_tasks set
    status = 'open', done_by = null, done_at = null,
    owner = case when keep_owner then owner else null end,
    week_of = wk
  where repeat = 'weekly' and coalesce(week_of, '1900-01-01') < wk;
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'week', wk,
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.status, t.due_on nulls last, t.created_at) from public.team_tasks t
                       where t.status = 'open' or t.repeat = 'weekly' or t.done_at > now() - interval '14 days'), '[]'::jsonb)
  );
end; $fn$;

-- Add or edit a task
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
    insert into public.team_tasks(title, notes, owner, due_on, repeat, keep_owner, week_of, created_by)
    values (left(trim(p->>'title'),140), left(p->>'notes',1000), v_owner, nullif(p->>'due_on','')::date, v_rep,
            coalesce((p->>'keep_owner')::boolean,false) and v_owner is not null, public.team_week(), m.name)
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

-- Take it, assign it, give it back, mark done or not done, delete
create or replace function public.team_task_act(tok text, p_id uuid, p_act text, p_who text) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; t public.team_tasks;
begin
  m := public.team_need();
  select * into t from public.team_tasks where id = p_id;
  if t.id is null then raise exception 'That task is gone. Refresh the board.'; end if;
  if p_act = 'take' then
    update public.team_tasks set owner = m.name where id = p_id;
  elsif p_act = 'assign' then
    if not exists (select 1 from public.team_member where active and name = p_who) then raise exception 'That person is not on the team list.'; end if;
    update public.team_tasks set owner = p_who where id = p_id;
  elsif p_act = 'release' then
    update public.team_tasks set owner = null, keep_owner = false where id = p_id;
  elsif p_act = 'done' then
    update public.team_tasks set status = 'done', done_by = m.name, done_at = now(), owner = coalesce(owner, m.name) where id = p_id;
  elsif p_act = 'undo' then
    update public.team_tasks set status = 'open', done_by = null, done_at = null where id = p_id;
  elsif p_act = 'delete' then
    if t.created_by <> m.name and not m.is_admin then raise exception 'Only the person who added it (or an admin) can delete it.'; end if;
    delete from public.team_tasks where id = p_id;
  else
    raise exception 'Unknown action.';
  end if;
  return true;
end; $fn$;

revoke all on function public.team_week() from public, anon;
revoke all on function public.team_tasks(text) from public, anon;
revoke all on function public.team_task_save(text, jsonb) from public, anon;
revoke all on function public.team_task_act(text, uuid, text, text) from public, anon;
grant execute on function public.team_tasks(text) to authenticated;
grant execute on function public.team_task_save(text, jsonb) to authenticated;
grant execute on function public.team_task_act(text, uuid, text, text) to authenticated;
