-- Latino Built Bid Board: update 1 (shared price list + job tracking). Safe to run again.

alter table public.bid_job_private add column if not exists work_status text;
alter table public.bid_job_private add column if not exists completed_on date;
alter table public.bid_job_private add column if not exists final_amount numeric;
alter table public.bid_job_private add column if not exists work_notes text;

create table if not exists public.bid_settings (
  key text primary key,
  value jsonb not null default '[]'::jsonb,
  updated_by text default (auth.jwt() ->> 'email'),
  updated_at timestamptz not null default now()
);
alter table public.bid_settings enable row level security;
drop policy if exists "staff manage settings" on public.bid_settings;
create policy "staff manage settings" on public.bid_settings for all to authenticated
  using (public.is_bid_staff()) with check (public.is_bid_staff());
revoke all on public.bid_settings from anon;
grant select, insert, update, delete on public.bid_settings to authenticated;
