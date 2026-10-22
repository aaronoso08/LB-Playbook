-- Latino Built Team Playbook: update 2 (team board, polls, games). Safe to run again.
-- Only people with the playbook password have the team code these functions check.

create table if not exists public.team_secret (id int primary key default 1, code_hash text not null);
alter table public.team_secret enable row level security;
revoke all on public.team_secret from anon, authenticated;
insert into public.team_secret(id, code_hash) values (1, '732233f572c68d3d932fe072141c126e68969e9963420dea963b77a4e0ac2655')
  on conflict (id) do update set code_hash = excluded.code_hash;

create table if not exists public.team_posts (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'news' check (kind in ('news','fact')),
  author text not null, title text, body text not null,
  pinned boolean not null default false, ends_on date,
  created_at timestamptz not null default now()
);
create table if not exists public.team_polls (
  id uuid primary key default gen_random_uuid(),
  author text not null, question text not null, options jsonb not null,
  closes_on date, created_at timestamptz not null default now()
);
create table if not exists public.team_votes (
  poll_id uuid not null references public.team_polls(id) on delete cascade,
  voter text not null, choice int not null,
  created_at timestamptz not null default now(),
  primary key (poll_id, voter)
);
create table if not exists public.team_scores (
  id uuid primary key default gen_random_uuid(),
  game text not null, player text not null, score int not null check (score between 0 and 100000),
  created_at timestamptz not null default now()
);
alter table public.team_posts enable row level security;
alter table public.team_polls enable row level security;
alter table public.team_votes enable row level security;
alter table public.team_scores enable row level security;
revoke all on public.team_posts, public.team_polls, public.team_votes, public.team_scores from anon, authenticated;

create or replace function public.team_ok(tok text) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.team_secret where code_hash = encode(sha256(convert_to(coalesce(tok,''), 'UTF8')), 'hex'));
$fn$;

create or replace function public.team_feed(tok text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not public.team_ok(tok) then raise exception 'Team code not accepted.'; end if;
  return jsonb_build_object(
    'posts', coalesce((select jsonb_agg(to_jsonb(p) order by p.pinned desc, p.created_at desc) from public.team_posts p
                       where p.kind = 'news' and (p.ends_on is null or p.ends_on >= current_date)), '[]'::jsonb),
    'facts', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'author', f.author, 'body', f.body)) from public.team_posts f where f.kind = 'fact'), '[]'::jsonb),
    'polls', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'author', q.author, 'question', q.question, 'options', q.options,
                       'closes_on', q.closes_on, 'created_at', q.created_at,
                       'votes', (select coalesce(jsonb_agg(jsonb_build_object('voter', v.voter, 'choice', v.choice)), '[]'::jsonb) from public.team_votes v where v.poll_id = q.id))
                       order by q.created_at desc) from public.team_polls q
                       where q.closes_on is null or q.closes_on >= current_date - 14), '[]'::jsonb),
    'scores', coalesce((select jsonb_agg(to_jsonb(s) order by s.score desc) from (
                       select game, player, max(score) as score, max(created_at) as at from public.team_scores
                       group by game, player) s), '[]'::jsonb)
  );
end; $fn$;

create or replace function public.team_post(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare v_id uuid;
begin
  if not public.team_ok(tok) then raise exception 'Team code not accepted.'; end if;
  if coalesce(trim(p->>'author'),'') = '' or coalesce(trim(p->>'body'),'') = '' then raise exception 'Add your name and a message.'; end if;
  if (p->>'kind') = 'fact' then delete from public.team_posts where kind = 'fact' and author = left(p->>'author',80); end if;
  insert into public.team_posts(kind, author, title, body, pinned, ends_on)
  values (case when p->>'kind' = 'fact' then 'fact' else 'news' end, left(p->>'author',80), left(p->>'title',140), left(p->>'body',2000),
          coalesce((p->>'pinned')::boolean, false), nullif(p->>'ends_on','')::date)
  returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.team_delete(tok text, p_what text, p_item uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.team_ok(tok) then raise exception 'Team code not accepted.'; end if;
  if p_what = 'poll' then delete from public.team_polls where id = p_item; else delete from public.team_posts where id = p_item; end if;
  return found;
end; $fn$;

create or replace function public.team_poll(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare v_id uuid;
begin
  if not public.team_ok(tok) then raise exception 'Team code not accepted.'; end if;
  if coalesce(trim(p->>'question'),'') = '' or jsonb_typeof(p->'options') <> 'array' or jsonb_array_length(p->'options') < 2 or jsonb_array_length(p->'options') > 8 then
    raise exception 'Add a question and 2 to 8 choices.'; end if;
  insert into public.team_polls(author, question, options, closes_on)
  values (left(coalesce(p->>'author','Team'),80), left(p->>'question',300), p->'options', nullif(p->>'closes_on','')::date)
  returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.team_vote(tok text, p_poll uuid, p_voter text, p_choice int) returns boolean
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.team_ok(tok) then raise exception 'Team code not accepted.'; end if;
  if coalesce(trim(p_voter),'') = '' then raise exception 'Pick your name first.'; end if;
  insert into public.team_votes(poll_id, voter, choice) values (p_poll, left(p_voter,80), p_choice)
    on conflict (poll_id, voter) do update set choice = excluded.choice, created_at = now();
  return true;
end; $fn$;

create or replace function public.team_score(tok text, p_game text, p_player text, p_score int) returns boolean
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.team_ok(tok) then raise exception 'Team code not accepted.'; end if;
  if coalesce(trim(p_player),'') = '' then raise exception 'Pick your name first.'; end if;
  insert into public.team_scores(game, player, score) values (left(p_game,40), left(p_player,80), greatest(0, least(p_score, 100000)));
  return true;
end; $fn$;

revoke all on function public.team_ok(text) from public;
revoke all on function public.team_feed(text) from public;
revoke all on function public.team_post(text, jsonb) from public;
revoke all on function public.team_delete(text, text, uuid) from public;
revoke all on function public.team_poll(text, jsonb) from public;
revoke all on function public.team_vote(text, uuid, text, int) from public;
revoke all on function public.team_score(text, text, text, int) from public;
grant execute on function public.team_feed(text) to anon, authenticated;
grant execute on function public.team_post(text, jsonb) to anon, authenticated;
grant execute on function public.team_delete(text, text, uuid) to anon, authenticated;
grant execute on function public.team_poll(text, jsonb) to anon, authenticated;
grant execute on function public.team_vote(text, uuid, text, int) to anon, authenticated;
grant execute on function public.team_score(text, text, text, int) to anon, authenticated;
