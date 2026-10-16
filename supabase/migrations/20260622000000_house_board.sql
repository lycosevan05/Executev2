-- House board ("The Shortlist") backing table for executelabs.ca/house
--
-- This is a public, no-login board: identity is just a name typed on the device
-- and stored in the browser. There is no auth, so RLS is permissive for the anon
-- role (anyone with the page can read/write). The page is unlisted, not secret.
-- See legal/house.html. Tighten the policies below if you ever add a passphrase
-- or move it behind auth.

create extension if not exists pgcrypto;

create table if not exists public.house_listings (
  id            uuid primary key default gen_random_uuid(),
  title         text,
  url           text,
  gist          text,
  neighbourhood text,
  price         integer,
  beds          text,
  baths         text,
  tags          jsonb not null default '[]'::jsonb,
  gym           text,
  misc          text,
  added_by      text,
  votes         jsonb not null default '{}'::jsonb,   -- { "<name>": "love" | "maybe" | "pass" }
  created_at    timestamptz not null default now()
);

create index if not exists house_listings_created_at_idx on public.house_listings (created_at desc);

alter table public.house_listings enable row level security;

-- Permissive policies: public board, no auth. Anyone (anon) can do anything.
drop policy if exists "house read"   on public.house_listings;
drop policy if exists "house insert" on public.house_listings;
drop policy if exists "house update" on public.house_listings;
drop policy if exists "house delete" on public.house_listings;

create policy "house read"   on public.house_listings for select using (true);
create policy "house insert" on public.house_listings for insert with check (true);
create policy "house update" on public.house_listings for update using (true) with check (true);
create policy "house delete" on public.house_listings for delete using (true);

-- Full row image so realtime DELETE/UPDATE events carry the old row.
alter table public.house_listings replica identity full;

-- Add to the realtime publication for live sync (guarded so re-runs don't error).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'house_listings'
    ) then
      alter publication supabase_realtime add table public.house_listings;
    end if;
  end if;
end $$;
