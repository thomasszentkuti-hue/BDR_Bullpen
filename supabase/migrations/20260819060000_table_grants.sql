-- =============================================================================
-- Table-level GRANTs — missing from the initial schema migration.
--
-- RLS policies (in 20260818120000_init_schema.sql) control WHICH ROWS a role
-- can see/touch, but that's a second layer on top of basic table-level GRANTs,
-- which control whether a role can touch the table AT ALL. service_role's
-- BYPASSRLS attribute only skips the first layer — it still needs these grants
-- to get past the second one. This project's tables didn't inherit Supabase's
-- usual default-privilege grants, so every Edge Function call was failing with
-- "permission denied for table X" regardless of which API key was used.
--
-- service_role gets full access on every table (it bypasses RLS anyway, so
-- these grants are what actually let it through). authenticated gets the
-- baseline CRUD verbs its RLS policies are written to filter — a grant here
-- does nothing on its own without a matching policy, and vice versa.
-- =============================================================================

grant usage on schema public to anon, authenticated, service_role;

grant all on user_roles, reps, leaderboard_snapshot, lead_queue,
  assignment_session, assignment_log, routing_counters, connects_history
  to service_role;

grant select on user_roles, reps, leaderboard_snapshot, assignment_log,
  routing_counters, connects_history, rep_odds
  to authenticated;

grant select, insert, update on lead_queue to authenticated;
grant select, update on assignment_session to authenticated;

-- Sequences backing the identity/generated columns need USAGE too, or inserts
-- from `authenticated` (lead_queue, assignment_session use gen_random_uuid()
-- so no sequence involved there, but assignment_log's identity column does).
grant usage on all sequences in schema public to service_role;
