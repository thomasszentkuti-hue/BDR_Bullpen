-- =============================================================================
-- BDR Bullpen — Supabase schema
-- Ports: Settings, BDR_Console, Rep Audit, Connects History, Leaderboard
-- Run via `supabase migration new bullpen_init` -> paste -> `supabase db push`.
-- Never hand-edit this schema directly against production; change here, PR,
-- migrate through staging first (see the SDLC section of the migration plan).
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- ROLES
-- Google OAuth (restricted to shift4.com at the Supabase Auth provider config)
-- creates a row in auth.users. This table assigns app-level permissions on top.
-- -----------------------------------------------------------------------------
create table if not exists user_roles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  role        text not null check (role in ('bdr', 'rep', 'admin')),
  created_at  timestamptz not null default now()
);

-- Defense in depth: even though Supabase Auth should be configured to only
-- allow the shift4.com Google Workspace domain, reject anything else at
-- signup time too, so a misconfigured provider can't silently let others in.
create or replace function enforce_shift4_domain()
returns trigger language plpgsql as $$
begin
  if new.email is not null and new.email !~* '@shift4\.com$' then
    raise exception 'Only shift4.com accounts may sign in.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_shift4_domain on auth.users;
create trigger trg_enforce_shift4_domain
  before insert on auth.users
  for each row execute function enforce_shift4_domain();

create or replace function is_admin()
returns boolean language sql stable as $$
  select exists (
    select 1 from user_roles where user_id = auth.uid() and role = 'admin'
  );
$$;

create or replace function current_role_name()
returns text language sql stable as $$
  select role from user_roles where user_id = auth.uid();
$$;

