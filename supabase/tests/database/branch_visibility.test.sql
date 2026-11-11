-- Branch-scoped visibility tests.
-- Each test logs in as a user at a different point in the tree and checks
-- they see exactly their branch: nothing above, beside, or in other trees.
-- Runs inside a transaction and rolls back, so it never touches real data.

begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(36);

-- ---------------------------------------------------------------------------
-- Fixture
--
-- Molliteum
-- ├── North Region           Nora (rank 1), Nate (rank 2)
-- │   ├── Club A             Alice
-- │   │   └── Team A1        Tom
-- │   └── Club B             Mia
-- └── South Region           Sam
--     └── Club C             Mia (second membership)
-- Olivia is at the root.
--
-- Other Org (a separate tree)  Oscar
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('22222222-0000-0000-0000-000000000001', 'olivia@test'),
  ('22222222-0000-0000-0000-000000000002', 'nora@test'),
  ('22222222-0000-0000-0000-000000000003', 'nate@test'),
  ('22222222-0000-0000-0000-000000000004', 'alice@test'),
  ('22222222-0000-0000-0000-000000000005', 'tom@test'),
  ('22222222-0000-0000-0000-000000000006', 'sam@test'),
  ('22222222-0000-0000-0000-000000000007', 'mia@test'),
  ('22222222-0000-0000-0000-000000000008', 'oscar@test');

insert into public.organizations (id, parent_id, name) values
  ('11111111-0000-0000-0000-000000000001', null,                                   'Molliteum'),
  ('11111111-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', 'North Region'),
  ('11111111-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001', 'South Region'),
  ('11111111-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000002', 'Club A'),
  ('11111111-0000-0000-0000-000000000005', '11111111-0000-0000-0000-000000000002', 'Club B'),
  ('11111111-0000-0000-0000-000000000006', '11111111-0000-0000-0000-000000000004', 'Team A1'),
  ('11111111-0000-0000-0000-000000000007', '11111111-0000-0000-0000-000000000003', 'Club C'),
  ('11111111-0000-0000-0000-000000000008', null,                                   'Other Org');

insert into public.memberships (user_id, org_id, rank, role, display_name) values
  ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 1, 'admin',   'Olivia'),
  ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000002', 1, 'manager', 'Nora'),
  ('22222222-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000002', 2, 'staff',   'Nate'),
  ('22222222-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000004', 1, 'manager', 'Alice'),
  ('22222222-0000-0000-0000-000000000005', '11111111-0000-0000-0000-000000000006', 1, 'member',  'Tom'),
  ('22222222-0000-0000-0000-000000000006', '11111111-0000-0000-0000-000000000003', 1, 'manager', 'Sam'),
  ('22222222-0000-0000-0000-000000000007', '11111111-0000-0000-0000-000000000005', 5, 'member',  'Mia'),
  ('22222222-0000-0000-0000-000000000007', '11111111-0000-0000-0000-000000000007', 5, 'member',  'Mia'),
  ('22222222-0000-0000-0000-000000000008', '11111111-0000-0000-0000-000000000008', 1, 'admin',   'Oscar');

insert into public.records (org_id, title)
select id, name || ' record' from public.organizations;

-- ---------------------------------------------------------------------------
-- Closure table is built correctly
-- ---------------------------------------------------------------------------

select is(
  (select depth from public.org_closure
   where ancestor_id = '11111111-0000-0000-0000-000000000001'
     and descendant_id = '11111111-0000-0000-0000-000000000006'),
  3,
  'Team A1 sits three levels below Molliteum'
);

select is(
  (select count(*)::int from public.org_closure
   where descendant_id = '11111111-0000-0000-0000-000000000006'),
  4,
  'Team A1 has four ancestors including itself'
);

-- ---------------------------------------------------------------------------
-- Anonymous: nothing
-- ---------------------------------------------------------------------------

set local role anon;
select set_config('request.jwt.claims', '', true);

select is((select count(*)::int from public.organizations), 0, 'anon sees no organizations');
select is((select count(*)::int from public.memberships),   0, 'anon sees no people');
select is((select count(*)::int from public.records),       0, 'anon sees no records');

-- ---------------------------------------------------------------------------
-- Organizations each user can see
-- ---------------------------------------------------------------------------

set local role authenticated;

-- Olivia, root
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000001"}', true);
select set_eq(
  'select name from public.organizations',
  array['Molliteum','North Region','South Region','Club A','Club B','Team A1','Club C'],
  'Olivia (root) sees the whole Molliteum tree and not the other tree'
);

-- Nora, North Region
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000002"}', true);
select set_eq(
  'select name from public.organizations',
  array['North Region','Club A','Club B','Team A1'],
  'Nora sees North and below, not the root above her or South beside her'
);
select set_eq(
  'select title from public.records',
  array['North Region record','Club A record','Club B record','Team A1 record'],
  'Nora sees records only in her branch'
);

-- Alice, Club A
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000004"}', true);
select set_eq(
  'select name from public.organizations',
  array['Club A','Team A1'],
  'Alice sees Club A and Team A1, not sibling Club B or North above'
);

-- Tom, Team A1 (a leaf)
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000005"}', true);
select set_eq(
  'select name from public.organizations',
  array['Team A1'],
  'Tom at a leaf sees only his own team'
);
select set_eq(
  'select title from public.records',
  array['Team A1 record'],
  'Tom sees only his team''s records'
);

-- Sam, South Region
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000006"}', true);
select set_eq(
  'select name from public.organizations',
  array['South Region','Club C'],
  'Sam sees South and Club C, nothing in North'
);

-- Mia, member of Club B and Club C
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000007"}', true);
select set_eq(
  'select name from public.organizations',
  array['Club B','Club C'],
  'Mia belongs to two branches and sees exactly those two'
);

