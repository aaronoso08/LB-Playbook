-- team_update_29: Assessment kit (Field > Assessment kit). Applied in Supabase on 2026-11-16.
-- The tool list itself lives in the page. This table only keeps what the team changes:
-- each tool's status (have / requested / need to buy), its price, and a short note,
-- with who changed it and when. Any signed-in staff member can update it.

create table if not exists public.team_kit (
  item_key   text primary key check (item_key ~ '^[a-z0-9_-]{1,40}$'),
  status     text not null default 'unset' check (status in ('have','requested','need','unset')),
  price      numeric(10,2) check (price is null or (price >= 0 and price < 100000)),
  note       text check (note is null or length(note) <= 200),
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.team_kit enable row level security;
revoke all on public.team_kit from anon, authenticated;

create or replace function public.kit_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return coalesce((select jsonb_object_agg(item_key, jsonb_build_object('status', status, 'price', price, 'note', note,
    'by', updated_by, 'at', updated_at)) from public.team_kit), '{}'::jsonb);
end; $fn$;

create or replace function public.kit_set(tok text, p_key text, p jsonb) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_status text := coalesce(p->>'status','unset');
        v_price numeric := nullif(p->>'price','')::numeric; v_note text := nullif(left(trim(coalesce(p->>'note','')),200),'');
begin
  m := public.team_need();
  if v_status not in ('have','requested','need','unset') then raise exception 'Unknown status.'; end if;
  insert into public.team_kit(item_key, status, price, note, updated_by, updated_at)
    values (p_key, v_status, v_price, v_note, coalesce(m.name, m.email), now())
  on conflict (item_key) do update set status = excluded.status, price = excluded.price, note = excluded.note,
    updated_by = excluded.updated_by, updated_at = now();
  return true;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['kit_list(text)','kit_set(text,text,jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
