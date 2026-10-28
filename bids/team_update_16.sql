-- =====================================================================
-- Latino Built Team Playbook: update 16 (Growth path: removed people stay removed). Safe to run again.
-- Run AFTER team_update_15.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- When someone is taken off the Growth path, "Bring in from Certifications"
-- no longer offers to add them back. They can still be added by hand.
-- Staff only, like everything else.
-- =====================================================================

create or replace function public.growth_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'persons', coalesce((select jsonb_agg(to_jsonb(g) || jsonb_build_object(
        'steps', coalesce((select jsonb_object_agg(s.step_key, jsonb_build_object('status', s.status, 'done_on', s.done_on, 'note', s.note, 'by', s.updated_by))
                           from public.growth_steps s where s.person_id = g.id), '{}'::jsonb),
        'certs', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'label', i.label, 'issued_on', i.issued_on, 'expires_on', i.expires_on, 'number', i.number))
                           from public.cert_items i where g.cert_id is not null and i.contractor_id = g.cert_id), '[]'::jsonb),
        'support', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'note', x.note, 'on_date', x.on_date, 'by', x.created_by)
                           order by x.on_date desc, x.created_at desc) from public.growth_support x where x.person_id = g.id), '[]'::jsonb))
        order by lower(g.name)) from public.growth_people g where g.active), '[]'::jsonb),
    'unlinked_certs', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'company', c.company, 'contact', c.contact, 'trade', c.trade, 'area', c.area,
        'phone', c.phone, 'email', c.email, 'is_member', c.is_member) order by lower(c.company))
        from public.cert_contractors c where c.active and not exists (select 1 from public.growth_people g where g.cert_id = c.id)), '[]'::jsonb)
  );
end; $fn$;

create or replace function public.growth_import_certs(tok text) returns int
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; n int;
begin
  m := public.team_need();
  insert into public.growth_people(name, company, start_track, trade, area, phone, email, cert_id, is_member, created_by, updated_by)
  select coalesce(nullif(trim(c.contact),''), c.company), c.company, 'business', c.trade, c.area, c.phone, c.email, c.id, c.is_member, m.name, m.name
    from public.cert_contractors c
   where c.active and not exists (select 1 from public.growth_people g where g.cert_id = c.id);
  get diagnostics n = row_count;
  return n;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['growth_list(text)','growth_import_certs(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
