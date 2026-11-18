-- Synthetic local Auth and Storage shims for applying the real migration chain.
create role anon;
create role authenticated;
create role service_role bypassrls;
create schema auth;
create schema storage;
create table auth.users (id uuid primary key, email text);
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid;
$$;
create function auth.role() returns text language sql stable as $$
  select auth.jwt() ->> 'role';
$$;
create function storage.foldername(path text) returns text[] language sql immutable as $$
  select (string_to_array(path, '/'))[1:cardinality(string_to_array(path, '/')) - 1];
$$;
create table storage.buckets (
  id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(), name text not null, bucket_id text not null
);
alter table storage.objects enable row level security;
create publication supabase_realtime;

grant usage on schema auth, public to authenticated, service_role;
alter default privileges in schema public grant select, insert, update, delete
  on tables to authenticated, service_role;

insert into auth.users(id, email) values
  ('11111111-1111-1111-1111-111111111111', 'writer-first@example.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'deletion-first@example.invalid'),
  ('33333333-3333-3333-3333-333333333333', 'unrelated@example.invalid');
