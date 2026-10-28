-- =====================================================================
-- Latino Built Team Playbook: update 17 (Partners and Ideas board). Safe to run again.
-- Run AFTER team_update_16.sql.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- 1) Partners: the organizations we work with, who our contact is there,
--    which of us owns the relationship, the last time we talked and the next step.
--    Every check-in is logged with the date.
-- 2) Ideas board: anyone on staff can post an idea or something they saw,
--    others comment and vote, and the idea moves from new to doing or parked.
-- Staff only, like everything else. No client information here.
-- =====================================================================

create table if not exists public.team_partners (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  kind          text not null default 'community' check (kind in ('community','funder','government','program','training','workforce','business','other')),
  what          text,
  contact_name  text,
  contact_role  text,
  contact_email text,
  contact_phone text,
  website       text,
  owner         text,
  status        text not null default 'active' check (status in ('active','building','past')),
  next_step     text,
  next_on       date,
  notes         text,
  active        boolean not null default true,
  created_by    text not null,
  created_at    timestamptz not null default now(),
  updated_by    text,
  updated_at    timestamptz not null default now()
);
create table if not exists public.team_partner_touches (
  id         uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.team_partners(id) on delete cascade,
  kind       text not null default 'meeting' check (kind in ('meeting','call','email','event','other')),
  note       text,
  on_date    date not null,
  created_by text not null,
  created_at timestamptz not null default now()
);
create index if not exists team_partner_touches_p_idx on public.team_partner_touches(partner_id, on_date desc);

create table if not exists public.team_ideas (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  body       text,
  tag        text not null default 'other' check (tag in ('funding','partnership','program','training','advocacy','members','operations','other')),
  link       text,
  status     text not null default 'new' check (status in ('new','talking','doing','parked','done')),
  next_step  text,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now()
);
create table if not exists public.team_idea_votes (
  idea_id uuid not null references public.team_ideas(id) on delete cascade,
  name    text not null,
  at      timestamptz not null default now(),
  primary key (idea_id, name)
);
create table if not exists public.team_idea_comments (
  id         uuid primary key default gen_random_uuid(),
  idea_id    uuid not null references public.team_ideas(id) on delete cascade,
  body       text not null,
  created_by text not null,
  created_at timestamptz not null default now()
);
create index if not exists team_idea_comments_i_idx on public.team_idea_comments(idea_id, created_at);

alter table public.team_partners enable row level security;
alter table public.team_partner_touches enable row level security;
alter table public.team_ideas enable row level security;
alter table public.team_idea_votes enable row level security;
alter table public.team_idea_comments enable row level security;
revoke all on public.team_partners, public.team_partner_touches, public.team_ideas, public.team_idea_votes, public.team_idea_comments from anon, authenticated;

-- ---------- Partners ----------
create or replace function public.partners_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'people', coalesce((select jsonb_agg(name order by name) from public.team_member where active), '[]'::jsonb),
    'partners', coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'last_on', (select max(t.on_date) from public.team_partner_touches t where t.partner_id = p.id),
        'touches', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'note', t.note, 'on_date', t.on_date, 'by', t.created_by)
                     order by t.on_date desc, t.created_at desc) from (select * from public.team_partner_touches x where x.partner_id = p.id
                     order by x.on_date desc, x.created_at desc limit 25) t), '[]'::jsonb))
        order by lower(p.name)) from public.team_partners p where p.active), '[]'::jsonb));
end; $fn$;

create or replace function public.partner_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_owner text := nullif(trim(coalesce(p->>'owner','')),'');
        v_kind text := coalesce(nullif(p->>'kind',''),'community'); v_status text := coalesce(nullif(p->>'status',''),'active');
