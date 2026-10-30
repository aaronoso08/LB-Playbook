-- team_update_22: My bookmarks. Applied in Supabase on 2026-10-30.
-- Each person keeps their own shortcuts on the Home page: starred Playbook pages and their own links
-- (any https website). Saved to their account, so they show on every device they sign in on.
-- Only the owner can see or change their bookmarks. Up to 60 per person.

create table if not exists public.team_bookmarks (
  id          uuid primary key default gen_random_uuid(),
  owner_email text not null,
  kind        text not null check (kind in ('page','link')),
  page_id     text,
  title       text,
  url         text,
  created_at  timestamptz not null default now(),
  check ((kind = 'page' and page_id is not null) or (kind = 'link' and url ~* '^https://' and title is not null))
);
create unique index if not exists team_bookmarks_page_uq on public.team_bookmarks(owner_email, page_id) where kind = 'page';
create index if not exists team_bookmarks_owner_idx on public.team_bookmarks(owner_email, created_at);
alter table public.team_bookmarks enable row level security;
revoke all on public.team_bookmarks from anon, authenticated;

create or replace function public.bookmarks_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'page_id', page_id, 'title', title, 'url', url) order by created_at)
    from public.team_bookmarks where owner_email = lower(m.email)), '[]'::jsonb);
end; $fn$;

create or replace function public.bookmark_add(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid; v_kind text := coalesce(p->>'kind','link');
        v_url text := left(trim(coalesce(p->>'url','')), 500); v_title text := left(trim(coalesce(p->>'title','')), 80);
        v_page text := left(trim(coalesce(p->>'page_id','')), 60);
begin
  m := public.team_need();
  if (select count(*) from public.team_bookmarks where owner_email = lower(m.email)) >= 60 then
    raise exception 'You have 60 bookmarks. Remove one to add another.'; end if;
  if v_kind = 'page' then
    if v_page = '' then raise exception 'Missing page.'; end if;
    insert into public.team_bookmarks(owner_email, kind, page_id) values (lower(m.email), 'page', v_page)
      on conflict (owner_email, page_id) where kind = 'page' do nothing returning id into v_id;
    return v_id;
  end if;
  if v_url !~* '^https?://' then v_url := 'https://' || v_url; end if;
  v_url := regexp_replace(v_url, '^http://', 'https://', 'i');
  if v_url !~* '^https://[^\s/$.?#][^\s]*$' then raise exception 'That link doesn''t look right. Copy it from the address bar.'; end if;
  if v_title = '' then v_title := left(regexp_replace(v_url, '^https://(www\.)?([^/]+).*$', '\2', 'i'), 80); end if;
  insert into public.team_bookmarks(owner_email, kind, title, url) values (lower(m.email), 'link', v_title, v_url) returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.bookmark_delete(tok text, p_id uuid, p_page text) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  delete from public.team_bookmarks where owner_email = lower(m.email)
    and ((p_id is not null and id = p_id) or (p_page is not null and kind = 'page' and page_id = p_page));
  return true;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['bookmarks_list(text)','bookmark_add(text,jsonb)','bookmark_delete(text,uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
