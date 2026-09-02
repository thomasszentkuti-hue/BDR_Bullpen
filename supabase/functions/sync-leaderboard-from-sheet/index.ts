// =============================================================================
// sync-leaderboard-from-sheet
//
// NOTE ON THE NAME: this function is no longer what its name says. It was
// originally a pull-based function that read the Leaderboard tab out of a
// Google Sheet via the Sheets API. As of 2026-09-01, the leaderboard source
// moved to an Excel workbook driven by an Office Script + Power Automate
// flow, and this function was redeployed under this SAME slug as a
// push-based receiver instead. Renaming the slug to something like
// `sync-leaderboard-from-excel` was considered and deliberately deferred as
// cosmetic cleanup, not a functional need — so the URL Power Automate posts
// to, and the folder name in this repo, both stay `sync-leaderboard-from-sheet`
// even though nothing here talks to Google Sheets anymore. Don't restore the
// old Google Sheets version of this file from git history without knowing
// that's what you're doing — it would silently break the live Power
// Automate integration.
//
// What this function does now: Power Automate's "Bullpen Daily Updater" flow
// runs its Office Script, computes the day's leaderboard numbers inside the
// Excel workbook, and POSTs them here directly — no Google Sheets API, no
// service-account JWT. The POST body shape is
//   { reportDateStr: "yyyy-MM-dd", rows: [{ name, connects, units, revenue,
//     sqlRate, weightedScore, rank }, ...] }
// matching what the workbook's DailyUpdate.office.ts / buildLeaderboardSnapshot()
// produces. Everything downstream (leaderboard_snapshot upsert, the
// rank-based multiplier formula, the "all weighted scores 0 => skip" guard)
// is unchanged from the original pull-based version.
//
// AUTH: this function is reachable from outside Supabase (Power Automate's
// HTTP action), so — unlike a same-origin browser call — every request must
// carry a matching `x-sync-secret` header, checked against the
// EXCEL_SYNC_SECRET secret set in this project's Edge Function secrets.
// Requests without a matching header are rejected before anything is parsed
// or written. supabase/config.toml has verify_jwt = false for this function,
// which is correct and required — Power Automate has no Supabase user
// session to send a JWT with; this shared secret is the only auth layer.
// =============================================================================

