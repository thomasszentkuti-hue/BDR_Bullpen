-- =============================================================================
-- Raincheck, take 3: log it against skipped reps, but only once the lead
-- actually lands on someone else — not on the bare "No" click.
--
-- Previous behaviour (20260827090000_fix_raincheck_and_rotation.sql) made
-- raincheck fully manual because auto-flagging on every skip snowballed into
-- "raincheck against everyone" and starved the weighted lottery. Per
-- decision, the desired behaviour is actually a middle ground: a rep who
-- gets skipped SHOULD get a raincheck — but only if the lead ends up
-- confirmed to somebody else. If the BDR cycles through a few reps and then
-- cancels instead of confirming, no raincheck should be logged for anyone
-- skipped along the way.
--
-- `lead_queue.skipped_rep_ids` already accumulates every rep skipped for a
-- given lead (skip_assignment appends to it, unchanged from the last fix).
-- This migration reads that array at the point of confirm/recall — the only
-- two paths that actually close a lead out successfully — and flags
-- raincheck for everyone in it except whoever is actually getting the lead.
-- cancel_assignment is untouched: it never looks at skipped_rep_ids, so
-- cancelling still flags nobody, which is exactly the point.
--
-- No auto-expiry and no cap on Raincheck Redemption's share of leads, per
-- decision — this is deliberately the same "manual clear only" model as
-- before, just with the trigger point moved from skip to confirm/recall.
-- =============================================================================

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

-- cancel_assignment is intentionally untouched — it never reads
-- skipped_rep_ids, so cancelling a session (instead of confirming or
-- recalling) still flags nobody's raincheck. That's the whole point.
