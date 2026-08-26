// =============================================================================
// sync-leaderboard-from-sheet
//
// The ONLY thing this function does: read the Leaderboard tab's already-
// computed numbers (connects, units, revenue, SQL rate, weighted score, rank)
// out of the existing Google Sheet via the read-only Sheets API, and copy them
// into `leaderboard_snapshot`. It then computes each rep's `multiplier`
// itself, in Supabase, from the rank it just read — same rank-based formula
// the old script used (best rank -> 2.25, worst -> 0.75, evenly spaced) — so
// the Sheet's Settings tab is never read at all.
//
// Everything else (bullpen_status, caps, raincheck_status, dine_eligible,
// and now the multiplier formula itself) is Supabase-native and edited only
// through the app / SQL editor. This function has no write access to any of
// that, and no read dependency on it either.
//
// This is a bridge: the old Apps Script Daily Updater keeps running
// unchanged and still does the actual Zoom/NetSuite parsing to produce the
// Leaderboard tab. When that gets rebuilt as direct Drive-report parsing,
// this file is what gets replaced — nothing downstream changes, since
// everything else just reads leaderboard_snapshot / reps.multiplier.
// =============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SHEET_ID = Deno.env.get('BULLPEN_SHEET_ID') ?? '1zYP1sKG4NYYnv5ojbUTfwlRNbn30EQRkvwK1XG9toB0';
const GOOGLE_SA_EMAIL = Deno.env.get('GOOGLE_SA_EMAIL')!;
const GOOGLE_SA_PRIVATE_KEY = (Deno.env.get('GOOGLE_SA_PRIVATE_KEY') ?? '').replace(/\\n/g, '\n');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
// This project uses Supabase's newer key system, where the auto-injected
// SUPABASE_SERVICE_ROLE_KEY doesn't reliably grant full access. EDGE_SERVICE_ROLE_KEY
// is a custom secret (set manually from Project Settings -> API Keys -> service_role)
// that we know works; SUPABASE_SERVICE_ROLE_KEY is kept as a fallback for older projects.
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('EDGE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Rank-based multiplier — ported from the old script's updateAutoMultiplier().
const MIN_MULT = 0.75; // worst rank
const MAX_MULT = 2.25; // rank 1

// -----------------------------------------------------------------------------
// Google service-account auth (JWT bearer flow) — Web Crypto only, no library.
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
// Called both from cron/manual URL visit AND now from a "Sync Leaderboard"
// button in the manager panel (a cross-origin POST from the browser), so it
// needs the same CORS preflight handling as sync-roster-from-sheet.
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  try {
    const accessToken = await getGoogleAccessToken();
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const today = new Date().toISOString().slice(0, 10);
    const summary = { leaderboard_rows: 0, multiplier_updates: 0, skipped_no_data: false, errors: [] as string[] };

    // ---- The ONLY sheet read: Leaderboard!A2:G16 ----
    // Columns: name, connects, units, revenue, sql%, weighted score, rank.
    // Bounded well before row 18, where a second, duplicate "SE LEADERBOARD"
    // sorted display table (same tab, cols A-F) lives — that block would
    // otherwise get scooped up too. Widened from G12 to G16 (2026-08-26) now
    // that the roster is 12 SEs instead of 10 — G12 was silently dropping the
    // last couple of reps. Bump this again if the roster grows past ~14.
    // The break-on-"Total"/"Weightings" guard below is a second layer of
    // protection either way.
    const leaderboardRows = await fetchSheetRange(accessToken, 'Leaderboard!A2:G16');

    const parsed: { name: string; connects: number; units: number; revenue: number; sqlRate: number; weightedScore: number; rank: number | null }[] = [];
    for (const row of leaderboardRows) {
      const [name, connects, units, revenue, sqlPct, weightedScore, rank] = row;
      if (!name) continue;
      // Stop before the Total/Weightings summary rows and the duplicate sorted
      // display table further down the same tab (both share this A2:G range).
      if (['total', 'weightings'].includes(name.toLowerCase())) break;
      parsed.push({
        name,
        connects: Number(connects) || 0,
        units: Number(units) || 0,
        revenue: Number(revenue) || 0,
        sqlRate: Number(sqlPct) || 0,
        weightedScore: Number(weightedScore) || 0,
        rank: rank ? Number(rank) : null,
      });
    }

    // Guard, same as the old script: if every weighted score is 0, there's no
    // real data for today (weekend/holiday/report not in yet) — don't write
    // ranks or recompute multipliers off of garbage, leave things as they are.
    const hasRealData = parsed.some((r) => r.weightedScore > 0);

    for (const r of parsed) {
      const { data: rep, error: repErr } = await supabase.from('reps').select('id').eq('name', r.name).maybeSingle();
      if (repErr || !rep) { summary.errors.push(`No rep found for Leaderboard row: ${r.name}`); continue; }

      const { error } = await supabase.from('leaderboard_snapshot').upsert({
        rep_id: rep.id,
        report_date: today,
        connects: r.connects,
        units_closed: r.units,
        revenue_closed: r.revenue,
        sql_rate: r.sqlRate,
        weighted_score: r.weightedScore,
        rank: r.rank,
      }, { onConflict: 'rep_id,report_date' });
      if (error) summary.errors.push(`leaderboard upsert failed for ${r.name}: ${error.message}`);
      else summary.leaderboard_rows++;
    }

    // ---- Multiplier: computed here, from rank, not read from the Sheet ----
    if (!hasRealData) {
      summary.skipped_no_data = true;
    } else {
      const n = parsed.length;
      const step = n > 1 ? (MAX_MULT - MIN_MULT) / (n - 1) : 0;
      for (const r of parsed) {
        if (r.rank === null) continue;
        const multiplier = Math.round((MAX_MULT - (r.rank - 1) * step) * 100) / 100;
        const { error } = await supabase.from('reps')
          .update({ multiplier, updated_at: new Date().toISOString() })
          .eq('name', r.name);
        if (error) summary.errors.push(`multiplier update failed for ${r.name}: ${error.message}`);
        else summary.multiplier_updates++;
      }
    }

    return new Response(JSON.stringify(summary), { headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
  }
});
