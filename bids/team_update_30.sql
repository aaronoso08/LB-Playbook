-- team_update_30: Team files (Library > Team files). Applied in Supabase on 2026-11-16.
-- Anyone signed in can upload a file (PDF, Word, Excel, PowerPoint, CSV, text, photos; 10 MB max)
-- or add a SharePoint/OneDrive link, and give it a title, category and note.
-- Files go in the private storage bucket "team-files" and only open for signed-in staff (10-minute links).
-- People can edit or remove their own entries; admins can edit or remove any.
-- Files with client personal information (IDs, income documents, signed forms) belong in SharePoint, not here.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-files', 'team-files', false, 10485760, array[
  'application/pdf',
  'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/csv','text/plain','image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "team uploads files" on storage.objects;
create policy "team uploads files" on storage.objects for insert to authenticated
  with check (bucket_id = 'team-files' and public.is_bid_staff() and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9._ ()-]{1,120}$');
drop policy if exists "team views files" on storage.objects;
create policy "team views files" on storage.objects for select to authenticated
  using (bucket_id = 'team-files' and public.is_bid_staff());
drop policy if exists "team removes own files" on storage.objects;
create policy "team removes own files" on storage.objects for delete to authenticated
  using (bucket_id = 'team-files' and public.is_bid_staff() and (owner = auth.uid() or exists (select 1 from public.team_member m
    where m.active and m.is_admin and lower(m.email) = lower(coalesce(auth.jwt()->>'email','')))));

create table if not exists public.team_files (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('file','link')),
  title       text not null check (length(title) between 1 and 120),
  category    text not null default 'other',
  note        text check (note is null or length(note) <= 300),
  path        text,
  url         text,
  file_name   text,
  mime        text,
  size_bytes  bigint,
  created_by  text not null,
  created_name text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((kind = 'file' and path is not null) or (kind = 'link' and url ~* '^https://'))
);
create index if not exists team_files_created_idx on public.team_files(created_at desc);
alter table public.team_files enable row level security;
revoke all on public.team_files from anon, authenticated;

create or replace function public.files_list(tok text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member;
begin
  m := public.team_need();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'title', title, 'category', category, 'note', note,
    'path', path, 'url', url, 'file_name', file_name, 'mime', mime, 'size', size_bytes, 'by', created_by, 'by_name', created_name,
    'at', created_at, 'mine', lower(created_by) = lower(m.email) or m.is_admin) order by created_at desc)
    from public.team_files), '[]'::jsonb);
end; $fn$;

create or replace function public.file_save(tok text, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; v_id uuid := nullif(p->>'id','')::uuid; v_kind text := coalesce(p->>'kind','file');
        v_title text := left(trim(coalesce(p->>'title','')),120); v_cat text := left(coalesce(nullif(p->>'category',''),'other'),40);
        v_note text := nullif(left(trim(coalesce(p->>'note','')),300),''); v_url text := trim(coalesce(p->>'url',''));
        v_path text := p->>'path'; r public.team_files;
begin
  m := public.team_need();
  if v_title = '' then raise exception 'Give it a title.'; end if;
  if v_id is not null then
    select * into r from public.team_files where id = v_id;
    if r.id is null then raise exception 'That file is gone.'; end if;
    if lower(r.created_by) <> lower(m.email) and not m.is_admin then raise exception 'Only the person who added it (or an admin) can change it.'; end if;
    if r.kind = 'link' and v_url <> '' then
      if v_url !~* '^https://[^\s]+$' then raise exception 'That link doesn''t look right. Copy it from the address bar.'; end if;
    else v_url := r.url; end if;
    update public.team_files set title = v_title, category = v_cat, note = v_note, url = v_url, updated_at = now() where id = v_id;
    return v_id;
  end if;
  if (select count(*) from public.team_files) >= 2000 then raise exception 'The team files list is full. Ask an admin to clean it up.'; end if;
  if v_kind = 'link' then
    if v_url !~* '^https://[^\s]+$' then raise exception 'That link doesn''t look right. Copy it from the address bar.'; end if;
    insert into public.team_files(kind, title, category, note, url, created_by, created_name)
      values ('link', v_title, v_cat, v_note, v_url, lower(m.email), m.name) returning id into v_id;
    return v_id;
  end if;
  if v_path is null or v_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9._ ()-]{1,120}$' then raise exception 'Upload the file first.'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'team-files' and o.name = v_path) then
    raise exception 'The upload didn''t finish. Try again.'; end if;
  insert into public.team_files(kind, title, category, note, path, file_name, mime, size_bytes, created_by, created_name)
    values ('file', v_title, v_cat, v_note, v_path, left(coalesce(p->>'file_name',''),160), left(coalesce(p->>'mime',''),120),
      nullif(p->>'size','')::bigint, lower(m.email), m.name) returning id into v_id;
  return v_id;
end; $fn$;

create or replace function public.file_delete(tok text, p_id uuid) returns text
language plpgsql security definer set search_path = public as $fn$
declare m public.team_member; r public.team_files;
begin
  m := public.team_need();
  select * into r from public.team_files where id = p_id;
  if r.id is null then return null; end if;
  if lower(r.created_by) <> lower(m.email) and not m.is_admin then raise exception 'Only the person who added it (or an admin) can remove it.'; end if;
  delete from public.team_files where id = p_id;
  return r.path;
end; $fn$;

do $do$
declare f text;
begin
  foreach f in array array['files_list(text)','file_save(text,jsonb)','file_delete(text,uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $do$;
