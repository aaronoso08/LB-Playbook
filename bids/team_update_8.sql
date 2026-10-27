-- =====================================================================
-- Latino Built Team Playbook: update 8 (admin password reset + live numbers). Safe to run again.
-- Run AFTER team_update_7.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- 1) Admins can set a temporary password for a teammate from inside the Playbook
--    (no more SQL for "I forgot my password"). Only people marked is_admin can do it,
--    only for active staff, and it never shows anyone's current password.
-- 2) hhgp_counts(): live counts for the Our numbers page, by status and program.
-- =====================================================================

create or replace function public.team_admin_people(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not m.is_admin then raise exception 'Only an admin can do this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email,
            'has_login', exists(select 1 from auth.users u where lower(u.email) = lower(t.email))) order by t.name)
          from public.team_member t where t.active), '[]'::jsonb);
end; $fn$;

create or replace function public.team_admin_set_password(tok text, p_email text, p_pw text) returns boolean
language plpgsql security definer set search_path = public, extensions as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not m.is_admin then raise exception 'Only an admin can do this.'; end if;
  if length(coalesce(p_pw,'')) < 8 then raise exception 'Use at least 8 characters.'; end if;
  if not exists (select 1 from public.team_member where active and lower(email) = lower(p_email)) then
    raise exception 'That email is not on the active staff list.'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_pw, extensions.gen_salt('bf')), updated_at = now()
   where lower(email) = lower(p_email);
  if not found then raise exception 'That person has no login yet.'; end if;
  return true;
end; $fn$;

-- Live numbers from the pipeline (all homes ever added, not just what's on the board)
create or replace function public.hhgp_counts(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'total', (select count(*) from public.hhgp_homes where not archived),
    'by_stage', coalesce((select jsonb_object_agg(stage, n) from (select stage, count(*) n from public.hhgp_homes where not archived group by stage) x), '{}'::jsonb),
    'fwd_hhgp', (select count(*) from public.hhgp_homes where not archived and program = 'HHGP' and stage in ('reservation','work','closeout','paid')),
    'fwd_pcef', (select count(*) from public.hhgp_homes where not archived and program = 'PCEF' and stage in ('reservation','work','closeout','paid')),
    'paid_total', (select coalesce(sum(paid_amt),0) from public.hhgp_homes where not archived and stage = 'paid'),
    'reserved_open', (select coalesce(sum(reserved_amt),0) from public.hhgp_homes where not archived and stage in ('reservation','work','closeout'))
  );
end; $fn$;

revoke all on function public.team_admin_people(text) from public, anon;
revoke all on function public.team_admin_set_password(text, text, text) from public, anon;
revoke all on function public.hhgp_counts(text) from public, anon;
grant execute on function public.team_admin_people(text) to authenticated;
grant execute on function public.team_admin_set_password(text, text, text) to authenticated;
grant execute on function public.hhgp_counts(text) to authenticated;
