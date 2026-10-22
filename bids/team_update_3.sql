-- Latino Built Team Playbook: update 3 (personal logins). Safe to run again.
-- Each staff member signs in with their own email. Posts, votes and scores use the signed-in person's name.
-- The staff list and the page key are added by a separate private file (never put those in this repo).

create table if not exists public.team_member (
  email text primary key,
  name text not null,
  role_id text,
  is_admin boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.team_member enable row level security;
revoke all on public.team_member from anon, authenticated;

create table if not exists public.team_vault (id int primary key default 1, page_key text not null);
alter table public.team_vault enable row level security;
revoke all on public.team_vault from anon, authenticated;

-- Who is signed in (null if they are not on the active staff list)
create or replace function public.team_me_row() returns public.team_member
language sql stable security definer set search_path = public as $fn$
  select m.* from public.team_member m
  where m.active and lower(m.email) = lower(coalesce(auth.jwt()->>'email',''))
  limit 1;
$fn$;

create or replace function public.team_need() returns public.team_member
language plpgsql stable security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_me_row();
  if m.email is null then raise exception 'NOT_MEMBER: sign in with your Latino Built email.'; end if;
  return m;
end; $fn$;

create or replace function public.team_whoami() returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object('email', m.email, 'name', m.name, 'role_id', m.role_id, 'is_admin', m.is_admin);
end; $fn$;

-- The key that unlocks the playbook page, only for active staff
create or replace function public.team_page_key() returns text
language plpgsql stable security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return (select page_key from public.team_vault where id = 1);
end; $fn$;

-- Team board functions: same names as update 2, but the name now comes from the login
create or replace function public.team_feed(tok text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return jsonb_build_object(
    'me', jsonb_build_object('name', m.name, 'is_admin', m.is_admin),
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
declare v_id uuid; m public.team_member;
begin
  m := public.team_need();
  if coalesce(trim(p->>'body'),'') = '' then raise exception 'Write a message first.'; end if;
  if (p->>'kind') = 'fact' then delete from public.team_posts where kind = 'fact' and author = m.name; end if;
  insert into public.team_posts(kind, author, title, body, pinned, ends_on)
  values (case when p->>'kind' = 'fact' then 'fact' else 'news' end, m.name, left(p->>'title',140), left(p->>'body',2000),
          coalesce((p->>'pinned')::boolean, false), nullif(p->>'ends_on','')::date)
  returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.team_delete(tok text, p_what text, p_item uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  if p_what = 'poll' then
    delete from public.team_polls where id = p_item and (author = m.name or m.is_admin);
  else
    delete from public.team_posts where id = p_item and (author = m.name or m.is_admin);
  end if;
  if not found then raise exception 'You can only delete your own posts.'; end if;
  return true;
end; $fn$;

create or replace function public.team_poll(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare v_id uuid; m public.team_member;
begin
  m := public.team_need();
  if coalesce(trim(p->>'question'),'') = '' or jsonb_typeof(p->'options') <> 'array' or jsonb_array_length(p->'options') < 2 or jsonb_array_length(p->'options') > 8 then
    raise exception 'Add a question and 2 to 8 choices.'; end if;
  insert into public.team_polls(author, question, options, closes_on)
  values (m.name, left(p->>'question',300), p->'options', nullif(p->>'closes_on','')::date)
  returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.team_vote(tok text, p_poll uuid, p_voter text, p_choice int) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  insert into public.team_votes(poll_id, voter, choice) values (p_poll, m.name, p_choice)
    on conflict (poll_id, voter) do update set choice = excluded.choice, created_at = now();
  return true;
end; $fn$;

create or replace function public.team_score(tok text, p_game text, p_player text, p_score int) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  insert into public.team_scores(game, player, score) values (left(p_game,40), m.name, greatest(0, least(p_score, 100000)));
  return true;
end; $fn$;

revoke all on function public.team_me_row() from public, anon, authenticated;
revoke all on function public.team_need() from public, anon, authenticated;
revoke all on function public.team_whoami() from public, anon;
revoke all on function public.team_page_key() from public, anon;
revoke all on function public.team_feed(text) from public, anon;
revoke all on function public.team_post(text, jsonb) from public, anon;
revoke all on function public.team_delete(text, text, uuid) from public, anon;
revoke all on function public.team_poll(text, jsonb) from public, anon;
revoke all on function public.team_vote(text, uuid, text, int) from public, anon;
revoke all on function public.team_score(text, text, text, int) from public, anon;
grant execute on function public.team_whoami() to authenticated;
grant execute on function public.team_page_key() to authenticated;
grant execute on function public.team_feed(text) to authenticated;
grant execute on function public.team_post(text, jsonb) to authenticated;
grant execute on function public.team_delete(text, text, uuid) to authenticated;
grant execute on function public.team_poll(text, jsonb) to authenticated;
grant execute on function public.team_vote(text, uuid, text, int) to authenticated;
grant execute on function public.team_score(text, text, text, int) to authenticated;
