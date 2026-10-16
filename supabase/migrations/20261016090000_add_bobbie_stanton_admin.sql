-- =============================================================================
-- Pre-authorize Bobbie Stanton for manager panel access.
--
-- She hasn't signed in yet ("new login"), so this just adds her email to the
-- allowlist — the trg_assign_admin_from_allowlist trigger (from
-- 20260826090000_admin_allowlist.sql) grants the admin role automatically the
-- moment her Google account is created on first sign-in. The backfill query
-- below is a no-op for her today, but is included so this migration still
-- does the right thing if she's somehow already signed in by the time it runs.
-- =============================================================================

insert into admin_emails (email) values
  ('bobbie.stanton@shift4.com')
on conflict (email) do nothing;

-- Backfill: grant immediately if she already has an account (safe no-op otherwise).
insert into user_roles (user_id, role)
select u.id, 'admin' from auth.users u
join admin_emails a on lower(a.email) = lower(u.email)
where lower(a.email) = 'bobbie.stanton@shift4.com'
on conflict (user_id) do update set role = 'admin';
