-- team_update_19: HHGP pipeline is need-to-know. Homeowner first names and addresses only for the
-- green programs team (Home Energy Assessor, Community Energy Navigator, Green Program Manager,
-- Program Director, Executive Director) and admins. Everyone else sees city and stage only.
-- Only the green programs team can add or change homes. Applied in Supabase on 2026-10-30.
create or replace function public.hhgp_can_see(m public.team_member) returns boolean
language sql stable set search_path=public as $$
  select coalesce(m.is_admin,false) or m.role_id in ('hea','nav','gpm','pd','ed');
$$;
revoke all on function public.hhgp_can_see(public.team_member) from public, anon, authenticated;
create or replace function public.hhgp_mask(h public.hhgp_homes, see boolean) returns jsonb
language sql stable set search_path=public as $$
  select case when see then to_jsonb(h)
    else to_jsonb(h) || jsonb_build_object('first_name','Homeowner','address',coalesce(nullif(h.city,''),'Oregon'),'city',null,'reservation_no',null,'notes',null) end;
$$;
revoke all on function public.hhgp_mask(public.hhgp_homes, boolean) from public, anon, authenticated;
-- hhgp_list and hhgp_get return hhgp_mask(h, see) and a 'limited' flag; a trigger (hhgp_guard)
-- blocks inserts, updates and deletes from staff outside the green programs team.
-- See the Supabase migration "team_update_19_hhgp_need_to_know" for the full function bodies.