begin
  m := public.team_need();
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'Add the organization name.'; end if;
  if v_owner is not null and not exists (select 1 from public.team_member where active and name = v_owner) then raise exception 'That person is not on the team list.'; end if;
  if v_kind not in ('community','funder','government','program','training','workforce','business','other') then v_kind := 'other'; end if;
  if v_status not in ('active','building','past') then v_status := 'active'; end if;
  if v_id is null then
    insert into public.team_partners(name, kind, what, contact_name, contact_role, contact_email, contact_phone, website, owner, status, next_step, next_on, notes, created_by, updated_by)
    values (left(trim(p->>'name'),160), v_kind, left(p->>'what',600), left(p->>'contact_name',120), left(p->>'contact_role',120), left(p->>'contact_email',200),
            left(p->>'contact_phone',60), left(p->>'website',300), v_owner, v_status, left(p->>'next_step',300), nullif(p->>'next_on','')::date, left(p->>'notes',2000), m.name, m.name)
    returning id into v_id;
  else
    update public.team_partners set name = left(trim(p->>'name'),160), kind = v_kind, what = left(p->>'what',600), contact_name = left(p->>'contact_name',120),
      contact_role = left(p->>'contact_role',120), contact_email = left(p->>'contact_email',200), contact_phone = left(p->>'contact_phone',60),
      website = left(p->>'website',300), owner = v_owner, status = v_status, next_step = left(p->>'next_step',300), next_on = nullif(p->>'next_on','')::date,
      notes = left(p->>'notes',2000), updated_by = m.name, updated_at = now()
    where id = v_id and active;
    if not found then raise exception 'That partner is gone. Refresh the page.'; end if;
  end if;
  return v_id;
end; $fn$;

-- Log a check-in. Optionally update the next step at the same time.
create or replace function public.partner_touch(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid; v_pid uuid := (p->>'partner_id')::uuid; v_kind text := coalesce(nullif(p->>'kind',''),'meeting');
begin
  m := public.team_need();
  if not exists (select 1 from public.team_partners where id = v_pid and active) then raise exception 'That partner is gone. Refresh the page.'; end if;
  if v_kind not in ('meeting','call','email','event','other') then v_kind := 'other'; end if;
  insert into public.team_partner_touches(partner_id, kind, note, on_date, created_by)
  values (v_pid, v_kind, nullif(left(trim(coalesce(p->>'note','')),600),''), coalesce(nullif(p->>'on_date','')::date, (now() at time zone 'America/Los_Angeles')::date), m.name)
  returning id into v_id;
  if p ? 'next_step' then
    update public.team_partners set next_step = nullif(left(trim(coalesce(p->>'next_step','')),300),''), next_on = nullif(p->>'next_on','')::date,
      updated_by = m.name, updated_at = now() where id = v_pid;
  else
    update public.team_partners set updated_by = m.name, updated_at = now() where id = v_pid;
  end if;
  return v_id;
end; $fn$;

create or replace function public.partner_touch_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.team_partner_touches where id = p_id and (m.is_admin or created_by = m.name);
  if not found then raise exception 'Only the person who logged it, or an admin, can remove it.'; end if;
  return true;
end; $fn$;

-- Hide a partner (kept in the database)
create or replace function public.partner_remove(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  update public.team_partners set active = false, updated_by = m.name, updated_at = now()
   where id = p_id and (m.is_admin or created_by = m.name or owner = m.name);
  if not found then raise exception 'Only an admin, the owner, or whoever added it can remove it.'; end if;
  return true;
end; $fn$;

-- ---------- Ideas board ----------
create or replace function public.ideas_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
    'ideas', coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object(
        'votes', (select count(*) from public.team_idea_votes v where v.idea_id = i.id),
        'voters', coalesce((select jsonb_agg(v.name order by v.at) from public.team_idea_votes v where v.idea_id = i.id), '[]'::jsonb),
        'mine', exists (select 1 from public.team_idea_votes v where v.idea_id = i.id and v.name = m.name),
        'comments', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'body', c.body, 'by', c.created_by, 'at', c.created_at) order by c.created_at)
                      from public.team_idea_comments c where c.idea_id = i.id), '[]'::jsonb),
        'last_at', greatest(i.updated_at, coalesce((select max(c.created_at) from public.team_idea_comments c where c.idea_id = i.id), i.updated_at)))
        order by i.created_at desc) from public.team_ideas i), '[]'::jsonb));
