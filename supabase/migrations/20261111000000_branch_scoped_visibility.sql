-- Branch-scoped visibility for nested organizations.
--
-- Rule: a person sees their own org and everything below it in their branch.
-- Never the orgs above them, never sibling branches, never other trees.
-- The database enforces this. Nothing is filtered in the application.
--
-- Pieces:
--   organizations      the tree (parent_id)
--   org_closure        every ancestor/descendant pair, maintained by triggers
--   memberships        who belongs to which org, with a rank inside that org
--   records            example of "anything owned by an org"
--   private.*          helper functions, in a schema the API does not expose

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.organizations (
  id         uuid primary key default gen_random_uuid(),
  parent_id  uuid references public.organizations (id) on delete restrict,
  name       text not null,
  created_at timestamptz not null default now(),
  constraint organizations_not_own_parent check (parent_id is distinct from id)
);
create index organizations_parent_id_idx on public.organizations (parent_id);

-- One row per (ancestor, descendant) pair, including (self, self) at depth 0.
-- "Everything below X" becomes a single indexed lookup instead of a recursive
-- query evaluated inside every policy.
create table public.org_closure (
  ancestor_id   uuid not null references public.organizations (id) on delete cascade,
  descendant_id uuid not null references public.organizations (id) on delete cascade,
  depth         int  not null check (depth >= 0),
  primary key (ancestor_id, descendant_id)
);
create index org_closure_descendant_idx on public.org_closure (descendant_id, ancestor_id);

create table public.memberships (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  org_id       uuid not null references public.organizations (id) on delete cascade,
  role         text not null default 'member',
  -- Rank inside the org: 1 is the most senior. Only used for the
  -- "same org" rule below; see private.my_org_ranks().
  rank         int  not null default 100 check (rank > 0),
  display_name text not null,
  unique (user_id, org_id)
);
create index memberships_user_id_idx on public.memberships (user_id);
create index memberships_org_id_idx  on public.memberships (org_id);

