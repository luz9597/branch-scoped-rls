// The demo tree and people. scripts/seed.mjs creates exactly this in Supabase.
// The page draws the full tree from here so it can show what each person
// does NOT get back; what they DO see always comes from the database.
import data from "./demo-data.json";

export type Org = { id: string; parentId: string | null; name: string };
export type Persona = {
  email: string;
  name: string;
  where: string;
  memberships: { orgId: string; rank: number; role: string }[];
};

export const ORGS: Org[] = data.orgs;
export const PERSONAS: Persona[] = data.personas;

export function depthOf(org: Org): number {
  let d = 0;
  let p = org.parentId;
  while (p) {
    d++;
    p = ORGS.find((o) => o.id === p)?.parentId ?? null;
  }
  return d;
}