end; $fn$;

-- Post or edit an idea. Anyone can change the status or next step; only the author or an admin can rewrite it.
create or replace function public.idea_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_tag text := coalesce(nullif(p->>'tag',''),'other');
        v_status text := coalesce(nullif(p->>'status',''),'new'); x public.team_ideas;
begin
  m := public.team_need();
  if v_tag not in ('funding','partnership','program','training','advocacy','members','operations','other') then v_tag := 'other'; end if;
  if v_status not in ('new','talking','doing','parked','done') then v_status := 'new'; end if;
  if v_id is null then
    if coalesce(trim(p->>'title'),'') = '' then raise exception 'Give your idea a short title.'; end if;
    insert into public.team_ideas(title, body, tag, link, status, next_step, created_by, updated_by)
    values (left(trim(p->>'title'),160), left(p->>'body',4000), v_tag, nullif(left(trim(coalesce(p->>'link','')),500),''), v_status,
            nullif(left(trim(coalesce(p->>'next_step','')),300),''), m.name, m.name)
    returning id into v_id;
  else
    select * into x from public.team_ideas where id = v_id;
    if not found then raise exception 'That idea is gone. Refresh the page.'; end if;
    if x.created_by = m.name or m.is_admin then
      if coalesce(trim(p->>'title'),'') = '' then raise exception 'Give your idea a short title.'; end if;
      update public.team_ideas set title = left(trim(p->>'title'),160), body = left(p->>'body',4000), tag = v_tag,
        link = nullif(left(trim(coalesce(p->>'link','')),500),''), status = v_status, next_step = nullif(left(trim(coalesce(p->>'next_step','')),300),''),
        updated_by = m.name, updated_at = now() where id = v_id;
    else
      update public.team_ideas set status = v_status, next_step = nullif(left(trim(coalesce(p->>'next_step','')),300),''),
        updated_by = m.name, updated_at = now() where id = v_id;
    end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.idea_vote(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not exists (select 1 from public.team_ideas where id = p_id) then raise exception 'That idea is gone. Refresh the page.'; end if;
  if exists (select 1 from public.team_idea_votes where idea_id = p_id and name = m.name) then
    delete from public.team_idea_votes where idea_id = p_id and name = m.name; return false;
  end if;
  insert into public.team_idea_votes(idea_id, name) values (p_id, m.name); return true;
end; $fn$;

create or replace function public.idea_comment(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid;
begin
  m := public.team_need();
  if coalesce(trim(p->>'body'),'') = '' then raise exception 'Write something first.'; end if;
  if not exists (select 1 from public.team_ideas where id = (p->>'idea_id')::uuid) then raise exception 'That idea is gone. Refresh the page.'; end if;
  insert into public.team_idea_comments(idea_id, body, created_by) values ((p->>'idea_id')::uuid, left(trim(p->>'body'),2000), m.name) returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.idea_comment_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.team_idea_comments where id = p_id and (m.is_admin or created_by = m.name);
  if not found then raise exception 'Only the person who wrote it, or an admin, can remove it.'; end if;
  return true;
end; $fn$;

create or replace function public.idea_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.team_ideas where id = p_id and (m.is_admin or created_by = m.name);
  if not found then raise exception 'Only the person who posted it, or an admin, can delete it.'; end if;
  return true;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['partners_list(text)','partner_save(text,jsonb)','partner_touch(text,jsonb)','partner_touch_delete(text,uuid)','partner_remove(text,uuid)',
    'ideas_list(text)','idea_save(text,jsonb)','idea_vote(text,uuid)','idea_comment(text,jsonb)','idea_comment_delete(text,uuid)','idea_delete(text,uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
