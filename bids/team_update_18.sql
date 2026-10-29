-- team_update_18: Snugg Pro connection (job IDs, stages and dates only; no homeowner names, no chat messages)
-- The webhook inbox is the Supabase Edge Function "snugg". Its secret link code lives in snugg_config.
create table if not exists public.snugg_config (id int primary key default 1 check (id=1), hook_token text not null);
create table if not exists public.snugg_jobs (
  job_id bigint primary key, alt_id text, stage text, prev_stage text, stage_at timestamptz,
  first_modeled_at timestamptz, hes_score numeric, program text, created_at timestamptz,
  updated_at timestamptz not null default now()
);
create table if not exists public.snugg_events (
  id bigserial primary key, event text not null, job_id bigint, detail text,
  received_at timestamptz not null default now()
);
alter table public.snugg_config enable row level security;
alter table public.snugg_jobs enable row level security;
alter table public.snugg_events enable row level security;
revoke all on public.snugg_config, public.snugg_jobs, public.snugg_events from anon, authenticated;
grant all on public.snugg_config, public.snugg_jobs, public.snugg_events to service_role;
grant usage, select on sequence public.snugg_events_id_seq to service_role;
insert into public.snugg_config(id, hook_token) values (1, encode(extensions.gen_random_bytes(24),'hex')) on conflict (id) do nothing;

drop function if exists public.snugg_list();
create or replace function public.snugg_list(tok text) returns json
language plpgsql security definer set search_path=public as $$
begin
  perform public.team_need();
  return json_build_object(
    'jobs', coalesce((select json_agg(j order by j.stage_at desc nulls last) from (select job_id, alt_id, stage, prev_stage, stage_at, first_modeled_at, hes_score, program, created_at, updated_at from snugg_jobs) j), '[]'::json),
    'stages', coalesce((select json_agg(s) from (select coalesce(stage,'Unknown') stage, count(*) n from snugg_jobs group by 1 order by 2 desc) s), '[]'::json),
    'events', coalesce((select json_agg(e) from (select event, job_id, detail, received_at from snugg_events order by received_at desc limit 25) e), '[]'::json),
    'last', (select max(received_at) from snugg_events)
  );
end $$;
revoke all on function public.snugg_list(text) from public, anon;
grant execute on function public.snugg_list(text) to authenticated;
