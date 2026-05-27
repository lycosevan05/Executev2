create extension if not exists pgcrypto;

create or replace function public.touch_backend_record()
returns trigger
language plpgsql
as $$
begin
  new.updated_date = now();
  return new;
end;
$$;

do $$
declare
  entity_table text;
  entity_tables text[] := array[
    'ai_plans',
    'custom_checklist_items',
    'daily_logs',
    'food_logs',
    'goals',
    'goal_progress_entries',
    'injury_profiles',
    'meal_plans',
    'nutrition_profiles',
    'readiness_check_ins',
    'saved_recipes',
    'app_users',
    'user_ai_contexts',
    'user_page_layouts',
    'user_profiles',
    'user_subscriptions',
    'workout_logs',
    'workout_plans',
    'workout_profiles'
  ];
begin
  foreach entity_table in array entity_tables loop
    execute format(
      'create table if not exists public.%I (
        id uuid primary key default gen_random_uuid(),
        owner_id uuid default auth.uid(),
        owner_email text default (auth.jwt() ->> ''email''),
        created_by text default (auth.jwt() ->> ''email''),
        user_email text default (auth.jwt() ->> ''email''),
        data jsonb not null default ''{}''::jsonb,
        created_date timestamptz not null default now(),
        updated_date timestamptz not null default now()
      )',
      entity_table
    );

    execute format('alter table public.%I enable row level security', entity_table);

    execute format('drop policy if exists "read own records" on public.%I', entity_table);
    execute format('drop policy if exists "insert own records" on public.%I', entity_table);
    execute format('drop policy if exists "update own records" on public.%I', entity_table);
    execute format('drop policy if exists "delete own records" on public.%I', entity_table);

    execute format(
      'create policy "read own records" on public.%I
        for select
        using (
          auth.role() = ''service_role''
          or owner_id = auth.uid()
          or owner_email = (auth.jwt() ->> ''email'')
          or created_by = (auth.jwt() ->> ''email'')
          or user_email = (auth.jwt() ->> ''email'')
        )',
      entity_table
    );

    execute format(
      'create policy "insert own records" on public.%I
        for insert
        with check (
          auth.role() = ''service_role''
          or owner_id = auth.uid()
          or owner_email = (auth.jwt() ->> ''email'')
          or created_by = (auth.jwt() ->> ''email'')
          or user_email = (auth.jwt() ->> ''email'')
        )',
      entity_table
    );

    execute format(
      'create policy "update own records" on public.%I
        for update
        using (
          auth.role() = ''service_role''
          or owner_id = auth.uid()
          or owner_email = (auth.jwt() ->> ''email'')
          or created_by = (auth.jwt() ->> ''email'')
          or user_email = (auth.jwt() ->> ''email'')
        )
        with check (
          auth.role() = ''service_role''
          or owner_id = auth.uid()
          or owner_email = (auth.jwt() ->> ''email'')
          or created_by = (auth.jwt() ->> ''email'')
          or user_email = (auth.jwt() ->> ''email'')
        )',
      entity_table
    );

    execute format(
      'create policy "delete own records" on public.%I
        for delete
        using (
          auth.role() = ''service_role''
          or owner_id = auth.uid()
          or owner_email = (auth.jwt() ->> ''email'')
          or created_by = (auth.jwt() ->> ''email'')
          or user_email = (auth.jwt() ->> ''email'')
        )',
      entity_table
    );

    execute format('create index if not exists %I on public.%I (owner_id)', entity_table || '_owner_id_idx', entity_table);
    execute format('create index if not exists %I on public.%I (owner_email)', entity_table || '_owner_email_idx', entity_table);
    execute format('create index if not exists %I on public.%I (created_by)', entity_table || '_created_by_idx', entity_table);
    execute format('create index if not exists %I on public.%I (created_date desc)', entity_table || '_created_date_idx', entity_table);
    execute format('create index if not exists %I on public.%I (updated_date desc)', entity_table || '_updated_date_idx', entity_table);
    execute format('create index if not exists %I on public.%I using gin (data)', entity_table || '_data_gin_idx', entity_table);

    execute format('drop trigger if exists touch_backend_record on public.%I', entity_table);
    execute format(
      'create trigger touch_backend_record
        before update on public.%I
        for each row execute function public.touch_backend_record()',
      entity_table
    );

    begin
      execute format('alter publication supabase_realtime add table public.%I', entity_table);
    exception
      when duplicate_object then null;
      when undefined_object then null;
    end;
  end loop;
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'uploads',
  'uploads',
  true,
  52428800,
  array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'application/pdf', 'text/plain']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "uploads public read" on storage.objects;
drop policy if exists "uploads insert own folder" on storage.objects;
drop policy if exists "uploads update own folder" on storage.objects;
drop policy if exists "uploads delete own folder" on storage.objects;

create policy "uploads public read" on storage.objects
  for select
  using (bucket_id = 'uploads');

create policy "uploads insert own folder" on storage.objects
  for insert
  with check (
    bucket_id = 'uploads'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "uploads update own folder" on storage.objects
  for update
  using (
    bucket_id = 'uploads'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'uploads'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "uploads delete own folder" on storage.objects
  for delete
  using (
    bucket_id = 'uploads'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
