-- =====================================================================
-- Latino Built Team Playbook: update 7 (pipeline matches the HHGP Tracker statuses). Safe to run again.
-- Run AFTER team_update_6.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- New stage "HHA complete" (assessed, deciding) between "HHA scheduled" and "Moving forward".
-- A date doesn't mean a home was accepted, so the outcome is its own state:
-- Not eligible, No answer, Referred out, On hold, Closed.
-- Each home is tagged HHGP or PCEF (Referred – Healthy Homes vs Referred – PCEF Grant).
-- =====================================================================

alter table public.hhgp_homes add column if not exists program text not null default 'HHGP';
alter table public.hhgp_homes drop constraint if exists hhgp_homes_program_check;
alter table public.hhgp_homes add constraint hhgp_homes_program_check check (program in ('HHGP','PCEF'));
alter table public.hhgp_homes drop constraint if exists hhgp_homes_stage_check;
alter table public.hhgp_homes add constraint hhgp_homes_stage_check check (stage in
  ('intake','assessment','assessed','reservation','work','closeout','paid','noteligible','noanswer','referredout','hold','closed'));

create or replace function public.hhgp_stage_ok(s text) returns boolean language sql immutable as $fn$
  select s in ('intake','assessment','assessed','reservation','work','closeout','paid','noteligible','noanswer','referredout','hold','closed');
$fn$;

-- The board: open homes, plus finished or closed ones from the last 60 days
create or replace function public.hhgp_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'homes', coalesce((select jsonb_agg(to_jsonb(h) order by h.stage_at) from public.hhgp_homes h
                       where not h.archived and (h.stage in ('intake','assessment','assessed','reservation','work','closeout','hold')
                             or h.stage_at > now() - interval '60 days')), '[]'::jsonb)
  );
end; $fn$;

create or replace function public.hhgp_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; old public.hhgp_homes; v_stage text; v_owner text; v_prog text; v_what text := '';
begin
  m := public.team_need();
  if coalesce(trim(p->>'address'),'') = '' then raise exception 'Add the home address.'; end if;
  v_owner := nullif(trim(coalesce(p->>'owner','')),'');
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  v_stage := coalesce(nullif(p->>'stage',''),'intake');
  if not public.hhgp_stage_ok(v_stage) then raise exception 'Unknown stage.'; end if;
  v_prog := case when p->>'program' = 'PCEF' then 'PCEF' else 'HHGP' end;

  if v_id is null then
    insert into public.hhgp_homes(address, city, first_name, stage, program, owner, reservation_no, reserved_amt, paid_amt, certa, next_step, notes,
                                  paid_on, created_by, updated_by)
    values (left(trim(p->>'address'),200), left(p->>'city',80), left(p->>'first_name',60), v_stage, v_prog, v_owner,
            left(p->>'reservation_no',60), nullif(p->>'reserved_amt','')::numeric, nullif(p->>'paid_amt','')::numeric,
            coalesce((p->>'certa')::boolean,false), left(p->>'next_step',300), left(p->>'notes',4000),
            case when v_stage = 'paid' then current_date end, m.name, m.name)
    returning id into v_id;
    insert into public.hhgp_events(home_id, who, what, stage) values (v_id, m.name, 'Added to the pipeline', v_stage);
  else
    select * into old from public.hhgp_homes where id = v_id;
    if old.id is null then raise exception 'That home is gone. Refresh the board.'; end if;
    if old.stage is distinct from v_stage then v_what := v_what || 'Moved to ' || v_stage || '. '; end if;
    if old.program is distinct from v_prog then v_what := v_what || 'Program: ' || v_prog || '. '; end if;
    if old.owner is distinct from v_owner then v_what := v_what || 'Owner: ' || coalesce(v_owner,'nobody') || '. '; end if;
    if old.reservation_no is distinct from nullif(p->>'reservation_no','') then v_what := v_what || 'Reservation # updated. '; end if;
    if old.reserved_amt is distinct from nullif(p->>'reserved_amt','')::numeric then v_what := v_what || 'Reserved amount updated. '; end if;
    if old.paid_amt is distinct from nullif(p->>'paid_amt','')::numeric then v_what := v_what || 'Paid amount updated. '; end if;
    if old.next_step is distinct from nullif(p->>'next_step','') then v_what := v_what || 'Next step updated. '; end if;
    update public.hhgp_homes set address = left(trim(p->>'address'),200), city = left(p->>'city',80), first_name = left(p->>'first_name',60),
      stage = v_stage, program = v_prog, owner = v_owner, reservation_no = nullif(left(p->>'reservation_no',60),''),
      reserved_amt = nullif(p->>'reserved_amt','')::numeric, paid_amt = nullif(p->>'paid_amt','')::numeric,
      certa = coalesce((p->>'certa')::boolean,false), next_step = nullif(left(p->>'next_step',300),''), notes = left(p->>'notes',4000),
      stage_at = case when old.stage is distinct from v_stage then now() else stage_at end,
      paid_on = case when v_stage = 'paid' and old.stage <> 'paid' then current_date when v_stage <> 'paid' then null else paid_on end,
      archived = coalesce((p->>'archived')::boolean, archived),
      updated_by = m.name, updated_at = now()
    where id = v_id;
    if coalesce((p->>'archived')::boolean,false) and not old.archived then v_what := v_what || 'Removed from the board. '; end if;
    if v_what <> '' then insert into public.hhgp_events(home_id, who, what, stage) values (v_id, m.name, trim(v_what), v_stage); end if;
  end if;
  return v_id;
end; $fn$;

-- Monthly numbers by status: "assessed" = reached HHA complete (billable unless later marked not eligible)
create or replace function public.hhgp_month_stats(tok text, p_month date) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; a timestamptz; b timestamptz;
begin
  m := public.team_need();
  a := date_trunc('month', p_month)::timestamptz; b := (date_trunc('month', p_month) + interval '1 month')::timestamptz;
  return jsonb_build_object(
    'inq', (select count(*) from public.hhgp_homes where created_at >= a and created_at < b),
    'asmt', (select count(distinct e.home_id) from public.hhgp_events e join public.hhgp_homes h on h.id = e.home_id
             where e.at >= a and e.at < b and e.what like 'Moved to assessed%' and h.stage <> 'noteligible'),
    'fwd', (select count(distinct home_id) from public.hhgp_events where at >= a and at < b and what like 'Moved to reservation%'),
    'done', (select count(*) from public.hhgp_homes where paid_on >= a::date and paid_on < b::date),
    'usd', (select coalesce(sum(paid_amt),0) from public.hhgp_homes where paid_on >= a::date and paid_on < b::date),
    'open', (select count(*) from public.hhgp_homes where not archived and stage in ('intake','assessment','assessed','reservation','work','closeout'))
  );
end; $fn$;

revoke all on function public.hhgp_stage_ok(text) from public, anon;
revoke all on function public.hhgp_list(text) from public, anon;
revoke all on function public.hhgp_save(text, jsonb) from public, anon;
revoke all on function public.hhgp_month_stats(text, date) from public, anon;
grant execute on function public.hhgp_list(text) to authenticated;
grant execute on function public.hhgp_save(text, jsonb) to authenticated;
grant execute on function public.hhgp_month_stats(text, date) to authenticated;
