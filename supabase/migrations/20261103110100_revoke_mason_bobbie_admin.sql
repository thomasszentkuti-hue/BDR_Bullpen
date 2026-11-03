-- =============================================================================
-- Revoke manager-panel (admin) access for Mason Ireland and Bobbie Stanton,
-- per Tom's request 2026-11-03 — admin only, not a full account cutoff.
--
-- This schema has a single `role` per user (bdr / rep / admin — see
-- user_roles check constraint in 20260818120000_init_schema.sql), not an
-- "admin flag on top of a base role." So "remove admin, keep basic access"
-- means downgrading role to 'bdr' rather than deleting the row outright.
-- Assumption: 'bdr' is the safe default non-admin role for both. If either of
-- them shouldn't have ANY app access going forward, just delete their row
-- from user_roles instead (or re-run this as a delete) — flag it and Tom can
-- correct.
--
-- Also removes both emails from admin_emails so a future resignup (e.g. if
-- their auth.users row is ever recreated) doesn't silently re-grant admin
-- via trg_assign_admin_from_allowlist (from 20260826090000_admin_allowlist.sql
-- and 20261016090000_add_bobbie_stanton_admin.sql).
-- =============================================================================

update user_roles
   set role = 'bdr'
 where user_id in (
   select id from auth.users
   where lower(email) in ('mason.ireland@shift4.com', 'bobbie.stanton@shift4.com')
 )
   and role = 'admin';

delete from admin_emails
 where lower(email) in ('mason.ireland@shift4.com', 'bobbie.stanton@shift4.com');
