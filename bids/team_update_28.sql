-- team_update_28: the tracker sync signs in as one staff member (read-only) instead of needing admin approval.
-- An admin clicks "Connect Microsoft" on the Program pulse board, signs in once, and the sync keeps that
-- sign-in fresh. If the sign-in stops working (password change, account turned off), the cards say the
-- numbers are paused and an admin connects again. Tokens are kept in tracker_config, which no one can read
-- from the website. Microsoft app Redirect URI (Web):
--   https://uptrzajrneoarbchmbkp.supabase.co/functions/v1/tracker-sync/callback

alter table public.tracker_config
  add column if not exists ms_refresh_token text,
  add column if not exists ms_access_token text,
  add column if not exists ms_access_expires timestamptz,
  add column if not exists ms_account text,
  add column if not exists ms_connected_at timestamptz,
  add column if not exists login_code text,
  add column if not exists login_until timestamptz;

grant execute on function public.tracker_kick() to service_role;

create or replace function public.tracker_connect_link(tok text) returns text
language plpgsql security definer set search_path = public, extensions as $fn$
declare m public.team_member; c text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  m := public.team_need();
  if not m.is_admin then raise exception 'Only an admin can connect the trackers.'; end if;
  update public.tracker_config set login_code = c, login_until = now() + interval '30 minutes' where id = 1;
  return 'https://uptrzajrneoarbchmbkp.supabase.co/functions/v1/tracker-sync/login?c=' || c;
end; $fn$;
revoke all on function public.tracker_connect_link(text) from public, anon;
grant execute on function public.tracker_connect_link(text) to authenticated;
