// =============================================================================
// sync-roster-from-sheet
//
// Manager-triggered (button in the manager panel), not on a schedule. Reads
// only the name column (Settings!A) plus the manual-config columns for a
// BRAND NEW rep's initial seed (bullpen, caps, raincheck, dine-eligible) —
// then:
//   - a name in the Sheet with no matching Supabase rep -> inserted, seeded
//     from the Sheet's current values for that row.
//   - a non-archived Supabase rep whose name is NOT in the Sheet -> archived
//     (see 20260826120000_archive_reps.sql; never hard-deleted).
//   - a name that exists in BOTH -> left completely alone. Caps/bullpen/dine/
//     raincheck are Supabase-native once a rep exists; re-running this sync
//     must never clobber an edit made in the manager panel.
//
// This intentionally does NOT touch multiplier (owned by
// sync-leaderboard-from-sheet) or anything else already Supabase-native.
//
// Admin-gated: verifies the caller's JWT resolves to a user_roles row with
// role = 'admin' before doing anything. Unlike sync-leaderboard-from-sheet
// (which runs unauthenticated on a timer), this one is invoked by a signed-in
// manager from the browser, so verify_jwt stays at its default (true) and we
// do a second, explicit admin check on top of that.
// =============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SHEET_ID = Deno.env.get('BULLPEN_SHEET_ID') ?? '1zYP1sKG4NYYnv5ojbUTfwlRNbn30EQRkvwK1XG9toB0';
const GOOGLE_SA_EMAIL = Deno.env.get('GOOGLE_SA_EMAIL')!;
const GOOGLE_SA_PRIVATE_KEY = (Deno.env.get('GOOGLE_SA_PRIVATE_KEY') ?? '').replace(/\\n/g, '\n');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('EDGE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const DEFAULT_MIN_CAP = 0;
const DEFAULT_MAX_CAP = 999999999;

// -----------------------------------------------------------------------------
// Google service-account auth (JWT bearer flow) — same as sync-leaderboard-from-sheet.
// -----------------------------------------------------------------------------
function base64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : new Uint8Array(input);
  let str = '';
  bytes.forEach((b) => (str += String.fromCharCode(b)));
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function getGoogleAccessToken(): Promise<string> {
  const header = { alg: 'RS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const claim = {
    iss: GOOGLE_SA_EMAIL,
    scope: 'https://www.googleapis.com/auth/spreadsheets.readonly',
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claim))}`;

  const pemBody = GOOGLE_SA_PRIVATE_KEY
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '');
  const keyBytes = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', cryptoKey, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${base64url(signature)}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!res.ok) throw new Error(`Google token exchange failed: ${res.status} ${await res.text()}`);
  const { access_token } = await res.json();
  return access_token;
}

async function fetchSheetRange(accessToken: string, range: string): Promise<string[][]> {
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${SHEET_ID}/values/${encodeURIComponent(range)}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!res.ok) throw new Error(`Sheets API error for ${range}: ${res.status} ${await res.text()}`);
  const json = await res.json();
  return json.values ?? [];
}

// -----------------------------------------------------------------------------
// Main handler
// -----------------------------------------------------------------------------
Deno.serve(async (req) => {
  try {
    // ---- Admin gate ----
    // Explicitly verify the caller's bearer token via the auth API (not just
    // relying on client-side session state, which doesn't exist server-side).
    const authHeader = req.headers.get('Authorization') ?? '';
    const token = authHeader.replace(/^Bearer\s+/i, '').trim();
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    if (!token) {
      return new Response(JSON.stringify({ error: 'Not signed in.' }), { status: 401 });
    }
    const { data: userData, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Not signed in.' }), { status: 401 });
    }

    const { data: roleRow } = await admin
      .from('user_roles')
      .select('role')
      .eq('user_id', userData.user.id)
      .maybeSingle();
    if (!roleRow || roleRow.role !== 'admin') {
      return new Response(JSON.stringify({ error: 'Admin role required.' }), { status: 403 });
    }

    // ---- Read Settings tab: name (A), bullpen (F), min cap (G), max cap (H),
    //      raincheck (I), dine eligible (K). Generous range; stop at first
    //      blank name so a longer-than-expected roster is never truncated. ----
    const accessToken = await getGoogleAccessToken();
    const settingsRows = await fetchSheetRange(accessToken, 'Settings!A2:K80');

    type SheetRow = { name: string; bullpen: boolean; minCap: number; maxCap: number; raincheck: boolean; dine: boolean };
    const sheetReps: SheetRow[] = [];
    for (const row of settingsRows) {
      const name = (row[0] || '').trim();
      if (!name) break; // first blank name = end of roster
      sheetReps.push({
        name,
        bullpen: String(row[5] ?? '').toUpperCase() === 'TRUE',
        minCap: Number(row[6]) || DEFAULT_MIN_CAP,
        maxCap: Number(row[7]) || DEFAULT_MAX_CAP,
        raincheck: String(row[8] ?? '').toUpperCase() === 'TRUE',
        dine: String(row[10] ?? '').toUpperCase() === 'TRUE',
      });
    }

    const { data: existingReps, error: repsErr } = await admin.from('reps').select('id, name, archived');
    if (repsErr) throw repsErr;

    const existingByName = new Map((existingReps ?? []).map((r) => [r.name.toLowerCase(), r]));
    const sheetNames = new Set(sheetReps.map((r) => r.name.toLowerCase()));

    const summary = { added: [] as string[], archived: [] as string[], unarchived: [] as string[], errors: [] as string[] };

    // ---- Add anyone in the Sheet but not in Supabase ----
    for (const sr of sheetReps) {
      const existing = existingByName.get(sr.name.toLowerCase());
      if (!existing) {
        const { error } = await admin.from('reps').insert({
          name: sr.name,
          bullpen_status: sr.bullpen,
          min_cap: sr.minCap,
          max_cap: sr.maxCap,
          raincheck_status: sr.raincheck,
          dine_eligible: sr.dine,
          multiplier: 1,
        });
        if (error) summary.errors.push(`insert ${sr.name}: ${error.message}`);
        else summary.added.push(sr.name);
      } else if (existing.archived) {
        // Reappeared in the Sheet after being archived — bring them back,
        // but still don't touch caps/bullpen/dine (Supabase-native from here).
        const { error } = await admin.from('reps').update({ archived: false }).eq('id', existing.id);
        if (error) summary.errors.push(`unarchive ${sr.name}: ${error.message}`);
        else summary.unarchived.push(sr.name);
      }
      // else: exists and active — leave every field untouched.
    }

    // ---- Archive anyone active in Supabase but no longer in the Sheet ----
    for (const rep of existingReps ?? []) {
      if (!rep.archived && !sheetNames.has(rep.name.toLowerCase())) {
        const { error } = await admin.from('reps').update({ archived: true, bullpen_status: false }).eq('id', rep.id);
        if (error) summary.errors.push(`archive ${rep.name}: ${error.message}`);
        else summary.archived.push(rep.name);
      }
    }

    return new Response(JSON.stringify(summary), { headers: { 'Content-Type': 'application/json' } });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});