create table public.records (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  title      text not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index records_org_id_idx on public.records (org_id);

-- ---------------------------------------------------------------------------
-- Closure table maintenance
-- ---------------------------------------------------------------------------

create or replace function private.org_closure_on_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.org_closure (ancestor_id, descendant_id, depth)
  values (new.id, new.id, 0);

  if new.parent_id is not null then
    insert into public.org_closure (ancestor_id, descendant_id, depth)
    select c.ancestor_id, new.id, c.depth + 1
    from public.org_closure c
    where c.descendant_id = new.parent_id;
  end if;

  return new;
end;
$$;

-- Moving an org (and its whole subtree) to a new parent.
create or replace function private.org_closure_before_move()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Refuse to move an org underneath itself or one of its own descendants.
  if new.parent_id is not null and exists (
    select 1 from public.org_closure c
    where c.ancestor_id = new.id and c.descendant_id = new.parent_id
  ) then
    raise exception 'cannot move organization % under its own descendant %', new.id, new.parent_id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create or replace function private.org_closure_after_move()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 1. Detach the subtree from its old ancestors.
  delete from public.org_closure c
  where c.descendant_id in (select descendant_id from public.org_closure where ancestor_id = new.id)
    and c.ancestor_id not in (select descendant_id from public.org_closure where ancestor_id = new.id);

  -- 2. Attach it under the new parent's ancestors.
  if new.parent_id is not null then
    insert into public.org_closure (ancestor_id, descendant_id, depth)
    select above.ancestor_id, below.descendant_id, above.depth + below.depth + 1
    from public.org_closure above
    cross join public.org_closure below
    where above.descendant_id = new.parent_id
      and below.ancestor_id   = new.id;
  end if;

  return new;
end;
$$;

create trigger organizations_closure_insert
  after insert on public.organizations
  for each row execute function private.org_closure_on_insert();

create trigger organizations_closure_before_move
  before update of parent_id on public.organizations
  for each row when (old.parent_id is distinct from new.parent_id)
  execute function private.org_closure_before_move();

create trigger organizations_closure_after_move
  after update of parent_id on public.organizations
  for each row when (old.parent_id is distinct from new.parent_id)
  execute function private.org_closure_after_move();

-- ---------------------------------------------------------------------------
-- Visibility functions
--
-- SECURITY DEFINER so they read memberships and org_closure without going
-- back through the memberships policy (the classic infinite-recursion trap
-- with hierarchical RLS). search_path is pinned so they cannot be hijacked.
-- ---------------------------------------------------------------------------

-- Every org the current user can see: the orgs they belong to plus
-- everything below them.
create or replace function private.visible_org_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct c.descendant_id
  from public.memberships m
  join public.org_closure c on c.ancestor_id = m.org_id
  where m.user_id = auth.uid();
$$;

-- Only the orgs strictly below the user's own orgs.
create or replace function private.below_org_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct c.descendant_id
  from public.memberships m
  join public.org_closure c on c.ancestor_id = m.org_id
  where m.user_id = auth.uid()
    and c.depth > 0;
$$;

-- The user's rank in each org they belong to. Used for the "same org" rule:
-- inside your own org you see people ranked below you, not your seniors or
-- peers. Drop this rule if "below" should mean "lower orgs only".
create or replace function private.my_org_ranks()
returns table (org_id uuid, rank int)
language sql
stable
security definer
set search_path = ''
as $$
  select m.org_id, m.rank
  from public.memberships m
  where m.user_id = auth.uid();
$$;

revoke all on function
  private.visible_org_ids(), private.below_org_ids(), private.my_org_ranks(),
  private.org_closure_on_insert(), private.org_closure_before_move(), private.org_closure_after_move()
  from public;
grant usage on schema private to authenticated;
grant execute on function
  private.visible_org_ids(), private.below_org_ids(), private.my_org_ranks()
  to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security: deny by default, one small policy per action.
--
-- Function calls are wrapped in (select ...) so Postgres evaluates them once
-- per query instead of once per row.
-- ---------------------------------------------------------------------------

alter table public.organizations enable row level security;
alter table public.org_closure   enable row level security;
alter table public.memberships   enable row level security;
alter table public.records       enable row level security;

-- Explicit grants instead of relying on project defaults. Grants say which
-- actions an API role may attempt at all; the policies decide which rows.
revoke all on public.organizations, public.memberships, public.records from anon, authenticated;
grant select on public.organizations, public.memberships, public.records to anon, authenticated;
grant insert, update, delete on public.records to authenticated;
-- Server-side admin work (seeding, creating orgs, moving branches, adding
-- members). Newer projects do not grant new tables to service_role by default.
grant select, insert, update, delete on public.organizations, public.memberships, public.records to service_role;

-- The closure table is internal. No policies, and no grants to API roles.
revoke all on public.org_closure from anon, authenticated;

-- Organizations: your own and everything below. Ancestors and siblings
-- are invisible, including their names.
create policy organizations_select on public.organizations
  for select to authenticated
  using (id in (select private.visible_org_ids()));

-- People: yourself, everyone in the orgs below you, and in your own org
-- only the people ranked below you.
create policy memberships_select on public.memberships
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or org_id in (select private.below_org_ids())
    or exists (
      select 1 from private.my_org_ranks() r
      where r.org_id = memberships.org_id
        and memberships.rank > r.rank
    )
  );

-- Records: read and write only inside your branch. WITH CHECK means a user
-- cannot create or move a record into an org outside it.
create policy records_select on public.records
  for select to authenticated
  using (org_id in (select private.visible_org_ids()));

create policy records_insert on public.records
  for insert to authenticated
  with check (org_id in (select private.visible_org_ids()));

create policy records_update on public.records
  for update to authenticated
  using      (org_id in (select private.visible_org_ids()))
  with check (org_id in (select private.visible_org_ids()));

create policy records_delete on public.records
  for delete to authenticated
  using (org_id in (select private.visible_org_ids()));

-- No policies for anon: unauthenticated requests see nothing.
-- Org and membership writes (creating orgs, moving branches, inviting people)
-- go through server-side code with the service role, never the browser.
