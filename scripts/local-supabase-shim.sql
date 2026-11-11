-- Minimal stand-in for what a Supabase project already provides, so the
-- migration and tests can run against plain Postgres in CI or locally
-- without the Supabase CLI. Not used when running `supabase test db`.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists auth;
create schema if not exists extensions;

create table if not exists auth.users (
  id    uuid primary key,
  email text
);

-- Same behaviour as Supabase's auth.uid(): the "sub" claim of the request JWT.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ),
    ''
  )::uuid;
$$;

grant usage on schema auth, extensions to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- The migration grants table privileges itself, so nothing else is granted
-- here; the tests then prove the migration alone is enough.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to service_role;
