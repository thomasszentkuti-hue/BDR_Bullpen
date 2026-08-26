-- =============================================================================
-- Fix: manager panel writes to `reps` were failing with
-- "permission denied for table reps".
--
-- Same class of bug as the original sync-function permissions issue: the
-- reps_admin_update / reps_admin_write / reps_admin_delete RLS policies
-- (in 20260818120000_init_schema.sql) control WHICH rows an admin can touch,
-- but 20260819060000_table_grants.sql only ever granted `select` on `reps`
-- to `authenticated` — never insert/update/delete. RLS is a second gate on
-- top of table-level GRANTs, not a replacement for them, so admins could
-- read the roster but never actually save a change to it.
--
-- This does not loosen who can write — the existing RLS policies still
-- restrict every insert/update/delete on `reps` to is_admin() — it just
-- lets the grant layer get out of the way for the role RLS already trusts.
-- =============================================================================

grant insert, update, delete on reps to authenticated;
