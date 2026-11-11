"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { ORGS, PERSONAS, depthOf, type Persona } from "@/lib/demo";

type Member = { display_name: string; org_id: string; rank: number; role: string };
type Rec = { title: string; org_id: string };
type Result = {
  orgIds: Set<string>;
  members: Member[];
  records: Rec[];
  ms: number;
};
type WriteResult = { ok: boolean; text: string } | null;

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const password = process.env.NEXT_PUBLIC_DEMO_PASSWORD;
const repoUrl = process.env.NEXT_PUBLIC_REPO_URL;
const configured = Boolean(url && anonKey && password);

export default function Page() {
  const clientRef = useRef<SupabaseClient | null>(null);
  const [active, setActive] = useState<Persona | null | undefined>(undefined);
  const [result, setResult] = useState<Result | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [inside, setInside] = useState<WriteResult>(null);
  const [outside, setOutside] = useState<WriteResult>(null);

  function client() {
    if (!clientRef.current) {
      clientRef.current = createClient(url!, anonKey!, {
        auth: { persistSession: false, autoRefreshToken: false },
      });
    }
    return clientRef.current;
  }

  async function view(p: Persona | null) {
    setActive(p);
    setLoading(true);
    setError(null);
    setInside(null);
    setOutside(null);
    const sb = client();
    try {
      await sb.auth.signOut();
      if (p) {
        const { error } = await sb.auth.signInWithPassword({ email: p.email, password: password! });
        if (error) throw new Error(`Sign-in failed: ${error.message}`);
      }
      const t0 = performance.now();
      // No filters. Whatever comes back is decided by the database.
      const [orgs, members, records] = await Promise.all([
        sb.from("organizations").select("id, name"),
        sb.from("memberships").select("display_name, org_id, rank, role"),
        sb.from("records").select("title, org_id"),
      ]);
      const ms = Math.round(performance.now() - t0);
      for (const r of [orgs, members, records]) if (r.error) throw new Error(r.error.message);
      setResult({
        orgIds: new Set((orgs.data ?? []).map((o) => o.id)),
        members: (members.data ?? []) as Member[],
        records: (records.data ?? []) as Rec[],
        ms,
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setResult(null);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (configured) view(PERSONAS[1]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const visible = result?.orgIds ?? new Set<string>();
  const ownOrgId = active?.memberships[0]?.orgId;
  const outsideTarget = useMemo(() => {
    if (!active) return ORGS[0];
    // Prefer an org in the same tree (a parent or sibling), which is the case that matters.
    return ORGS.find((o) => !visible.has(o.id) && o.name !== "Other Org") ?? ORGS.find((o) => !visible.has(o.id));
  }, [active, visible]);

  async function writeInside() {
    if (!ownOrgId) return;
    const org = ORGS.find((o) => o.id === ownOrgId)!;
    const sb = client();
    const { data, error } = await sb
      .from("records")
      .insert({ org_id: ownOrgId, title: "Demo write, removed immediately" })
      .select("id")
      .single();
    if (error) return setInside({ ok: false, text: error.message });
    await sb.from("records").delete().eq("id", data.id);
    setInside({ ok: true, text: `Accepted. Wrote a record into ${org.name}, then removed it.` });
  }

  async function writeOutside() {
    if (!outsideTarget) return;
    const { error } = await client()
      .from("records")
      .insert({ org_id: outsideTarget.id, title: "Should never land" });
    setOutside(
      error
        ? { ok: false, text: `Rejected by Postgres: ${error.message}` }
        : { ok: true, text: "Accepted. This should not happen." },
    );
  }

  return (
    <main className="wrap">
      <header className="hero">
        <p className="eyebrow">Supabase · Row Level Security · live</p>
        <h1>Branch-scoped visibility</h1>
        <p className="lede">
          Pick a person. The browser signs in as them with the public anon key and asks the database for every
          organization, person and record, with no filters at all. What comes back is decided by Postgres alone.
        </p>
      </header>

      {!configured ? (
        <section className="card notice">
          <h2>Not connected yet</h2>
          <p>
            Set <code>NEXT_PUBLIC_SUPABASE_URL</code>, <code>NEXT_PUBLIC_SUPABASE_ANON_KEY</code> and{" "}
            <code>NEXT_PUBLIC_DEMO_PASSWORD</code>, run the migration and <code>npm run seed</code>. The README has
            the steps.
          </p>
        </section>
      ) : (
        <>
          <nav className="people" aria-label="Sign in as">
            {PERSONAS.map((p) => (
              <button
                key={p.email}
                className={`chip ${active?.email === p.email ? "on" : ""}`}
                onClick={() => view(p)}
                disabled={loading}
              >
                <span className="chip-name">{p.name}</span>
                <span className="chip-where">{p.where}</span>
              </button>
            ))}
            <button className={`chip ${active === null ? "on" : ""}`} onClick={() => view(null)} disabled={loading}>
              <span className="chip-name">Anonymous</span>
              <span className="chip-where">not signed in</span>
            </button>
          </nav>

          {error && <p className="err">{error}</p>}

          <div className="grid">
            <section className="card">
              <div className="card-head">
                <h2>Organizations</h2>
                <span className="meta">
                  {loading ? "querying…" : result ? `${visible.size} of ${ORGS.length} returned · ${result.ms} ms` : ""}
                </span>
              </div>
              <ul className="tree">
                {ORGS.map((o) => {
                  const shown = visible.has(o.id);
                  const people = result?.members.filter((m) => m.org_id === o.id) ?? [];
                  return (
                    <li
                      key={o.id}
                      className={`node ${shown ? "shown" : "hidden"} ${o.parentId ? "" : "root"}`}
                      style={{ paddingLeft: `${depthOf(o) * 22 + 12}px` }}
                    >
                      <span className="dot" aria-hidden />
                      <span className="org-name">{o.name}</span>
                      {shown ? (
                        <span className="who">{people.map((m) => m.display_name).join(", ") || "no one visible"}</span>
                      ) : (
                        <span className="who">not returned</span>
                      )}
                    </li>
                  );
                })}
              </ul>
              <p className="hint">
                Dimmed rows are drawn from the page&apos;s own copy of the tree. The database never sent them.
              </p>
            </section>

            <div className="stack">
              <section className="card">
                <div className="card-head">
                  <h2>People</h2>
                  <span className="meta">{result ? `${result.members.length} returned` : ""}</span>
                </div>
                {result && result.members.length > 0 ? (
                  <ul className="list">
                    {result.members.map((m, i) => (
                      <li key={i}>
                        <strong>{m.display_name}</strong>
                        <span>
                          {ORGS.find((o) => o.id === m.org_id)?.name} · rank {m.rank}
                        </span>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="empty">Nothing returned.</p>
                )}
              </section>

              <section className="card">
                <h2>Writes</h2>
                {active ? (
                  <>
                    <div className="write">
                      <button className="btn" onClick={writeInside}>
                        Write into {ORGS.find((o) => o.id === ownOrgId)?.name}
                      </button>
                      {inside && <p className={inside.ok ? "good" : "bad"}>{inside.text}</p>}
                    </div>
                    {outsideTarget && (
                      <div className="write">
                        <button className="btn ghost" onClick={writeOutside}>
                          Try writing into {outsideTarget.name}
                        </button>
                        {outside && <p className={outside.ok ? "bad" : "good"}>{outside.text}</p>}
                      </div>
                    )}
                  </>
                ) : (
                  <p className="empty">Sign in as someone to try writing.</p>
                )}
              </section>

              <section className="card code">
                <h2>What the browser asks</h2>
                <pre>{`supabase.from("organizations").select("id, name")
supabase.from("memberships").select("display_name, org_id, rank, role")
supabase.from("records").select("title, org_id")`}</pre>
                <p className="hint">The same three queries for everyone. The policies do the rest:</p>
                <pre>{`using (org_id in (select private.visible_org_ids()))`}</pre>
              </section>
            </div>
          </div>
        </>
      )}

      <footer className="foot">
        <span>Closure table + one SECURITY DEFINER function + small RLS policies, covered by 36 pgTAP tests.</span>
        {repoUrl && (
          <a href={repoUrl} target="_blank" rel="noreferrer">
            Source and tests
          </a>
        )}
      </footer>
    </main>
  );
}
