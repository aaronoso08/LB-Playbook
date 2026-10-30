-- team_update_21: Search misses. Applied in Supabase on 2026-10-30.
-- When someone searches the Playbook and gets no results, the words they typed are saved here
-- (only the words and a count, never who searched) so an admin can add the missing keywords.
-- Kept for 90 days. Admins see the list on the Page owners page and can clear an item once fixed.

create table if not exists public.team_search_misses (
  q          text primary key,
  hits       int not null default 1,
  first_at   timestamptz not null default now(),
  last_at    timestamptz not null default now()
);
alter table public.team_search_misses enable row level security;
revoke all on public.team_search_misses from anon, authenticated;

create or replace function public.search_miss(tok text, p_q text) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v text;
begin
  m := public.team_need();
  v := left(lower(regexp_replace(trim(coalesce(p_q,'')), '\s+', ' ', 'g')), 60);
  if length(v) < 2 then return false; end if;
  insert into public.team_search_misses(q) values (v)
    on conflict (q) do update set hits = team_search_misses.hits + 1, last_at = now();
  delete from public.team_search_misses where last_at < now() - interval '90 days';
  return true;
end; $fn$;

create or replace function public.search_misses_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not m.is_admin then return null; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('q', q, 'hits', hits, 'last_at', last_at) order by hits desc, last_at desc)
    from (select * from public.team_search_misses order by hits desc, last_at desc limit 60) x), '[]'::jsonb);
end; $fn$;

create or replace function public.search_miss_clear(tok text, p_q text) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not m.is_admin then raise exception 'Only an admin can clear this list.'; end if;
  delete from public.team_search_misses where q = p_q;
  return true;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['search_miss(text,text)','search_misses_list(text)','search_miss_clear(text,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
