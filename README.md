# Branch-scoped visibility in Supabase

A small, working example of one rule: in a tree of nested organizations, a person sees their own organization and everything below it in their branch, and nothing else. Not the orgs above them, not the branches beside them, not other trees.

The database enforces the rule with Row Level Security. The application never filters anything, so a bug in the front end or a hand-written API call cannot leak data.

## The example tree

```
Molliteum                     Olivia
├── North Region              Nora (rank 1), Nate (rank 2)
│   ├── Club A                Alice
│   │   └── Team A1           Tom
│   └── Club B                Mia
└── South Region              Sam
    └── Club C                Mia (second membership)

Other Org (separate tree)     Oscar
```

| User | Sees |
|---|---|
| Olivia (root) | the whole Molliteum tree, never Other Org |
| Nora (North) | North, Club A, Team A1, Club B |
| Alice (Club A) | Club A, Team A1 |
| Tom (Team A1) | Team A1 only |
| Mia (Club B and Club C) | exactly those two |
| anonymous | nothing |

## How it works

**Closure table.** `organizations` holds the tree through `parent_id`. `org_closure` holds every ancestor and descendant pair, including each org with itself at depth 0, and triggers keep it current when an org is created or moved. "Everything below X" becomes a single indexed lookup instead of a recursive query inside every policy, so cost stays flat as the tree gets deeper.

**One question, one function.** `private.visible_org_ids()` answers "which orgs can the current user see". Every policy calls it, so the rule lives in one place. The functions are `SECURITY DEFINER` with a pinned `search_path`, which avoids the infinite recursion you get when the policy on `memberships` has to read `memberships`, and they sit in a schema the API does not expose.

**Small policies.** Each policy reduces to something like:

```sql
using (org_id in (select private.visible_org_ids()))
```

Wrapping the call in `select` lets Postgres evaluate it once per query instead of once per row. Inserts and updates use `with check`, so a user cannot create a row in another branch or move one there.

**People inside the same org.** Below means lower orgs, and inside your own org it means people ranked below you. Nate and Nora are both in North, but Nate does not see Nora because she ranks above him. If Molliteum's rule is simply "lower orgs only", that part is one clause in one policy and comes out cleanly.

**Moving a branch.** Re-parenting an org updates the closure rows for its whole subtree in one statement, and visibility follows immediately. Moving an org under one of its own descendants is rejected, so the tree cannot become a loop.

**Locked down by default.** RLS is on for every table. The closure table has no grants for API roles at all. Creating orgs, moving branches and adding members happen server side with the service role, never from the browser, so nobody can add themselves to a higher org to widen their own access.

A note on `FORCE ROW LEVEL SECURITY`: it is not used here on purpose. The API roles never own the tables, so enabling RLS already applies to them, and forcing it would also apply the policies inside the definer functions and bring back the recursion those functions exist to avoid.

## Tests

`supabase/tests/database/branch_visibility.test.sql` is a pgTAP suite that logs in as users at different points in the tree and checks each one sees exactly their branch. It covers reads, people, writes into other branches, privilege escalation, moving a branch, and attempts to corrupt the tree. It runs in a transaction and rolls back.

```
ok 1 - Team A1 sits three levels below Molliteum
ok 2 - Team A1 has four ancestors including itself
ok 3 - anon sees no organizations
ok 4 - anon sees no people
ok 5 - anon sees no records
ok 6 - Olivia (root) sees the whole Molliteum tree and not the other tree
ok 7 - Nora sees North and below, not the root above her or South beside her
ok 8 - Nora sees records only in her branch
ok 9 - Alice sees Club A and Team A1, not sibling Club B or North above
ok 10 - Tom at a leaf sees only his own team
ok 11 - Tom sees only his team's records
ok 12 - Sam sees South and Club C, nothing in North
ok 13 - Mia belongs to two branches and sees exactly those two
ok 14 - Oscar in a separate tree never sees Molliteum
ok 15 - Nora sees herself, Nate below her, and everyone in her branch
ok 16 - Nora cannot see Olivia above her or Sam in the South branch
ok 17 - Nora sees Mia's Club B membership but not her Club C one
ok 18 - Nate sees his branch but not Nora, who ranks above him in the same org
ok 19 - Tom at a leaf sees only himself
ok 20 - Alice can create a record in Team A1, below her
ok 21 - Alice cannot create a record in sibling Club B
ok 22 - Alice cannot create a record in North, above her
ok 23 - Alice cannot move a Club A record into Club B
ok 24 - Alice's update against Club B touches zero rows
ok 25 - Alice's delete against North touches zero rows
ok 26 - Users cannot create organizations from the client
ok 27 - Alice cannot add herself to the root to widen her own access
ok 28 - The closure table is not readable from the API
ok 29 - after the move, Club B is directly under South
ok 30 - after the move, North is no longer an ancestor of Club B
ok 31 - Nora loses Club B as soon as it moves out of her branch
ok 32 - Sam gains Club B as soon as it moves into his branch
ok 33 - Sam now sees Mia in both Club B and Club C
ok 34 - Olivia at the root still sees all seven orgs after the move
ok 35 - North cannot be moved under its own descendant Team A1
ok 36 - An org cannot be its own parent
All tests successful.
```

The suite also catches regressions. Loosening the insert policy to `with check (true)` and dropping the same-org rank rule makes tests 18, 21 and 22 fail. That is the point of running it on every pull request (`.github/workflows/rls-tests.yml`): nobody can weaken a policy without CI going red.

## Live demo page

The Next.js page at the root of this repo is a live version of the same rule. Pick a person and the browser signs in as them with the public anon key, then runs the same three unfiltered queries for everyone. The tree lights up only what the database returned. You can also try a write inside your branch (accepted, then removed) and one outside it (rejected by Postgres).

Deploying it:

1. Create a Supabase project. In Authentication settings, turn off new user signups.
2. Run `supabase/migrations/20261111000000_branch_scoped_visibility.sql` in the SQL editor (or `supabase db push`).
3. Seed the demo data from your machine. The service role key stays local and never goes to Vercel:
   ```bash
   npm install
   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... DEMO_PASSWORD=... npm run seed
   ```
4. Import the repo in Vercel and set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_DEMO_PASSWORD` (same value as `DEMO_PASSWORD`) and `NEXT_PUBLIC_REPO_URL`. Deploy.

The demo password is public on purpose: these accounts exist only to show what each person can see, and RLS is the only thing standing between them and everything else.

## Running the tests

In a Supabase project, put the migration in `supabase/migrations/` and the test in `supabase/tests/database/`, then:

```bash
supabase db reset
supabase test db
```

Against plain Postgres 16 with pgTAP installed (this is what CI does):

```bash
DATABASE_URL=postgres://postgres@localhost:5432/postgres ./scripts/test-local.sh
```

`scripts/local-supabase-shim.sql` stands in for the pieces Supabase already provides (the `auth` schema, `auth.uid()` and the API roles) so the same migration runs unchanged in both places.

## Files

```
supabase/migrations/20261111000000_branch_scoped_visibility.sql   schema, triggers, functions, policies
supabase/tests/database/branch_visibility.test.sql                36 pgTAP tests
scripts/local-supabase-shim.sql                                   Supabase auth stand-in for plain Postgres
scripts/test-local.sh                                             migration + tests in one command
.github/workflows/rls-tests.yml                                   runs the suite on every PR
```
