// Seeds the demo tree, people and records into a Supabase project.
// Run once, locally, with the service role key. Never ship that key to the browser.
//
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... DEMO_PASSWORD=... npm run seed
//
// Safe to run again: existing orgs and users are reused, records are reset.
import { createClient } from "@supabase/supabase-js";
import data from "../lib/demo-data.json" with { type: "json" };

const url = process.env.SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const password = process.env.DEMO_PASSWORD;
if (!url || !serviceKey || !password) {
  console.error("Set SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and DEMO_PASSWORD.");
  process.exit(1);
}

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

function check(error, what) {
  if (error) {
    console.error(`${what}: ${error.message}`);
    process.exit(1);
  }
}

// Organizations, parents before children, so the closure triggers can run.
const { data: existing, error: listOrgsErr } = await admin.from("organizations").select("id");
check(listOrgsErr, "list organizations");
const have = new Set(existing.map((o) => o.id));
for (const org of data.orgs) {
  if (have.has(org.id)) continue;
  const { error } = await admin
    .from("organizations")
    .insert({ id: org.id, parent_id: org.parentId, name: org.name });
  check(error, `insert ${org.name}`);
}
console.log(`organizations: ${data.orgs.length}`);

// Users: reuse by email, otherwise create with the demo password.
const { data: userPage, error: listUsersErr } = await admin.auth.admin.listUsers({ perPage: 1000 });
check(listUsersErr, "list users");
const byEmail = new Map(userPage.users.map((u) => [u.email, u.id]));

for (const p of data.personas) {
  let id = byEmail.get(p.email);
  if (!id) {
    const { data: created, error } = await admin.auth.admin.createUser({
      email: p.email,
      password,
      email_confirm: true,
    });
    check(error, `create ${p.email}`);
    id = created.user.id;
  } else {
    const { error } = await admin.auth.admin.updateUserById(id, { password });
    check(error, `update ${p.email}`);
  }

  for (const m of p.memberships) {
    const { error } = await admin.from("memberships").upsert(
      { user_id: id, org_id: m.orgId, rank: m.rank, role: m.role, display_name: p.name },
      { onConflict: "user_id,org_id" },
    );
    check(error, `membership ${p.name}`);
  }
}
console.log(`people: ${data.personas.length}`);

// One record per org.
const { error: delErr } = await admin.from("records").delete().in("org_id", data.orgs.map((o) => o.id));
check(delErr, "reset records");
const { error: recErr } = await admin
  .from("records")
  .insert(data.orgs.map((o) => ({ org_id: o.id, title: `${o.name} record` })));
check(recErr, "insert records");
console.log(`records: ${data.orgs.length}`);
console.log("Seed complete.");
