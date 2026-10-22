-- =====================================================================
-- Latino Built Bid Board: database setup
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to run again later (it updates instead of duplicating).
-- =====================================================================


-- ---------- Staff list: only these emails can see bids ----------
create table if not exists public.bid_staff (
  email text primary key
);
insert into public.bid_staff(email) values ('aaron@latinobuilt.org') on conflict do nothing;
-- Add teammates like this (one line each), then run again:
-- insert into public.bid_staff(email) values ('name@latinobuilt.org') on conflict do nothing;

create or replace function public.is_bid_staff() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from public.bid_staff
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$fn$;

-- ---------- Jobs (public part: no client name or street address) ----------
create table if not exists public.bid_jobs (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null default upper(substr(md5(random()::text), 1, 6)),
  title       text not null,
  city        text,
  zip         text,
  home_type   text,
  program     text,
  scope       jsonb not null default '[]'::jsonb,   -- [{name, qty, unit, note}]
  details     text,                                  -- public notes for contractors
  walkthrough text,                                  -- walkthrough date / how to schedule
  due_at      timestamptz not null,
  status      text not null default 'open' check (status in ('draft','open','closed','awarded')),
  created_by  text default (auth.jwt() ->> 'email'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- Jobs (private part: staff only) ----------
create table if not exists public.bid_job_private (
  job_id         uuid primary key references public.bid_jobs(id) on delete cascade,
  address        text,
  client_name    text,
  estimate_total numeric,
  internal_notes text
);

-- ---------- Bids ----------
create table if not exists public.bid_submissions (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references public.bid_jobs(id) on delete cascade,
  token         uuid not null unique default gen_random_uuid(),  -- contractor's private receipt link
  company       text not null,
  contact_name  text,
  phone         text not null,
  email         text,
  ccb           text not null,
  lang          text not null default 'es',
  items         jsonb not null default '[]'::jsonb,   -- [{name, price}]
  total         numeric not null check (total >= 0),
  start_date    date,
  duration_days int check (duration_days is null or duration_days between 0 and 365),
  warranty      text,
  notes         text,
  file_path     text,
  status        text not null default 'submitted'
                check (status in ('submitted','reviewing','awarded','not_selected','withdrawn')),
  staff_note    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists bid_submissions_job_idx on public.bid_submissions(job_id);

-- ---------- Keep updated_at current ----------
create or replace function public.bid_touch() returns trigger language plpgsql as $fn$
begin new.updated_at = now(); return new; end; $fn$;
drop trigger if exists bid_jobs_touch on public.bid_jobs;
create trigger bid_jobs_touch before update on public.bid_jobs for each row execute function public.bid_touch();
drop trigger if exists bid_submissions_touch on public.bid_submissions;
create trigger bid_submissions_touch before update on public.bid_submissions for each row execute function public.bid_touch();

-- ---------- Security rules ----------
alter table public.bid_staff       enable row level security;
alter table public.bid_jobs        enable row level security;
alter table public.bid_job_private enable row level security;
alter table public.bid_submissions enable row level security;

drop policy if exists "staff see staff list" on public.bid_staff;
create policy "staff see staff list" on public.bid_staff for select to authenticated using (public.is_bid_staff());

drop policy if exists "anyone sees open jobs" on public.bid_jobs;
create policy "anyone sees open jobs" on public.bid_jobs for select to anon, authenticated using (status = 'open');

drop policy if exists "staff manage jobs" on public.bid_jobs;
create policy "staff manage jobs" on public.bid_jobs for all to authenticated
  using (public.is_bid_staff()) with check (public.is_bid_staff());

drop policy if exists "staff manage private job info" on public.bid_job_private;
create policy "staff manage private job info" on public.bid_job_private for all to authenticated
  using (public.is_bid_staff()) with check (public.is_bid_staff());

drop policy if exists "staff manage bids" on public.bid_submissions;
create policy "staff manage bids" on public.bid_submissions for all to authenticated
  using (public.is_bid_staff()) with check (public.is_bid_staff());
-- Contractors never read or write bid_submissions directly. They use the functions below.

-- ---------- Table access (works with "Automatically expose new tables" on or off) ----------
grant usage on schema public to anon, authenticated;
revoke all on public.bid_staff, public.bid_jobs, public.bid_job_private, public.bid_submissions from anon;
grant select on public.bid_jobs to anon;
grant select on public.bid_staff to authenticated;
grant select, insert, update, delete on public.bid_jobs, public.bid_job_private, public.bid_submissions to authenticated;

-- ---------- Contractor: submit or update a bid ----------
create or replace function public.submit_bid(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  j public.bid_jobs;
  b public.bid_submissions;
  v_items jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_item jsonb;
  v_token uuid;
  v_recent int;
begin
  select * into j from public.bid_jobs where id = (p->>'job_id')::uuid;
  if j.id is null or j.status <> 'open' then raise exception 'This job is not taking bids.'; end if;
  if j.due_at < now() then raise exception 'The bid deadline has passed.'; end if;

  if coalesce(trim(p->>'company'),'') = '' or coalesce(trim(p->>'phone'),'') = '' or coalesce(trim(p->>'ccb'),'') = '' then
    raise exception 'Company, phone and CCB number are required.';
  end if;
  if length(p->>'company') > 120 or length(coalesce(p->>'notes','')) > 4000 then
    raise exception 'Some answers are too long.';
  end if;

  -- Clean the line items and add them up on the server
  if jsonb_typeof(p->'items') = 'array' then
    if jsonb_array_length(p->'items') > 150 then raise exception 'Too many line items.'; end if;
    for v_item in select * from jsonb_array_elements(p->'items') loop
      if coalesce((v_item->>'price'),'') similar to '[0-9]+(.[0-9]{1,2})?' then
        v_items := v_items || jsonb_build_object('name', left(v_item->>'name', 200), 'price', (v_item->>'price')::numeric);
        v_total := v_total + (v_item->>'price')::numeric;
      end if;
    end loop;
  end if;
  if jsonb_array_length(v_items) = 0 then
    if coalesce(p->>'total','') not similar to '[0-9]+(.[0-9]{1,2})?' then raise exception 'Please enter a price.'; end if;
    v_total := (p->>'total')::numeric;
  end if;
  if v_total <= 0 or v_total > 10000000 then raise exception 'Please check the total price.'; end if;

  v_token := nullif(p->>'token','')::uuid;
  if v_token is not null then
    -- Update an existing bid (only before the deadline, only if not already decided)
    update public.bid_submissions set
      company = left(p->>'company',120), contact_name = left(p->>'contact_name',120),
      phone = left(p->>'phone',40), email = left(p->>'email',160), ccb = left(p->>'ccb',40),
      lang = case when p->>'lang' = 'en' then 'en' else 'es' end,
      items = v_items, total = v_total,
      start_date = nullif(p->>'start_date','')::date,
      duration_days = nullif(p->>'duration_days','')::int,
      warranty = left(p->>'warranty',300), notes = left(p->>'notes',4000),
      file_path = coalesce(nullif(p->>'file_path',''), file_path),
      status = 'submitted'
    where token = v_token and job_id = j.id and status in ('submitted','reviewing','withdrawn')
    returning * into b;
    if b.id is null then raise exception 'That bid can no longer be changed.'; end if;
  else
    -- Basic spam guard: at most 5 bids per phone number per job
    select count(*) into v_recent from public.bid_submissions
      where job_id = j.id and regexp_replace(phone,'\D','','g') = regexp_replace(p->>'phone','\D','','g');
    if v_recent >= 5 then raise exception 'You already sent bids for this job. Use your receipt link to change one.'; end if;

    insert into public.bid_submissions
      (job_id, company, contact_name, phone, email, ccb, lang, items, total, start_date, duration_days, warranty, notes, file_path)
    values
      (j.id, left(p->>'company',120), left(p->>'contact_name',120), left(p->>'phone',40), left(p->>'email',160),
       left(p->>'ccb',40), case when p->>'lang' = 'en' then 'en' else 'es' end, v_items, v_total,
       nullif(p->>'start_date','')::date, nullif(p->>'duration_days','')::int,
       left(p->>'warranty',300), left(p->>'notes',4000), nullif(p->>'file_path',''))
    returning * into b;
  end if;

  return jsonb_build_object('token', b.token, 'total', b.total);
end; $fn$;

-- ---------- Contractor: check a bid with the receipt link ----------
create or replace function public.get_bid(t uuid) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object(
    'job_id', j.id, 'code', j.code, 'title', j.title, 'city', j.city, 'scope', j.scope,
    'due_at', j.due_at, 'job_status', j.status,
    'company', b.company, 'contact_name', b.contact_name, 'phone', b.phone, 'email', b.email, 'ccb', b.ccb,
    'items', b.items, 'total', b.total, 'start_date', b.start_date, 'duration_days', b.duration_days,
    'warranty', b.warranty, 'notes', b.notes, 'status', b.status, 'lang', b.lang,
    'created_at', b.created_at, 'updated_at', b.updated_at,
    'has_file', b.file_path is not null)
  from public.bid_submissions b join public.bid_jobs j on j.id = b.job_id
  where b.token = t;
$fn$;

-- ---------- Contractor: withdraw a bid ----------
create or replace function public.withdraw_bid(t uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
begin
  update public.bid_submissions set status = 'withdrawn'
  where token = t and status in ('submitted','reviewing');
  return found;
end; $fn$;

-- ---------- Staff: award a bid (everyone else on that job gets "not selected") ----------
create or replace function public.award_bid(bid uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare v_job uuid;
begin
  if not public.is_bid_staff() then raise exception 'Staff only.'; end if;
  select job_id into v_job from public.bid_submissions where id = bid;
  if v_job is null then return false; end if;
  update public.bid_submissions set status = 'not_selected'
    where job_id = v_job and id <> bid and status in ('submitted','reviewing');
  update public.bid_submissions set status = 'awarded' where id = bid;
  update public.bid_jobs set status = 'awarded' where id = v_job;
  return true;
end; $fn$;

revoke all on function public.submit_bid(jsonb) from public;
revoke all on function public.get_bid(uuid) from public;
revoke all on function public.withdraw_bid(uuid) from public;
revoke all on function public.award_bid(uuid) from public;
grant execute on function public.submit_bid(jsonb) to anon, authenticated;
grant execute on function public.get_bid(uuid)     to anon, authenticated;
grant execute on function public.withdraw_bid(uuid) to anon, authenticated;
grant execute on function public.award_bid(uuid)   to authenticated;
grant execute on function public.is_bid_staff()    to anon, authenticated;

-- ---------- File uploads (bid PDFs and photos, 10 MB max) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bid-files', 'bid-files', false, 10485760,
        array['application/pdf','image/jpeg','image/png','image/heic','image/webp'])
on conflict (id) do nothing;

drop policy if exists "contractors upload bid files" on storage.objects;
create policy "contractors upload bid files" on storage.objects for insert to anon, authenticated
  with check (
    bucket_id = 'bid-files'
    and exists (select 1 from public.bid_jobs j
                where j.id::text = (storage.foldername(name))[1] and j.status = 'open')
  );

drop policy if exists "staff read bid files" on storage.objects;
create policy "staff read bid files" on storage.objects for select to authenticated
  using (bucket_id = 'bid-files' and public.is_bid_staff());

-- ---------- Update 1: shared price list and job tracking ----------
alter table public.bid_job_private add column if not exists work_status text;
alter table public.bid_job_private add column if not exists completed_on date;
alter table public.bid_job_private add column if not exists final_amount numeric;
alter table public.bid_job_private add column if not exists work_notes text;

create table if not exists public.bid_settings (
  key text primary key,
  value jsonb not null default '[]'::jsonb,
  updated_by text default (auth.jwt() ->> 'email'),
  updated_at timestamptz not null default now()
);
alter table public.bid_settings enable row level security;
drop policy if exists "staff manage settings" on public.bid_settings;
create policy "staff manage settings" on public.bid_settings for all to authenticated
  using (public.is_bid_staff()) with check (public.is_bid_staff());
revoke all on public.bid_settings from anon;
grant select, insert, update, delete on public.bid_settings to authenticated;
