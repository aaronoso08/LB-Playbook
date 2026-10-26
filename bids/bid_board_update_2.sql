-- =====================================================================
-- Latino Built Bid Board: update 2 (checkup fixes). Safe to run again.
-- Run AFTER bid_board_setup.sql, bid_board_update_1.sql and team_update_3.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- What it does:
--   1. One staff list. The bid board now uses the same staff list as the
--      Playbook logins (team_member). The old bid_staff list is kept as an
--      automatic copy so nothing that reads it breaks.
--   2. Changing an award. Awarding a different bid on the same job now sets
--      the earlier winner to "not selected". Withdrawn bids can't be awarded.
--   3. File uploads. Only allowed on open jobs before the deadline, only with
--      the file names the bid page makes, and capped per job so the storage
--      can't be flooded.
--   4. Expired jobs. A new close_expired_bid_jobs() function marks open jobs
--      past their deadline as "closed". The daily keep-awake job calls it.
--      Bids on closed jobs are untouched and can still be reviewed and awarded.
-- =====================================================================


-- ---------- Safety check: don't lock anyone out ----------
-- Every email on the old bid list must also be an active Playbook login,
-- otherwise they would lose bid board access. If this stops, add them to
-- team_member first (through your private staff file), then run this again.
do $chk$
declare missing text;
begin
  select string_agg(b.email, ', ') into missing
  from public.bid_staff b
  where not exists (select 1 from public.team_member m
                    where m.active and lower(m.email) = lower(b.email));
  if missing is not null then
    raise exception 'Stopped, nothing changed. These bid board emails are not active Playbook logins yet: %', missing;
  end if;
end $chk$;


-- ---------- 1. One staff list ----------
create or replace function public.is_bid_staff() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from public.team_member
    where active and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$fn$;

-- Keep bid_staff as an automatic copy of the active Playbook logins
create or replace function public.team_member_sync_bid_staff() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  if tg_op in ('UPDATE','DELETE') then
    delete from public.bid_staff where lower(email) = lower(old.email);
  end if;
  if tg_op in ('INSERT','UPDATE') and new.active then
    insert into public.bid_staff(email) values (lower(new.email)) on conflict do nothing;
  end if;
  return null;
end; $fn$;

drop trigger if exists team_member_sync_bid_staff on public.team_member;
create trigger team_member_sync_bid_staff
  after insert or update or delete on public.team_member
  for each row execute function public.team_member_sync_bid_staff();

-- Bring the copy up to date right now
delete from public.bid_staff b
  where not exists (select 1 from public.team_member m where m.active and lower(m.email) = lower(b.email));
insert into public.bid_staff(email)
  select lower(email) from public.team_member where active
  on conflict do nothing;


-- ---------- 2. Changing an award ----------
create or replace function public.award_bid(bid uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare v_job uuid; v_status text;
begin
  if not public.is_bid_staff() then raise exception 'Staff only.'; end if;
  select job_id, status into v_job, v_status from public.bid_submissions where id = bid;
  if v_job is null then return false; end if;
  if v_status = 'withdrawn' then raise exception 'That bid was withdrawn by the contractor.'; end if;
  update public.bid_submissions set status = 'not_selected'
    where job_id = v_job and id <> bid and status in ('submitted','reviewing','awarded');
  update public.bid_submissions set status = 'awarded' where id = bid;
  update public.bid_jobs set status = 'awarded' where id = v_job;
  return true;
end; $fn$;
revoke all on function public.award_bid(uuid) from public, anon;
grant execute on function public.award_bid(uuid) to authenticated;


-- ---------- 3. File uploads ----------
-- Checks a new upload: job is open, deadline not passed, file name looks like
-- the ones the bid page makes, and the job hasn't hit its upload cap.
create or replace function public.bid_upload_ok(p_name text) returns boolean
language plpgsql stable security definer set search_path = public, storage as $fn$
declare v_job uuid; v_total int; v_hour int;
begin
  if p_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{10,16}-[a-z0-9]{1,12}\.[a-z0-9]{1,5}$' then
    return false;
  end if;
  v_job := split_part(p_name, '/', 1)::uuid;
  if not exists (select 1 from public.bid_jobs where id = v_job and status = 'open' and due_at > now()) then
    return false;
  end if;
  select count(*), count(*) filter (where created_at > now() - interval '1 hour')
    into v_total, v_hour
    from storage.objects where bucket_id = 'bid-files' and name like v_job::text || '/%';
  return v_total < 200 and v_hour < 30;
end; $fn$;
revoke all on function public.bid_upload_ok(text) from public;
grant execute on function public.bid_upload_ok(text) to anon, authenticated;

drop policy if exists "contractors upload bid files" on storage.objects;
create policy "contractors upload bid files" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'bid-files' and public.bid_upload_ok(name));

-- A bid can only point to a file in its own job's folder
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
  v_file text;
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

  v_file := nullif(p->>'file_path','');
  if v_file is not null and (left(v_file, 37) <> j.id::text || '/' or length(v_file) > 120) then
    v_file := null;
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
      file_path = coalesce(v_file, file_path),
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
       left(p->>'warranty',300), left(p->>'notes',4000), v_file)
    returning * into b;
  end if;

  return jsonb_build_object('token', b.token, 'total', b.total);
end; $fn$;
revoke all on function public.submit_bid(jsonb) from public;
grant execute on function public.submit_bid(jsonb) to anon, authenticated;


-- ---------- 4. Close expired jobs ----------
-- Safe for anyone to call: it only closes open jobs whose deadline has passed.
create or replace function public.close_expired_bid_jobs() returns int
language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  update public.bid_jobs set status = 'closed' where status = 'open' and due_at < now();
  get diagnostics n = row_count;
  return n;
end; $fn$;
revoke all on function public.close_expired_bid_jobs() from public;
grant execute on function public.close_expired_bid_jobs() to anon, authenticated;

-- Close any that are already past due
select public.close_expired_bid_jobs() as jobs_closed_now;
