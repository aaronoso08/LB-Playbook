-- team_update_27: Live numbers from the Excel trackers on the Program pulse cards.
-- Every 10 minutes Supabase runs the "tracker-sync" function. It signs in to Microsoft 365 with a
-- read-only app ("LB Playbook Tracker Sync"), downloads each tracker, counts, and saves ONLY the counts
-- here. No client names, addresses or phone numbers are saved. The Excel files are never changed.
-- Staff see the numbers on the Home page and the Program pulse board, with "checked X min ago".
-- Needs: the function's Microsoft keys (MS_CLIENT_ID, MS_CLIENT_SECRET) set in Supabase > Edge Functions > Secrets.
-- Note: if an older update file that redefines pulse_auto() is run again, run this file again after it.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------- Which trackers to read ----------
-- location:  user:<their work email>:/<folder>/<file>.xlsx         (a file in someone's OneDrive)
--            site:<host>:/sites/<site>:/<folder>/<file>.xlsx      (a file in a SharePoint site's Documents)
-- If the file was moved, the function looks it up by name in the same OneDrive or site and notes the new folder.
create table if not exists public.tracker_sources (
  key            text primary key,
  label          text not null,
  card           text not null,                 -- Program pulse card the numbers show on
  kind           text not null check (kind in ('hhgp','referrals')),
  location       text not null,
  active         boolean not null default true,
  numbers        jsonb not null default '[]'::jsonb,
  alerts         jsonb not null default '[]'::jsonb,
  detail         jsonb not null default '{}'::jsonb,  -- sheet, heading row, columns found, rows counted
  ok             boolean,
  message        text,
  file_etag      text,
  file_edited_at timestamptz,
  computed_on    date,
  synced_at      timestamptz,
  created_at     timestamptz not null default now()
);
alter table public.tracker_sources enable row level security;
revoke all on public.tracker_sources from anon, authenticated;

create table if not exists public.tracker_config (
  id         int primary key default 1 check (id = 1),
  sync_token text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  last_kick  timestamptz
);
alter table public.tracker_config enable row level security;
revoke all on public.tracker_config from anon, authenticated;
insert into public.tracker_config(id) values (1) on conflict (id) do nothing;

insert into public.tracker_sources(key, label, card, kind, location) values
  ('hhgp', 'HHGP Tracker', 'hhgp', 'hhgp', 'user:aaron@latinobuilt.org:/HHGP/HHGP_Tracker.xlsx'),
  ('referrals', 'Referral Tracker', 'referrals', 'referrals',
   'site:latinobuilt100.sharepoint.com:/sites/LatinoBuilt:/1. LatinoBuilt Association/Programs & Services/Green_Programs_Referral_Tracker.xlsx')
on conflict (key) do nothing;

-- A Program pulse card for referrals (same owner as the HHGP card)
insert into public.pulse_cards(key, title, owner, sort)
select 'referrals', 'Green Programs Referrals', (select owner from public.pulse_cards where key = 'hhgp'), 15
on conflict (key) do nothing;

-- ---------- Merge tracker numbers into the automatic pulse numbers ----------
do $do$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'pulse_auto_core') then
    alter function public.pulse_auto() rename to pulse_auto_core;
  end if;
end $do$;

create or replace function public.pulse_auto() returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare r jsonb := coalesce(public.pulse_auto_core(), '{}'::jsonb); s record; feed jsonb := '{}'::jsonb;
begin
  for s in select * from public.tracker_sources where active order by key loop
    -- last good numbers stay up even if a check fails; the card then says the numbers are paused
    if jsonb_typeof(s.numbers) = 'array' and jsonb_array_length(s.numbers) > 0 then
      r := r || jsonb_build_object(s.card, s.numbers || coalesce(r -> s.card, '[]'::jsonb));
    end if;
    if s.synced_at is not null then
      feed := feed || jsonb_build_object(s.card, jsonb_build_object(
        'label', s.label, 'ok', s.ok, 'message', s.message, 'alerts', s.alerts,
        'synced_at', s.synced_at, 'edited_at', s.file_edited_at));
    end if;
  end loop;
  return r || jsonb_build_object('_feed', feed);
end; $fn$;
revoke all on function public.pulse_auto() from public, anon, authenticated;
revoke all on function public.pulse_auto_core() from public, anon, authenticated;

-- ---------- Run the sync ----------
-- One call per tracker, so each file gets the function's full time limit.
create or replace function public.tracker_kick() returns int
language plpgsql security definer set search_path = public, extensions as $fn$
declare s record; n int := 0; t text := (select sync_token from public.tracker_config where id = 1);
begin
  for s in select key from public.tracker_sources where active loop
    perform net.http_post(
      url := 'https://uptrzajrneoarbchmbkp.supabase.co/functions/v1/tracker-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', t),
      body := jsonb_build_object('key', s.key),
      timeout_milliseconds := 120000);
    n := n + 1;
  end loop;
  update public.tracker_config set last_kick = now() where id = 1;
  return n;
end; $fn$;
revoke all on function public.tracker_kick() from public, anon, authenticated;

-- "Check the trackers now" button for signed-in staff (at most once a minute)
create or replace function public.tracker_sync_now(tok text) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if exists (select 1 from public.tracker_config where id = 1 and last_kick > now() - interval '1 minute') then
    return false;
  end if;
  perform public.tracker_kick();
  return true;
end; $fn$;
revoke all on function public.tracker_sync_now(text) from public, anon;
grant execute on function public.tracker_sync_now(text) to authenticated;

-- Every 10 minutes
select cron.schedule('tracker-sync', '*/10 * * * *', $$select public.tracker_kick()$$);
