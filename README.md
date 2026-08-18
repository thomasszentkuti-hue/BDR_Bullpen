# BDR_Bullpen

Supabase-backed replacement for the "BDR Bullpen" Google Sheet + Apps Script lead
router. See `docs/BDR_Bullpen_Supabase_Migration_Plan.docx` for the full
architecture, security model, and phased rollout plan.

## Structure

- `supabase/migrations/` — schema + routing engine, applied in order via the
  Supabase CLI or the GitHub integration (Project Settings → Integrations →
  GitHub in the Supabase dashboard, pointed at this repo/branch).
- `docs/` — architecture and rollout plan.

## Local setup

```bash
npm install -g supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase db push
```

`db push` applies every file in `supabase/migrations/` in filename order —
that's why they're timestamp-prefixed. Never edit an already-applied migration
file; add a new one instead, the same way you'd never hand-edit a merged PR.

## Status

- [x] Schema (`reps`, `lead_queue`, `assignment_session`, `assignment_log`,
      `connects_history`, `leaderboard_snapshot`) + RLS policies
- [x] Routing engine (dine tiers, raincheck, forced rotation, starvation,
      weighted lottery) as transactional Postgres functions
- [ ] Frontend (lead assignment screen, admin settings, leaderboard)
- [ ] Drive-based ETL (Zoom/NetSuite report ingestion, replacing Gmail polling)
- [ ] Auth wiring (Google OAuth restricted to shift4.com)