-- Oscar, a different tree
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000008"}', true);
select set_eq(
  'select name from public.organizations',
  array['Other Org'],
  'Oscar in a separate tree never sees Molliteum'
);

-- ---------------------------------------------------------------------------
-- People each user can see
-- ---------------------------------------------------------------------------

-- Nora: herself, Nate (ranked below her in North), and everyone in orgs below.
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000002"}', true);
select set_eq(
  'select display_name || '' @ '' || o.name
   from public.memberships m join public.organizations o on o.id = m.org_id',
  array['Nora @ North Region','Nate @ North Region','Alice @ Club A','Tom @ Team A1','Mia @ Club B'],
  'Nora sees herself, Nate below her, and everyone in her branch'
);
select is(
  (select count(*)::int from public.memberships where display_name in ('Olivia','Sam')),
  0,
  'Nora cannot see Olivia above her or Sam in the South branch'
);
select is(
  (select count(*)::int from public.memberships
   where display_name = 'Mia' and org_id = '11111111-0000-0000-0000-000000000007'),
  0,
  'Nora sees Mia''s Club B membership but not her Club C one'
);

-- Nate: same org as Nora but ranked below her.
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000003"}', true);
select set_eq(
  'select display_name from public.memberships',
  array['Nate','Alice','Tom','Mia'],
  'Nate sees his branch but not Nora, who ranks above him in the same org'
);

-- Tom: only himself.
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000005"}', true);
select set_eq(
  'select display_name from public.memberships',
  array['Tom'],
  'Tom at a leaf sees only himself'
);

-- ---------------------------------------------------------------------------
-- Writes stay inside the branch
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000004"}', true);

select lives_ok(
  $$insert into public.records (org_id, title)
    values ('11111111-0000-0000-0000-000000000006', 'Alice note for Team A1')$$,
  'Alice can create a record in Team A1, below her'
);

select throws_ok(
  $$insert into public.records (org_id, title)
    values ('11111111-0000-0000-0000-000000000005', 'Alice note for Club B')$$,
  '42501',
  null,
  'Alice cannot create a record in sibling Club B'
);

select throws_ok(
  $$insert into public.records (org_id, title)
    values ('11111111-0000-0000-0000-000000000002', 'Alice note for North')$$,
  '42501',
  null,
  'Alice cannot create a record in North, above her'
);

select throws_ok(
  $$update public.records set org_id = '11111111-0000-0000-0000-000000000005'
    where title = 'Club A record'$$,
  '42501',
  null,
  'Alice cannot move a Club A record into Club B'
);

select is_empty(
  $$update public.records set title = 'tampered'
    where org_id = '11111111-0000-0000-0000-000000000005' returning id$$,
  'Alice''s update against Club B touches zero rows'
);

select is_empty(
  $$delete from public.records
    where org_id = '11111111-0000-0000-0000-000000000002' returning id$$,
  'Alice''s delete against North touches zero rows'
);

select throws_ok(
  $$insert into public.organizations (name, parent_id)
    values ('Rogue Org', '11111111-0000-0000-0000-000000000004')$$,
  '42501',
  null,
  'Users cannot create organizations from the client'
);

select throws_ok(
  $$insert into public.memberships (user_id, org_id, rank, display_name)
    values ('22222222-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000001', 1, 'Alice')$$,
  '42501',
  null,
  'Alice cannot add herself to the root to widen her own access'
);

select throws_ok(
  'select * from public.org_closure',
  '42501',
  null,
  'The closure table is not readable from the API'
);

-- ---------------------------------------------------------------------------
-- Moving a branch: visibility follows the tree immediately
-- ---------------------------------------------------------------------------

reset role;
update public.organizations
set parent_id = '11111111-0000-0000-0000-000000000003'   -- Club B moves under South
where id = '11111111-0000-0000-0000-000000000005';

select is(
  (select depth from public.org_closure
   where ancestor_id = '11111111-0000-0000-0000-000000000003'
     and descendant_id = '11111111-0000-0000-0000-000000000005'),
  1,
  'after the move, Club B is directly under South'
);
select is(
  (select count(*)::int from public.org_closure
   where ancestor_id = '11111111-0000-0000-0000-000000000002'
     and descendant_id = '11111111-0000-0000-0000-000000000005'),
  0,
  'after the move, North is no longer an ancestor of Club B'
);

set local role authenticated;

select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000002"}', true);
select set_eq(
  'select name from public.organizations',
  array['North Region','Club A','Team A1'],
  'Nora loses Club B as soon as it moves out of her branch'
);

select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000006"}', true);
select set_eq(
  'select name from public.organizations',
  array['South Region','Club B','Club C'],
  'Sam gains Club B as soon as it moves into his branch'
);
select set_eq(
  'select display_name from public.memberships',
  array['Sam','Mia','Mia'],
  'Sam now sees Mia in both Club B and Club C'
);

select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000001"}', true);
select is(
  (select count(*)::int from public.organizations),
  7,
  'Olivia at the root still sees all seven orgs after the move'
);

-- ---------------------------------------------------------------------------
-- The tree cannot be corrupted
-- ---------------------------------------------------------------------------

reset role;

select throws_ok(
  $$update public.organizations set parent_id = '11111111-0000-0000-0000-000000000006'
    where id = '11111111-0000-0000-0000-000000000002'$$,
  '23514',
  null,
  'North cannot be moved under its own descendant Team A1'
);

select throws_ok(
  $$update public.organizations set parent_id = id
    where id = '11111111-0000-0000-0000-000000000004'$$,
  '23514',
  null,
  'An org cannot be its own parent'
);

select * from finish();
rollback;