// Pinned exact version — was unpinned (`@2`) until 2026-09-02, which let esm.sh
// resolve to whatever the latest 2.x.y happened to be at each redeploy. That
// turned out to matter: a version drift changed how upsert's merge-duplicates
// behaviour was being applied, causing every write here to report success
// while silently affecting 0 rows (RLS/grants/triggers were all fine — this
// was the actual cause of the multi-hour "writes succeed but nothing
// persists" leaderboard bug). Do not remove the pin without re-verifying
// upsert-on-conflict still behaves as expected.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
// Same key fallback as the rest of this project's functions — the
// auto-injected SUPABASE_SERVICE_ROLE_KEY doesn't reliably grant full
// access, so EDGE_SERVICE_ROLE_KEY (set manually from Project Settings ->
// API Keys) is tried first.
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('EDGE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const EXCEL_SYNC_SECRET = Deno.env.get('EXCEL_SYNC_SECRET');

// Rank-based multiplier — identical formula to the original Sheets version.
const MIN_MULT = 0.75; // worst rank
const MAX_MULT = 2.25; // rank 1

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-sync-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface IncomingRow {
  name: string;
  connects: number;
  units: number;
  revenue: number;
  sqlRate: number;
  weightedScore: number;
  rank: number | null;
}

interface IncomingPayload {
  reportDateStr: string;
  rows: IncomingRow[];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), {
      status: 405,
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    });
  }

  // ---- Auth: shared-secret header from the Power Automate flow ----
  if (!EXCEL_SYNC_SECRET) {
    console.error('EXCEL_SYNC_SECRET is not set for this function — refusing all requests until it is.');
    return new Response(JSON.stringify({ error: 'server not configured' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    });
  }
  const providedSecret = req.headers.get('x-sync-secret');
  if (providedSecret !== EXCEL_SYNC_SECRET) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    });
  }

  const summary = { leaderboard_rows: 0, multiplier_updates: 0, skipped_no_data: false, errors: [] as string[] };

  try {
    let payload: IncomingPayload;
    try {
      payload = await req.json();
    } catch {
      return new Response(JSON.stringify({ error: 'invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
      });
    }

    const reportDateStr = payload?.reportDateStr;
    const rows = payload?.rows;

    if (typeof reportDateStr !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(reportDateStr)) {
      return new Response(JSON.stringify({ error: 'reportDateStr must be a "yyyy-MM-dd" string' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
      });
    }
    if (!Array.isArray(rows)) {
      return new Response(JSON.stringify({ error: 'rows must be an array' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
      });
    }

    // If nothing has a real weighted score, today's report is empty
    // (weekend/holiday/not-yet-arrived) — the flow's own Condition should
    // already have caught this before pushing, but the guard stays here too
    // as a second layer, same as the original pull-based version.
    const hasRealData = rows.some((r) => Number(r.weightedScore) > 0);

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    for (const r of rows) {
      const name = String(r.name ?? '').trim();
      if (!name) { summary.errors.push('row with no name, skipped'); continue; }

      const { data: rep, error: repErr } = await supabase.from('reps').select('id').eq('name', name).maybeSingle();
      if (repErr || !rep) { summary.errors.push(`No rep found for Leaderboard row: ${name}`); continue; }

      // ignoreDuplicates: false is explicit here (not just relying on the
      // client default) so this always does ON CONFLICT DO UPDATE, never
      // DO NOTHING. .select() forces Prefer: return=representation, so
      // PostgREST actually hands back the row it wrote — without this, a
      // 0-row-affected upsert (RLS, a stale conflict target, anything) looks
      // identical to a real success. Checking written.length is what makes a
      // silent no-op fail loudly instead of quietly doing nothing forever.
      const { data: written, error } = await supabase.from('leaderboard_snapshot').upsert({
        rep_id: rep.id,
        report_date: reportDateStr,
        connects: Number(r.connects) || 0,
        units_closed: Number(r.units) || 0,
        revenue_closed: Number(r.revenue) || 0,
        sql_rate: Number(r.sqlRate) || 0,
        weighted_score: Number(r.weightedScore) || 0,
        rank: r.rank === null || r.rank === undefined ? null : Number(r.rank),
      }, { onConflict: 'rep_id,report_date', ignoreDuplicates: false })
        .select('rep_id, report_date, weighted_score, rank');
      if (error) summary.errors.push(`leaderboard upsert failed for ${name}: ${error.message}`);
      else if (!written || written.length === 0) summary.errors.push(`leaderboard upsert for ${name} reported success but wrote 0 rows — check RLS/constraints`);
      else summary.leaderboard_rows++;
    }

    // ---- Multiplier: same rank-based formula as before ----
    if (!hasRealData) {
      summary.skipped_no_data = true;
    } else {
      const n = rows.length;
      const step = n > 1 ? (MAX_MULT - MIN_MULT) / (n - 1) : 0;
      for (const r of rows) {
        const name = String(r.name ?? '').trim();
        if (!name || r.rank === null || r.rank === undefined) continue;
        const multiplier = Math.round((MAX_MULT - (Number(r.rank) - 1) * step) * 100) / 100;
        const { data: updated, error } = await supabase.from('reps')
          .update({ multiplier, updated_at: new Date().toISOString() })
          .eq('name', name)
          .select('id');
        if (error) summary.errors.push(`multiplier update failed for ${name}: ${error.message}`);
        else if (!updated || updated.length === 0) summary.errors.push(`multiplier update for ${name} reported success but wrote 0 rows`);
        else summary.multiplier_updates++;
      }
    }

    return new Response(JSON.stringify(summary), { headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    });
  }
});
