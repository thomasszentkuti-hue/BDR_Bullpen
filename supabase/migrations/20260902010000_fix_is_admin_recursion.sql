-- =============================================================================
-- Fix "stack depth limit exceeded" on manager panel saves (reported by Mason
-- Ireland; reproducible on any admin action whose RLS policy is bare
-- `using (is_admin())` with no OR-shortcut, e.g. reps_admin_update).
--
-- Root cause: is_admin() queries user_roles, and user_roles' own RLS policy
-- (user_roles_self_select) calls is_admin() again to decide row visibility —
-- a self-referential loop. Postgres's planner usually short-circuits this by
-- evaluating the cheap `user_id = auth.uid()` branch first, which is why this
-- has worked for most admins most of the time, but that short-circuit isn't
-- guaranteed for every query plan/calling context. When it doesn't happen,
-- is_admin() -> user_roles RLS -> is_admin() -> ... recurses until Postgres
-- hits its stack depth limit and the save fails outright.
--
-- Fix: make is_admin() SECURITY DEFINER so its internal query against
-- user_roles runs with the function owner's privileges and bypasses RLS on
-- that table entirely. It can never re-trigger user_roles_self_select again,
-- which permanently breaks the recursion for every admin, not just a patch
-- for Mason's specific case. Safe to do here because is_admin() only ever
-- returns a boolean about the CURRENT calling user (auth.uid()) — it doesn't
-- expose any other user's data. set search_path = public is standard
-- hardening for SECURITY DEFINER functions (prevents search_path hijacking).
-- =============================================================================

create or replace function is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from user_roles where user_id = auth.uid() and role = 'admin'
  );
$$;
