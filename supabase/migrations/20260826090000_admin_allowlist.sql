-- =============================================================================
-- Admin allowlist: pre-authorize admins by email, before they've ever signed in.
--
-- Problem: user_roles keys on auth.users.id, which doesn't exist until a
-- person's first Google sign-in. This table + trigger closes that gap: put an
-- email on the allowlist now, and the admin role is granted automatically at
-- the moment their account is created.
--
-- Also backfills immediately for anyone on the list who already signed in.
-- =============================================================================

create table if not exists admin_emails (
  email       text primary key,
  created_at  timestamptz not null default now()
);

-- Managers to pre-authorize.
insert into admin_emails (email) values
  ('mason.ireland@shift4.com'),
  ('cian.egan@shift4.com')
on conflict (email) do nothing;

-- Runs alongside the existing shift4-domain trigger on auth.users.
create or replace function assign_admin_from_allowlist()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from admin_emails where lower(email) = lower(new.email)) then
    insert into user_roles (user_id, role) values (new.id, 'admin')
    on conflict (user_id) do update set role = 'admin';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_assign_admin_from_allowlist on auth.users;
create trigger trg_assign_admin_from_allowlist
  after insert on auth.users
  for each row execute function assign_admin_from_allowlist();

-- Backfill: grant immediately to allowlisted emails that already have accounts.
insert into user_roles (user_id, role)
select u.id, 'admin' from auth.users u
join admin_emails a on lower(a.email) = lower(u.email)
on conflict (user_id) do update set role = 'admin';
