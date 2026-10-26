-- =====================================================================
-- Latino Built Bid Board: update 3 (new-job alerts sign-up). Safe to run again.
-- Run AFTER bid_board_update_2.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- Contractors sign up on the bid page to hear about new jobs by text and/or
-- email, in Spanish or English, for the trades and areas they work in.
-- Each contractor gets a private link to change or stop their alerts.
-- Only staff can see the sign-up list.
-- =====================================================================


-- ---------- Sign-ups ----------
create table if not exists public.bid_alert_subs (
  id         uuid primary key default gen_random_uuid(),
  token      uuid not null unique default gen_random_uuid(),   -- contractor's private manage link
  name       text,
  company    text not null,
  phone      text,
  email      text,
  ccb        text,
  lang       text not null default 'es' check (lang in ('es','en')),
  by_text    boolean not null default false,
  by_email   boolean not null default false,
  trades     text[] not null default '{}',   -- empty = all trades
  areas      text[] not null default '{}',   -- empty = all areas
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists bid_alert_subs_touch on public.bid_alert_subs;
create trigger bid_alert_subs_touch before update on public.bid_alert_subs
  for each row execute function public.bid_touch();

alter table public.bid_alert_subs enable row level security;
drop policy if exists "staff manage alert sign-ups" on public.bid_alert_subs;
create policy "staff manage alert sign-ups" on public.bid_alert_subs for all to authenticated
  using (public.is_bid_staff()) with check (public.is_bid_staff());
revoke all on public.bid_alert_subs from anon;
grant select, insert, update, delete on public.bid_alert_subs to authenticated;

-- Jobs can be tagged with trades and an area so alerts only go to the right people.
-- Jobs with no tags go to everyone who signed up.
alter table public.bid_jobs add column if not exists trades text[] not null default '{}';
alter table public.bid_jobs add column if not exists area text;


-- ---------- The choices (kept in one place so the page and database agree) ----------
create or replace function public.bid_alert_choices() returns jsonb
language sql immutable as $fn$
  select jsonb_build_object(
    'trades', jsonb_build_array('general','roofing','hvac','insulation','windows','plumbing','electrical','accessibility','siding'),
    'areas',  jsonb_build_array('portland','sw_wa','valley','coast','other'));
$fn$;
grant execute on function public.bid_alert_choices() to anon, authenticated;


-- ---------- Contractor: sign up or change alerts ----------
create or replace function public.save_alerts(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  s public.bid_alert_subs;
  v_token  uuid := nullif(p->>'token','')::uuid;
  v_phone  text := left(trim(coalesce(p->>'phone','')), 40);
  v_email  text := lower(left(trim(coalesce(p->>'email','')), 160));
  v_text   boolean := coalesce((p->>'by_text')::boolean, false);
  v_mail   boolean := coalesce((p->>'by_email')::boolean, false);
  v_trades text[];
  v_areas  text[];
  v_recent int;
  c jsonb := public.bid_alert_choices();
begin
  if coalesce(trim(p->>'company'),'') = '' then raise exception 'Company name is required.'; end if;
  if not v_text and not v_mail then raise exception 'Choose text, email or both.'; end if;
  if v_text and length(regexp_replace(v_phone,'\D','','g')) < 10 then raise exception 'Enter a phone number for text alerts.'; end if;
  if v_mail and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter an email address for email alerts.'; end if;
  if not coalesce((p->>'consent')::boolean, false) then raise exception 'Please agree to receive alerts.'; end if;

  -- Only keep choices we know about
  select coalesce(array_agg(x), '{}') into v_trades
    from jsonb_array_elements_text(case when jsonb_typeof(p->'trades') = 'array' then p->'trades' else '[]'::jsonb end) x
    where c->'trades' ? x;
  select coalesce(array_agg(x), '{}') into v_areas
    from jsonb_array_elements_text(case when jsonb_typeof(p->'areas') = 'array' then p->'areas' else '[]'::jsonb end) x
    where c->'areas' ? x;

  if v_token is not null then
    update public.bid_alert_subs set
      name = left(p->>'name',120), company = left(p->>'company',120),
      phone = nullif(v_phone,''), email = nullif(v_email,''), ccb = left(p->>'ccb',40),
      lang = case when p->>'lang' = 'en' then 'en' else 'es' end,
      by_text = v_text, by_email = v_mail, trades = v_trades, areas = v_areas, active = true
    where token = v_token
    returning * into s;
    if s.id is null then raise exception 'We could not find those alerts. Sign up again.'; end if;
  else
    -- Basic spam guards
    select count(*) into v_recent from public.bid_alert_subs where created_at > now() - interval '1 hour';
    if v_recent >= 60 then raise exception 'Too many sign-ups right now. Please try again later.'; end if;
    select count(*) into v_recent from public.bid_alert_subs
      where (v_phone <> '' and regexp_replace(phone,'\D','','g') = regexp_replace(v_phone,'\D','','g'))
         or (v_email <> '' and email = v_email);
    if v_recent >= 3 then raise exception 'You are already signed up. Use your alerts link to make changes.'; end if;

    insert into public.bid_alert_subs(name, company, phone, email, ccb, lang, by_text, by_email, trades, areas)
    values (left(p->>'name',120), left(p->>'company',120), nullif(v_phone,''), nullif(v_email,''), left(p->>'ccb',40),
            case when p->>'lang' = 'en' then 'en' else 'es' end, v_text, v_mail, v_trades, v_areas)
    returning * into s;
  end if;

  return jsonb_build_object('token', s.token);
end; $fn$;

-- ---------- Contractor: see alerts with the private link ----------
create or replace function public.get_alerts(t uuid) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object('name', name, 'company', company, 'phone', phone, 'email', email, 'ccb', ccb,
    'lang', lang, 'by_text', by_text, 'by_email', by_email, 'trades', trades, 'areas', areas, 'active', active)
  from public.bid_alert_subs where token = t;
$fn$;

-- ---------- Contractor: stop alerts ----------
create or replace function public.stop_alerts(t uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
begin
  update public.bid_alert_subs set active = false where token = t and active;
  return found;
end; $fn$;

-- ---------- Staff: who should hear about a job ----------
-- Matches trades and area. A sign-up with no trades or areas picked gets everything,
-- and so does a job with no trades or area set.
create or replace function public.bid_alert_recipients(job uuid) returns table (
  name text, company text, phone text, email text, lang text, by_text boolean, by_email boolean)
language plpgsql stable security definer set search_path = public as $fn$
declare j public.bid_jobs;
begin
  if not public.is_bid_staff() then raise exception 'Staff only.'; end if;
  select * into j from public.bid_jobs where id = job;
  if j.id is null then return; end if;
  return query
    select s.name, s.company, s.phone, s.email, s.lang, s.by_text, s.by_email
    from public.bid_alert_subs s
    where s.active
      and (cardinality(s.trades) = 0 or cardinality(j.trades) = 0 or s.trades && j.trades)
      and (cardinality(s.areas) = 0 or j.area is null or j.area = any(s.areas))
    order by s.company;
end; $fn$;

revoke all on function public.save_alerts(jsonb) from public;
revoke all on function public.get_alerts(uuid) from public;
revoke all on function public.stop_alerts(uuid) from public;
revoke all on function public.bid_alert_recipients(uuid) from public, anon;
grant execute on function public.save_alerts(jsonb) to anon, authenticated;
grant execute on function public.get_alerts(uuid)   to anon, authenticated;
grant execute on function public.stop_alerts(uuid)  to anon, authenticated;
grant execute on function public.bid_alert_recipients(uuid) to authenticated;
