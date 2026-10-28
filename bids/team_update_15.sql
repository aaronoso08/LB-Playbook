-- =====================================================================
-- Latino Built Team Playbook: update 15 (Growth path mentors). Safe to run again.
-- Run AFTER team_update_14.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- Mentors: board members and experienced contractors who help bring others up.
-- They show in their own row on the Growth path, with no progress bar or alerts,
-- and don't count in the growth numbers. Staff only, like everything else.
-- =====================================================================

alter table public.growth_people add column if not exists is_mentor boolean not null default false;

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
    insert into public.growth_people(name, company, start_track, trade, area, phone, email, language, staff_owner, goal, notes, cert_id, is_member, is_mentor, created_by, updated_by)
    values (left(trim(p->>'name'),120), left(p->>'company',160), v_track, left(p->>'trade',120), left(p->>'area',120), left(p->>'phone',60),
            left(p->>'email',200), left(p->>'language',20), v_owner, left(p->>'goal',300), left(p->>'notes',2000), v_cert,
            coalesce((p->>'is_member')::boolean,false), coalesce((p->>'is_mentor')::boolean,false), m.name, m.name)
    returning id into v_id;
  else
    update public.growth_people set name = left(trim(p->>'name'),120), company = left(p->>'company',160), start_track = v_track,
      trade = left(p->>'trade',120), area = left(p->>'area',120), phone = left(p->>'phone',60), email = left(p->>'email',200),
      language = left(p->>'language',20), staff_owner = v_owner, goal = left(p->>'goal',300), notes = left(p->>'notes',2000),
      cert_id = v_cert, is_member = coalesce((p->>'is_member')::boolean, is_member),
      is_mentor = coalesce((p->>'is_mentor')::boolean, is_mentor), updated_by = m.name, updated_at = now()
    where id = v_id and active;
    if not found then raise exception 'That person is gone. Refresh the page.'; end if;
  end if;
  return v_id;
end; $fn$;

-- Program pulse: the Membership card counts people on the path, not mentors
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
       jsonb_build_object('label','On the growth path','value',(select count(*) from growth_people where active and not is_mentor)),
       jsonb_build_object('label','Steps reached this year','value',(select count(*) from growth_steps s join growth_people g on g.id = s.person_id
                           where g.active and not g.is_mentor and s.status = 'done' and s.done_on >= y)))
  );
end; $fn$;

revoke all on function public.pulse_auto() from public, anon, authenticated;
revoke all on function public.growth_save(text,jsonb) from public, anon;
grant execute on function public.growth_save(text,jsonb) to authenticated;
