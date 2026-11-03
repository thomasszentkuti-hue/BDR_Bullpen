-- =============================================================================
-- Pre-authorize Hitesh Rathi and George McNeil for manager panel access.
-- Same pattern as 20261016090000_add_bobbie_stanton_admin.sql — adds them to
-- the allowlist so trg_assign_admin_from_allowlist (from
-- 20260826090000_admin_allowlist.sql) grants the admin role automatically the
-- moment their Google account is created on first sign-in. The backfill query
-- below also grants immediately if either has already signed in.
-- =============================================================================

insert into admin_emails (email) values
  ('hitesh.rathi@shift4.com'),
  ('george.mcneil@shift4.com')
on conflict (email) do nothing;

-- Backfill: grant immediately if they already have an account (safe no-op otherwise).
insert into user_roles (user_id, role)
select u.id, 'admin' from auth.users u
join admin_emails a on lower(a.email) = lower(u.email)
where lower(a.email) in ('hitesh.rathi@shift4.com', 'george.mcneil@shift4.com')
on conflict (user_id) do update set role = 'admin';
