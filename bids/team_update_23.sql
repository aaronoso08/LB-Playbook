-- team_update_23: Earth Advantage payments for HHGP. Applied in Supabase on 2026-10-30.
-- A simple log of the payments Earth Advantage sends Latino Built for HHGP, entered by hand for now.
-- Everyone signed in sees the count and totals. The details (reference numbers, which homes,
-- notes) and adding, changing or removing a payment are for the green programs team and admins
-- (same rule as the HHGP pipeline, public.hhgp_can_see).

create table if not exists public.hhgp_ea_payments (
  id          uuid primary key default gen_random_uuid(),
  received_on date not null,
  amount      numeric(12,2) not null check (amount > 0 and amount < 10000000),
  reference   text,
  homes       text,
  note        text,
  created_by  text not null,
  created_at  timestamptz not null default now(),
  updated_by  text,
  updated_at  timestamptz
);
create index if not exists hhgp_ea_payments_date_idx on public.hhgp_ea_payments(received_on desc);
alter table public.hhgp_ea_payments enable row level security;
revoke all on public.hhgp_ea_payments from anon, authenticated;

create or replace function public.hhgp_payments_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; see boolean; y date := date_trunc('year', current_date)::date;
begin
  m := public.team_need(); see := public.hhgp_can_see(m);
  return jsonb_build_object(
    'can_edit', see,
    'count', (select count(*) from public.hhgp_ea_payments),
    'total', (select coalesce(sum(amount),0) from public.hhgp_ea_payments),
    'year_count', (select count(*) from public.hhgp_ea_payments where received_on >= y),
    'year_total', (select coalesce(sum(amount),0) from public.hhgp_ea_payments where received_on >= y),
    'last_on', (select max(received_on) from public.hhgp_ea_payments),
    'items', case when see then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'received_on', received_on, 'amount', amount,
        'reference', reference, 'homes', homes, 'note', note, 'by', coalesce(updated_by, created_by)) order by received_on desc, created_at desc)
      from public.hhgp_ea_payments), '[]'::jsonb) else '[]'::jsonb end);
end; $fn$;

create or replace function public.hhgp_payment_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_amt numeric; v_on date;
begin
  m := public.team_need();
  if not public.hhgp_can_see(m) then raise exception 'Only the green programs team can add or change payments.'; end if;
  begin v_amt := round(replace(replace(coalesce(p->>'amount',''),'$',''),',','')::numeric, 2); exception when others then v_amt := null; end;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter the amount, like 750 or 1,500.'; end if;
  begin v_on := (p->>'received_on')::date; exception when others then v_on := null; end;
  if v_on is null then raise exception 'Pick the date the payment came in.'; end if;
  if v_on > current_date + 1 then raise exception 'That date is in the future.'; end if;
  if v_id is null then
    insert into public.hhgp_ea_payments(received_on, amount, reference, homes, note, created_by)
    values (v_on, v_amt, nullif(left(trim(coalesce(p->>'reference','')),80),''), nullif(left(trim(coalesce(p->>'homes','')),500),''),
            nullif(left(trim(coalesce(p->>'note','')),500),''), m.name)
    returning id into v_id;
  else
    update public.hhgp_ea_payments set received_on = v_on, amount = v_amt,
      reference = nullif(left(trim(coalesce(p->>'reference','')),80),''), homes = nullif(left(trim(coalesce(p->>'homes','')),500),''),
      note = nullif(left(trim(coalesce(p->>'note','')),500),''), updated_by = m.name, updated_at = now()
    where id = v_id;
    if not found then raise exception 'That payment was already removed.'; end if;
  end if;
  return v_id;
end; $fn$;

create or replace function public.hhgp_payment_delete(tok text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if not public.hhgp_can_see(m) then raise exception 'Only the green programs team can remove payments.'; end if;
  delete from public.hhgp_ea_payments where id = p_id;
  return true;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['hhgp_payments_list(text)','hhgp_payment_save(text,jsonb)','hhgp_payment_delete(text,uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
