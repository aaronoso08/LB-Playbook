-- =====================================================================
-- Latino Built Team Playbook: update 11 (meetings on the Home page). Safe to run again.
-- Run AFTER team_update_10.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- 1) team_meeting_home(): what the Home page shows. The last meeting that has notes
--    (decisions, topics, action items) and the next Monday staff meeting (note taker, agenda).
-- 2) team_meeting_add_agenda(): add a topic to Monday's agenda from the Home page.
--    It adds a line to what's there, so two people adding at once never erase each other.
-- =====================================================================

create or replace function public.team_meeting_home(tok text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; today date := (now() at time zone 'America/Los_Angeles')::date;
        nxt date := coalesce(nullif(p->>'next_on','')::date, public.team_next_monday()); last public.team_meetings; nm public.team_meetings;
begin
  m := public.team_need();
  select * into last from public.team_meetings x
   where x.meet_on <= today
     and (coalesce(trim(x.notes),'') <> '' or coalesce(trim(x.decisions),'') <> '' or x.sections <> '{}'::jsonb
          or exists (select 1 from public.team_tasks t where t.meeting_id = x.id))
   order by x.meet_on desc, x.updated_at desc limit 1;
  select * into nm from public.team_meetings where kind = 'staff' and meet_on = nxt order by created_at limit 1;
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'last', case when last.id is null then null else jsonb_build_object(
       'id', last.id, 'meet_on', last.meet_on, 'title', last.title, 'kind', last.kind, 'note_taker', last.note_taker,
       'decisions', last.decisions, 'sections', last.sections, 'notes', last.notes,
       'actions', coalesce((select jsonb_agg(jsonb_build_object('title', t.title, 'owner', t.owner, 'due_on', t.due_on, 'status', t.status)
                             order by t.status, t.due_on nulls last, t.created_at)
                            from public.team_tasks t where t.meeting_id = last.id), '[]'::jsonb)) end,
    'next', jsonb_build_object('id', nm.id, 'meet_on', nxt, 'agenda', nm.agenda,
       'note_taker', coalesce(nm.note_taker, public.team_rotation_pick(nxt)))
  );
end; $fn$;

create or replace function public.team_meeting_add_agenda(tok text, p jsonb) returns text
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_on date := nullif(p->>'meet_on','')::date; v_line text := left(trim(coalesce(p->>'line','')),300); v_id uuid; v_ag text;
begin
  m := public.team_need();
  if v_on is null then raise exception 'Pick a meeting date.'; end if;
  if v_line = '' then raise exception 'Type a topic first.'; end if;
  v_id := public.team_meeting_start(tok, jsonb_build_object('meet_on', v_on, 'kind', 'staff'));
  update public.team_meetings
     set agenda = left(case when coalesce(trim(agenda),'') = '' then '' else rtrim(agenda, E' \n') || E'\n' end
                       || v_line || ' (' || split_part(m.name,' ',1) || ')', 20000),
         updated_by = m.name, updated_at = now()
   where id = v_id
  returning agenda into v_ag;
  return v_ag;
end; $fn$;

revoke all on function public.team_meeting_home(text, jsonb) from public, anon;
revoke all on function public.team_meeting_add_agenda(text, jsonb) from public, anon;
grant execute on function public.team_meeting_home(text, jsonb) to authenticated;
grant execute on function public.team_meeting_add_agenda(text, jsonb) to authenticated;
