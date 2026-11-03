-- =============================================================================
-- Add a 'manager' role: same manager-panel access as 'admin' (check-in/out,
-- caps, dine eligibility, odds/audit views), EXCEPT they cannot change
-- raincheck_status. Per Tom's request 2026-11-03 — Mason and Bobbie should
-- see and control everything in the panel except rainchecks.
--
-- Mechanics:
--   1. user_roles.role check constraint widened to allow 'manager'.
--   2. New helper is_manager_or_admin() — used for general reps table RLS
--      (read/write parity for managers), distinct from is_admin() which
--      still gates admin_emails/user_roles management and stays admin-only.
--   3. A BEFORE UPDATE trigger on reps blocks any change to raincheck_status
--      unless the caller is a true admin.
--
-- The tricky part: raincheck_status is also flipped automatically by
-- confirm_assignment / recall_last_skipped (20260901120000_raincheck_on_
-- confirm.sql) whenever a BDR confirms/recalls a lead — called by ordinary
-- BDRs, not admins. A blanket "only admins can touch this column" trigger
-- would break that normal flow for every BDR. So those two functions now set
-- a transaction-local flag (bullpen.system_write) right before they touch
-- reps, and the trigger lets anything through when that flag is set —
-- it only blocks a DIRECT client-side update to raincheck_status (i.e. the
-- manager panel's raincheck button) coming from a non-admin.
-- =============================================================================

-- ---- 1. Widen the role constraint -----------------------------------------
alter table user_roles drop constraint if exists user_roles_role_check;
alter table user_roles add constraint user_roles_role_check
  check (role in ('bdr', 'rep', 'admin', 'manager'));

-- ---- 2. Helper for reps-table RLS (admin OR manager) -----------------------
create or replace function is_manager_or_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('admin', 'manager')
  );
$$;

-- ---- 3. Extend reps RLS to managers (raincheck itself is still blocked by
--         the trigger below, regardless of what RLS allows) ----------------
drop policy if exists reps_admin_write on reps;
create policy reps_admin_write on reps
  for insert with check (is_manager_or_admin());
drop policy if exists reps_admin_update on reps;
create policy reps_admin_update on reps
  for update using (is_manager_or_admin()) with check (is_manager_or_admin());
drop policy if exists reps_admin_delete on reps;
create policy reps_admin_delete on reps
  for delete using (is_manager_or_admin());

-- ---- 4. Trigger: block raincheck_status changes from non-admins, unless
--         they come from the system's own confirm/recall flow -------------
create or replace function reps_block_manager_raincheck()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.raincheck_status is distinct from old.raincheck_status
     and coalesce(current_setting('bullpen.system_write', true), '') <> 'true'
     and not is_admin()
  then
    raise exception 'RAINCHECK_ADMIN_ONLY: only full admins can change raincheck_status directly';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reps_block_manager_raincheck on reps;
create trigger trg_reps_block_manager_raincheck
  before update on reps
  for each row execute function reps_block_manager_raincheck();

-- ---- 5. Mark confirm_assignment / recall_last_skipped as system writes ----
create or replace function confirm_assignment(p_session_id uuid)
returns assignment_log
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session assignment_session;
  v_lead    lead_queue;
  v_weight  numeric;
  v_log     assignment_log;
begin
  perform set_config('bullpen.system_write', 'true', true);

  select * into v_session from assignment_session where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND'; end if;
  if v_session.status <> 'pending' then raise exception 'SESSION_ALREADY_RESOLVED: %', v_session.status; end if;
  if now() > v_session.expires_at then
    update assignment_session set status = 'expired' where id = p_session_id;
    raise exception 'SESSION_EXPIRED';
  end if;

  select * into v_lead from lead_queue where id = v_session.lead_queue_id for update;
  perform _assert_lead_owner(v_lead);

  select weighting into v_weight from rep_odds where id = v_session.proposed_rep_id;

  insert into assignment_log (rep_id, route_method, bdr_email, ttv, snapshot_weight)
  values (v_session.proposed_rep_id, v_session.assignment_type, v_lead.bdr_email, v_session.raw_volume, v_weight)
  returning * into v_log;

  update reps set raincheck_status = false, updated_at = now() where id = v_session.proposed_rep_id;

  -- The lead is going to v_session.proposed_rep_id, not to whoever was
  -- skipped along the way (v_lead.skipped_rep_ids, captured before this
  -- confirm touches anything) — flag a raincheck for each of them. No-op if
  -- nobody was skipped (empty array).
  update reps set raincheck_status = true, updated_at = now()
    where id = any(v_lead.skipped_rep_ids) and not archived;

  update lead_queue set status = 'assigned', last_skipped_rep_id = null, last_skipped_type = null
    where id = v_session.lead_queue_id;
  update assignment_session set status = 'confirmed' where id = p_session_id;

  perform _bump_standard_lead_counter(v_session.assignment_type);

  return v_log;
end;
$$;

create or replace function recall_last_skipped(p_session_id uuid)
returns assignment_log
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session assignment_session;
  v_lead    lead_queue;
  v_weight  numeric;
  v_log     assignment_log;
begin
  perform set_config('bullpen.system_write', 'true', true);

  select * into v_session from assignment_session where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND'; end if;
  if v_session.status <> 'pending' then raise exception 'SESSION_ALREADY_RESOLVED: %', v_session.status; end if;

  select * into v_lead from lead_queue where id = v_session.lead_queue_id for update;
  perform _assert_lead_owner(v_lead);
  if v_lead.last_skipped_rep_id is null then
    raise exception 'NO_SKIPPED_REP: nothing to recall for this lead';
  end if;

  select weighting into v_weight from rep_odds where id = v_lead.last_skipped_rep_id;

  insert into assignment_log (rep_id, route_method, bdr_email, ttv, snapshot_weight)
  values (v_lead.last_skipped_rep_id, v_lead.last_skipped_type, v_lead.bdr_email, v_session.raw_volume, v_weight)
  returning * into v_log;

  update reps set raincheck_status = false, updated_at = now() where id = v_lead.last_skipped_rep_id;

  -- Everyone else skipped for this lead (not the recalled rep, who's the one
  -- actually getting it) gets a raincheck.
  update reps set raincheck_status = true, updated_at = now()
    where id = any(v_lead.skipped_rep_ids)
      and id <> v_lead.last_skipped_rep_id
      and not archived;

  update lead_queue set status = 'assigned', last_skipped_rep_id = null, last_skipped_type = null
    where id = v_session.lead_queue_id;
  update assignment_session set status = 'cancelled' where id = p_session_id;

  perform _bump_standard_lead_counter(v_lead.last_skipped_type);

  return v_log;
end;
$$;

-- ---- 6. Mason and Bobbie become managers, not plain bdr --------------------
update user_roles
   set role = 'manager'
 where user_id in (
   select id from auth.users
   where lower(email) in ('mason.ireland@shift4.com', 'bobbie.stanton@shift4.com')
 );
