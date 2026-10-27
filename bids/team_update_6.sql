-- =====================================================================
-- Latino Built Team Playbook: update 6 (HHGP pipeline). Safe to run again.
-- Run AFTER team_update_5.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- A shared board of HHGP homes: where each one stands from intake to paid.
-- Holds only the address, city and the client's first name. Income, phone and
-- full details stay in the HHGP Tracker. Every change is logged with who and when.
-- =====================================================================

create table if not exists public.hhgp_homes (
  id             uuid primary key default gen_random_uuid(),
  address        text not null,
  city           text,
  first_name     text,
  stage          text not null default 'intake'
                 check (stage in ('intake','assessment','reservation','work','closeout','paid','hold')),
  owner          text,
  checks         jsonb not null default '[]'::jsonb,
  reservation_no text,
  reserved_amt   numeric,
  paid_amt       numeric,
  certa          boolean not null default false,
  next_step      text,
  notes          text,
  stage_at       timestamptz not null default now(),
  paid_on        date,
  archived       boolean not null default false,
  created_by     text not null,
  created_at     timestamptz not null default now(),
  updated_by     text,
  updated_at     timestamptz not null default now()
);
create table if not exists public.hhgp_events (
  id       bigint generated always as identity primary key,
  home_id  uuid not null references public.hhgp_homes(id) on delete cascade,
  at       timestamptz not null default now(),
  who      text not null,
  what     text not null,
  stage    text
);
create index if not exists hhgp_events_home_idx on public.hhgp_events(home_id, at desc);
alter table public.hhgp_homes enable row level security;
alter table public.hhgp_events enable row level security;
revoke all on public.hhgp_homes, public.hhgp_events from anon, authenticated;

-- The board
create or replace function public.hhgp_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'homes', coalesce((select jsonb_agg(to_jsonb(h) order by h.stage_at) from public.hhgp_homes h
                       where not h.archived and (h.stage <> 'paid' or h.paid_on is null or h.paid_on > current_date - 60)), '[]'::jsonb)
  );
end; $fn$;

-- One home with its history
create or replace function public.hhgp_get(tok text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'home', (select to_jsonb(h) from public.hhgp_homes h where h.id = p_id),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.at desc) from (select * from public.hhgp_events where home_id = p_id order by at desc limit 60) e), '[]'::jsonb)
  );
end; $fn$;

-- Add or update a home. Logs what changed.
create or replace function public.hhgp_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; old public.hhgp_homes; v_stage text; v_owner text; v_what text := '';
begin
  m := public.team_need();
  if coalesce(trim(p->>'address'),'') = '' then raise exception 'Add the home address.'; end if;
  v_owner := nullif(trim(coalesce(p->>'owner','')),'');
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then
    raise exception 'That person is not on the team list.'; end if;
  v_stage := coalesce(nullif(p->>'stage',''),'intake');
  if v_stage not in ('intake','assessment','reservation','work','closeout','paid','hold') then raise exception 'Unknown stage.'; end if;

  if v_id is null then
    insert into public.hhgp_homes(address, city, first_name, stage, owner, reservation_no, reserved_amt, paid_amt, certa, next_step, notes,
                                  paid_on, created_by, updated_by)
    values (left(trim(p->>'address'),200), left(p->>'city',80), left(p->>'first_name',60), v_stage, v_owner,
            left(p->>'reservation_no',60), nullif(p->>'reserved_amt','')::numeric, nullif(p->>'paid_amt','')::numeric,
            coalesce((p->>'certa')::boolean,false), left(p->>'next_step',300), left(p->>'notes',4000),
            case when v_stage = 'paid' then current_date end, m.name, m.name)
    returning id into v_id;
    insert into public.hhgp_events(home_id, who, what, stage) values (v_id, m.name, 'Added to the pipeline', v_stage);
  else
    select * into old from public.hhgp_homes where id = v_id;
    if old.id is null then raise exception 'That home is gone. Refresh the board.'; end if;
    if old.stage is distinct from v_stage then v_what := v_what || 'Moved to ' || v_stage || '. '; end if;
    if old.owner is distinct from v_owner then v_what := v_what || 'Owner: ' || coalesce(v_owner,'nobody') || '. '; end if;
    if old.reservation_no is distinct from nullif(p->>'reservation_no','') then v_what := v_what || 'Reservation # updated. '; end if;
    if old.reserved_amt is distinct from nullif(p->>'reserved_amt','')::numeric then v_what := v_what || 'Reserved amount updated. '; end if;
    if old.paid_amt is distinct from nullif(p->>'paid_amt','')::numeric then v_what := v_what || 'Paid amount updated. '; end if;
    if old.next_step is distinct from nullif(p->>'next_step','') then v_what := v_what || 'Next step updated. '; end if;
    update public.hhgp_homes set address = left(trim(p->>'address'),200), city = left(p->>'city',80), first_name = left(p->>'first_name',60),
      stage = v_stage, owner = v_owner, reservation_no = nullif(left(p->>'reservation_no',60),''),
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

-- Check or uncheck one checklist item
create or replace function public.hhgp_check(tok text, p_id uuid, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v jsonb;
begin
  m := public.team_need();
  if p_key !~ '^[a-z0-9]{1,12}$' then raise exception 'Bad checklist item.'; end if;
  update public.hhgp_homes set
    checks = case when p_on then (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements_text(checks || to_jsonb(p_key)) x)
                  else (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(checks) x where x <> p_key) end,
    updated_by = m.name, updated_at = now()
  where id = p_id returning checks into v;
  if v is null then raise exception 'That home is gone. Refresh the board.'; end if;
  insert into public.hhgp_events(home_id, who, what) values (p_id, m.name, case when p_on then 'Checked: ' else 'Unchecked: ' end || p_key);
  return v;
end; $fn$;

-- Monthly report numbers now include HHGP pipeline counts
create or replace function public.hhgp_month_stats(tok text, p_month date) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; a timestamptz; b timestamptz;
begin
  m := public.team_need();
  a := date_trunc('month', p_month)::timestamptz; b := (date_trunc('month', p_month) + interval '1 month')::timestamptz;
  return jsonb_build_object(
    'inq', (select count(*) from public.hhgp_homes where created_at >= a and created_at < b),
    'asmt', (select count(distinct home_id) from public.hhgp_events where at >= a and at < b and what like 'Moved to reservation%'),
    'done', (select count(*) from public.hhgp_homes where paid_on >= a::date and paid_on < b::date),
    'usd', (select coalesce(sum(paid_amt),0) from public.hhgp_homes where paid_on >= a::date and paid_on < b::date),
    'open', (select count(*) from public.hhgp_homes where not archived and stage not in ('paid','hold'))
  );
end; $fn$;

revoke all on function public.hhgp_list(text) from public, anon;
revoke all on function public.hhgp_get(text, uuid) from public, anon;
revoke all on function public.hhgp_save(text, jsonb) from public, anon;
revoke all on function public.hhgp_check(text, uuid, text, boolean) from public, anon;
revoke all on function public.hhgp_month_stats(text, date) from public, anon;
grant execute on function public.hhgp_list(text) to authenticated;
grant execute on function public.hhgp_get(text, uuid) to authenticated;
grant execute on function public.hhgp_save(text, jsonb) to authenticated;
grant execute on function public.hhgp_check(text, uuid, text, boolean) to authenticated;
grant execute on function public.hhgp_month_stats(text, date) to authenticated;