-- -----------------------------------------------------------------------------
-- REPS  (was: Settings tab, cols A, D, F-K — B/C/E/J were formula-derived and
-- are recreated below as a view instead of stored columns)
-- -----------------------------------------------------------------------------
create table if not exists reps (
  id                uuid primary key default gen_random_uuid(),
  name              text not null unique,               -- short name, e.g. 'Ryan'
  full_name         text,
  auth_user_id      uuid references auth.users(id),      -- links rep to their Google login
  multiplier        numeric not null default 1,          -- col D — auto-set daily by the ETL job
  bullpen_status    boolean not null default false,      -- col F
  min_cap           numeric not null default 0,          -- col G
  max_cap           numeric not null default 999999999,  -- col H ('' == no cap in the sheet)
  raincheck_status  boolean not null default false,       -- col I
  dine_eligible     boolean not null default false,       -- col K
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- Reps named here never receive standard-lottery leads (dials-only reporting,
-- e.g. Michael) — mirrors DIALS_ONLY_REPS in the daily updater script.
alter table reps add column if not exists dials_only boolean not null default false;

-- -----------------------------------------------------------------------------
-- LEADERBOARD SNAPSHOT (was: Leaderboard tab main table, cols B-G)
-- One row per rep per report date. Rank/weighted score computed by the ETL job
-- exactly as today's Leaderboard formulas do; stored (not a view) because it's
-- a point-in-time snapshot the multiplier calc depends on.
-- -----------------------------------------------------------------------------
create table if not exists leaderboard_snapshot (
  rep_id          uuid not null references reps(id) on delete cascade,
  report_date     date not null,
  connects        numeric not null default 0,
  units_closed    numeric not null default 0,
  revenue_closed  numeric not null default 0,
  sql_rate        numeric not null default 0,
  weighted_score  numeric not null default 0,
  rank            int,
  created_at      timestamptz not null default now(),
  primary key (rep_id, report_date)
);

-- Convenience view: the rank/weighting/odds columns that used to be Settings
-- formulas (B, C, E, J), always computed from the latest snapshot instead of
-- a formula that a manual edit can clobber.
create or replace view rep_odds as
  with latest as (
    select distinct on (rep_id) rep_id, rank
    from leaderboard_snapshot
    order by rep_id, report_date desc
  ),
  n as (select count(*) as total from reps where dials_only = false),
  base as (
    select
      r.id, r.name, r.multiplier, r.bullpen_status, r.dine_eligible,
      l.rank,
      (n.total + 1) - coalesce(l.rank, n.total) as inverse
    from reps r
    left join latest l on l.rep_id = r.id
    cross join n
    where r.dials_only = false
  )
  select
    id, name, rank, inverse, multiplier,
    inverse * multiplier as weighting,
    (inverse * multiplier) / nullif(sum(inverse * multiplier) over (), 0) as odds
  from base;

-- -----------------------------------------------------------------------------
-- LEAD QUEUE (was: BDR_Console cols A-E)
-- One row per lead a BDR is routing. Created by the BDR, claimed by the
-- assignment transaction, closed out once confirmed/logged.
-- -----------------------------------------------------------------------------
create table if not exists lead_queue (
  id                    uuid primary key default gen_random_uuid(),
  bdr_user_id           uuid not null references auth.users(id),
  bdr_email             text not null,
  ttv                   numeric not null check (ttv > 0),
  hospitality           boolean not null default false,
  status                text not null default 'pending'
                          check (status in ('pending', 'assigned', 'cancelled')),
  -- Every rep skipped ("NO") so far for THIS lead — replaces the per-user
  -- 'skipped_' script property, scoped to the lead instead of the browser tab.
  skipped_rep_ids       uuid[] not null default '{}',
  -- Only the most recent skip — replaces 'lastSkipped_', used by the
  -- "DIRECT LOG TO ..." recall button.
  last_skipped_rep_id   uuid references reps(id),
  last_skipped_type     text,
  created_at            timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- ASSIGNMENT SESSION (was: PropertiesService state_/skipped_/lastSkipped_ keys)
-- Replaces the modal's in-memory state. TTL-based instead of a client-side
-- 15-second timer, and row-scoped so one BDR's session can never block another.
-- -----------------------------------------------------------------------------
create table if not exists assignment_session (
  id                uuid primary key default gen_random_uuid(),
  lead_queue_id     uuid not null references lead_queue(id) on delete cascade,
  bdr_user_id       uuid not null references auth.users(id),
  proposed_rep_id   uuid references reps(id),
  assignment_type   text,   -- e.g. 'STANDARD LOTTERY DRAW', 'SHIFT4 DINE ROUND ROBIN'
  raw_volume        numeric,
  skipped_rep_ids   uuid[] not null default '{}',
  status            text not null default 'pending'
                      check (status in ('pending', 'confirmed', 'skipped', 'cancelled', 'expired')),
  expires_at        timestamptz not null default (now() + interval '2 minutes'),
  created_at        timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- ASSIGNMENT LOG (was: Rep Audit tab) — append-only source of truth.
-- -----------------------------------------------------------------------------
create table if not exists assignment_log (
  id                bigint generated always as identity primary key,
  rep_id            uuid not null references reps(id),
  route_method      text not null,
  bdr_email         text not null,
  ttv               numeric not null,
  snapshot_weight   numeric,
  created_at        timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- ROUTING COUNTERS (was: script property 'standardLeadCount')
-- Single durable counter, incremented only on confirmed standard-type leads —
-- same rule as _bumpStandardLeadCounter in the original script.
-- -----------------------------------------------------------------------------
create table if not exists routing_counters (
  key    text primary key,
  value  bigint not null default 0
);
insert into routing_counters (key, value) values ('standard_lead_count', 0)
  on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- CONNECTS HISTORY (was: Connects History tab, long/normalized instead of
-- wide-by-rep so the roster can change without a schema migration)
-- -----------------------------------------------------------------------------
create table if not exists connects_history (
  id            bigint generated always as identity primary key,
  report_date   date not null,
  person        text not null,   -- short name, rep or BDR
  is_bdr        boolean not null default false,
  connects      numeric not null default 0,
  dials         numeric not null default 0,
  unique (report_date, person)
);

-- =============================================================================
-- ROW LEVEL SECURITY
-- Roles: bdr (routes leads), rep (SE — read-only on their own data + leaderboard),
-- admin (edits reps/caps/weighting, sees everything). service_role (used only by
-- the Edge Functions) bypasses RLS entirely, per Supabase default.
-- =============================================================================

alter table user_roles           enable row level security;
alter table reps                 enable row level security;
alter table leaderboard_snapshot enable row level security;
alter table lead_queue           enable row level security;
alter table assignment_session   enable row level security;
alter table assignment_log       enable row level security;
alter table routing_counters     enable row level security;
alter table connects_history     enable row level security;

-- user_roles: everyone can read their own role; only admins manage roles.
drop policy if exists user_roles_self_select on user_roles;
create policy user_roles_self_select on user_roles
  for select using (user_id = auth.uid() or is_admin());
drop policy if exists user_roles_admin_write on user_roles;
create policy user_roles_admin_write on user_roles
  for all using (is_admin()) with check (is_admin());

-- reps: any signed-in shift4 user can read (leaderboard is meant to be visible);
-- only admins can edit caps/weighting/flags. Multiplier is written by the ETL
-- job via service_role, which bypasses this policy entirely.
drop policy if exists reps_read_all on reps;
create policy reps_read_all on reps
  for select using (auth.role() = 'authenticated');
drop policy if exists reps_admin_write on reps;
create policy reps_admin_write on reps
  for insert with check (is_admin());
drop policy if exists reps_admin_update on reps;
create policy reps_admin_update on reps
  for update using (is_admin()) with check (is_admin());
drop policy if exists reps_admin_delete on reps;
create policy reps_admin_delete on reps
  for delete using (is_admin());

-- leaderboard_snapshot: read-only for everyone signed in; writes are service_role only.
drop policy if exists leaderboard_read_all on leaderboard_snapshot;
create policy leaderboard_read_all on leaderboard_snapshot
  for select using (auth.role() = 'authenticated');

-- lead_queue: a BDR can see/create/update only their own rows; admins see all.
drop policy if exists lead_queue_owner_select on lead_queue;
create policy lead_queue_owner_select on lead_queue
  for select using (bdr_user_id = auth.uid() or is_admin());
drop policy if exists lead_queue_owner_insert on lead_queue;
create policy lead_queue_owner_insert on lead_queue
  for insert with check (bdr_user_id = auth.uid());
drop policy if exists lead_queue_owner_update on lead_queue;
create policy lead_queue_owner_update on lead_queue
  for update using (bdr_user_id = auth.uid() or is_admin());

-- assignment_session: same ownership pattern as lead_queue.
drop policy if exists session_owner_select on assignment_session;
create policy session_owner_select on assignment_session
  for select using (bdr_user_id = auth.uid() or is_admin());
drop policy if exists session_owner_update on assignment_session;
create policy session_owner_update on assignment_session
  for update using (bdr_user_id = auth.uid() or is_admin());
-- Inserts happen only inside the propose_assignment() function (security
-- definer, runs as service_role) — no direct-insert policy is granted here.

-- assignment_log: append-only ledger. Read access for everyone signed in;
-- no update/delete policy exists for authenticated users at all — only
-- service_role (which bypasses RLS) can write, via confirm_assignment().
drop policy if exists audit_read_all on assignment_log;
create policy audit_read_all on assignment_log
  for select using (auth.role() = 'authenticated');

-- routing_counters / connects_history: read-only for authenticated users;
-- writes are service_role only (Edge Functions).
drop policy if exists counters_read_all on routing_counters;
create policy counters_read_all on routing_counters
  for select using (auth.role() = 'authenticated');
drop policy if exists connects_read_all on connects_history;
create policy connects_read_all on connects_history
  for select using (auth.role() = 'authenticated');

-- =============================================================================
-- Seed reference: map the current Settings tab into `reps`. Fill in auth_user_id
-- once each person has signed in once via Google SSO (or backfill from
-- auth.users by email after first login).
-- =============================================================================
-- insert into reps (name, full_name, multiplier, bullpen_status, min_cap, max_cap, raincheck_status, dine_eligible, dials_only) values
--   ('Al',      'Alasdair Laidlaw',  1.42, true,  3000, 150000, true,  false, false),
--   ('Ryan',    'Ryan Ford',         2.25, true,  0,    999999, false, false, false),
--   ('Tommy',   'Tom Davison',       0.92, true,  0,    999999, false, true,  false),
--   ('Kyle',    'Kyle Leschke',      2.08, true,  3000, 150000, false, false, false),
--   ('Tristin', 'Tristin Burke',     1.75, true,  3000, 999999, false, false, false),
--   ('Jackson', 'Jackson Howard',    1.58, true,  3000, 150000, false, false, false),
--   ('Sammy',   'Samantha Hutchins', 1.08, true,  0,    150000, false, true,  false),
--   ('Candice', 'Candice Mitchell',  1.25, false, 3000, 150000, false, false, false),
--   ('Bella',   'Bella Floc''h',     0.75, false, 3000, 150000, false, false, false),
--   ('Soad',    'Soad Hamed',        1.92, true,  3000, 150000, false, false, false),
--   ('Liam',    'Liam',              null, false, null, null,   false, true,  false),
--   ('Troy',    'Troy',              null, false, null, null,   false, true,  false),
--   ('Michael', 'Michael Calabria',  null, false, null, null,   false, false, true);
