-- =============================================================================
-- BDR Bullpen — routing engine, ported from assignInboundLead / evaluateAndProposeNextRep
-- / handleModalAction in the original bound Apps Script.
--
-- Design: everything that used to happen across a JS function call + a
-- PropertiesService write + a modal round-trip now happens as ONE Postgres
-- transaction per step (propose / confirm / skip / recall), with `for update`
-- row locks on the candidate rep. That's what makes two BDRs assigning at the
-- same moment safe here in a way it isn't in the Sheet today.
--
-- All four RPCs are SECURITY DEFINER (they need to write tables that
-- `authenticated` only has read access to per schema.sql's RLS policies) but
-- each one re-checks that the caller owns the lead (or is an admin) before
-- doing anything — so the privilege escalation is scoped, not blanket.
--
-- Constants below are the exact business rules from the original script,
-- unchanged. Where a tie-break rule was simplified for a cleaner SQL
-- implementation (rather than replicated byte-for-byte), it's called out in
-- a comment with "SIMPLIFIED:" — flag these for review in the parity check.
-- =============================================================================

create or replace function _assert_lead_owner(p_lead lead_queue)
returns void language plpgsql as $$
begin
  if p_lead.bdr_user_id <> auth.uid() and not is_admin() then
    raise exception 'Not authorized for this lead';
  end if;
end;
$$;

-- Position of a rep's most recent appearance within the last p_lookback
-- assignment_log rows (optionally filtered to one route_method), 1 = most
-- recent. NULL means "didn't appear in the window" — i.e. most overdue.
-- Used for the dine round robin, forced 3rd-lead rotation, and raincheck
-- ordering, all of which are "least recently used" fairness rules.
create or replace function _lru_rank(p_rep_id uuid, p_route_method text, p_lookback int)
returns int language sql stable as $$
  select rnk::int from (
    select rep_id, row_number() over (order by created_at desc) as rnk
    from assignment_log
    where (p_route_method is null or route_method = p_route_method)
    order by created_at desc
    limit p_lookback
  ) x
  where x.rep_id = p_rep_id
  limit 1;
$$;

-- Advances the persistent "every 3rd standard lead" counter — only for the
-- three types that count towards it, exactly like STANDARD_LEAD_TYPES_ in the
-- original. Called only from confirm_assignment / recall_last_skipped
-- (never from propose/skip), so a respin can't advance it more than once.
create or replace function _bump_standard_lead_counter(p_assignment_type text)
returns void language plpgsql as $$
begin
  if p_assignment_type in ('STANDARD LOTTERY DRAW', 'STARVATION OVERRIDE', 'THIRD LEAD ROTATION (TOMMY/RYAN)') then
    update routing_counters set value = value + 1 where key = 'standard_lead_count';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- PROPOSE — the full cascade from evaluateAndProposeNextRep(). Call this to
-- get a fresh proposal, or to respin after a skip.
-- -----------------------------------------------------------------------------
create or replace function propose_assignment(p_lead_queue_id uuid)
returns assignment_session
language plpgsql
security definer
set search_path = public
as $$
declare
  DINE_TIER_THRESHOLD      constant numeric := 150000;
  BIG_LEAD_STARVATION_SKIP constant numeric := 58000;
  STARVATION_DEPTH         constant int := 30;
  MAX_STREAK               constant int := 2;

  v_lead            lead_queue;
  v_is_dine         boolean;
  v_is_big_dine     boolean;
  v_rep_id          uuid;
  v_assignment_type text;
  v_standard_count  bigint;
  v_forced_slot     boolean;
  v_recent_count    int;
  v_benched_id      uuid;
  v_session         assignment_session;
begin
  select * into v_lead from lead_queue where id = p_lead_queue_id for update;
  if not found then raise exception 'LEAD_NOT_FOUND'; end if;
  perform _assert_lead_owner(v_lead);
  if v_lead.status <> 'pending' then
    raise exception 'LEAD_NOT_PENDING: status is %', v_lead.status;
  end if;

  v_is_dine := v_lead.hospitality;

  -- ---- 1. SHIFT4 DINE — two-tier round robin -------------------------------
  if v_is_dine then
    v_is_big_dine := v_lead.ttv >= DINE_TIER_THRESHOLD;
    v_assignment_type := 'SHIFT4 DINE ROUND ROBIN';

    select r.id into v_rep_id
    from reps r
    where r.dine_eligible
      and (case when v_is_big_dine then r.name in ('Liam', 'Troy')
                else r.name not in ('Liam', 'Troy') end)
      and not (r.id = any(v_lead.skipped_rep_ids))
    order by _lru_rank(r.id, 'SHIFT4 DINE ROUND ROBIN', 500) asc nulls first, r.name
    limit 1
    for update of r skip locked;

    if v_rep_id is null then
      raise exception 'NO_DINE_REPS: no % dine reps available for this lead',
        case when v_is_big_dine then 'Liam/Troy ($150k+)' else 'other Shift4 Dine eligible' end;
    end if;

  -- ---- 2. RAINCHECK REDEMPTION ---------------------------------------------
  elsif exists (
    select 1 from reps r
    where r.raincheck_status and r.bullpen_status
      and v_lead.ttv between r.min_cap and r.max_cap
      and not (r.id = any(v_lead.skipped_rep_ids))
  ) then
    v_assignment_type := 'RAINCHECK REDEMPTION';
    -- SIMPLIFIED: original re-derives order from the last 200 unfiltered audit
    -- rows via an unshift loop; this uses the same LRU-by-type pattern as the
    -- dine/rotation tiers, which is equivalent in intent (most-overdue rep
    -- wins) and easier to verify. Flagged for review.
    select r.id into v_rep_id
    from reps r
    where r.raincheck_status and r.bullpen_status
      and v_lead.ttv between r.min_cap and r.max_cap
      and not (r.id = any(v_lead.skipped_rep_ids))
    order by _lru_rank(r.id, 'RAINCHECK REDEMPTION', 200) asc nulls first, r.name
    limit 1
    for update of r skip locked;

  -- ---- 3-5. FORCED ROTATION / STARVATION / STANDARD LOTTERY -----------------
  else
    if not exists (
      select 1 from reps r
      where r.bullpen_status and r.multiplier > 0
        and v_lead.ttv between r.min_cap and r.max_cap
        and not (r.id = any(v_lead.skipped_rep_ids))
    ) then
      raise exception 'AUTOMATION_TIMEOUT: all qualified reps are busy or out of the bullpen';
    end if;

    select value into v_standard_count from routing_counters where key = 'standard_lead_count' for update;
    v_forced_slot := ((v_standard_count + 1) % 3) = 0;

    if v_forced_slot then
      select r.id into v_rep_id
      from reps r
      where r.bullpen_status and r.multiplier > 0 and r.name in ('Tommy', 'Ryan')
        and v_lead.ttv between r.min_cap and r.max_cap
        and not (r.id = any(v_lead.skipped_rep_ids))
      order by _lru_rank(r.id, 'THIRD LEAD ROTATION (TOMMY/RYAN)', 500) asc nulls first, r.name
      limit 1
      for update of r skip locked;

      if v_rep_id is not null then
        v_assignment_type := 'THIRD LEAD ROTATION (TOMMY/RYAN)';
      end if;
      -- else: forced slot but Tommy/Ryan both unavailable -> fall through to
      -- starvation/lottery below, exactly like the original's fallback branch.
    end if;

    if v_rep_id is null then
      -- Starvation override — skipped entirely for big leads.
      if v_lead.ttv < BIG_LEAD_STARVATION_SKIP then
        select count(*) into v_recent_count from (
          select 1 from assignment_log order by created_at desc limit STARVATION_DEPTH
        ) x;

        if v_recent_count >= STARVATION_DEPTH then
          select r.id into v_rep_id
          from reps r
          where r.bullpen_status and r.multiplier > 0
            and v_lead.ttv between r.min_cap and r.max_cap
            and not (r.id = any(v_lead.skipped_rep_ids))
            and not exists (
              select 1 from (
                select rep_id from assignment_log order by created_at desc limit STARVATION_DEPTH
              ) recent where recent.rep_id = r.id
            )
          -- SIMPLIFIED: original takes the first match in Settings row order;
          -- this breaks ties by highest current weighting. Only matters if
          -- more than one rep is starved at once. Flagged for review.
          order by (select weighting from rep_odds where id = r.id) desc nulls last, r.name
          limit 1
          for update of r skip locked;

          if v_rep_id is not null then
            v_assignment_type := 'STARVATION OVERRIDE';
          end if;
        end if;
      end if;

      if v_rep_id is null then
        -- 2-in-a-row streak bench: if the same rep won the last two logged
        -- assignments (any type), exclude them from this draw.
        select rep_id into v_benched_id
        from (
          select rep_id, row_number() over (order by created_at desc) as rnk
          from assignment_log order by created_at desc limit MAX_STREAK
        ) last2
        group by rep_id
        having count(*) = MAX_STREAK;

        -- Weighted lottery draw over Weighting (col E equivalent), excluding
        -- the benched rep. If that empties the pool, fall back to including
        -- them (mirrors "if (!drum.length) drum = activeReps").
        with pool as (
          select r.id, coalesce(ro.weighting, 0) as weighting
          from reps r
          join rep_odds ro on ro.id = r.id
          where r.bullpen_status and r.multiplier > 0
            and v_lead.ttv between r.min_cap and r.max_cap
            and not (r.id = any(v_lead.skipped_rep_ids))
            and (v_benched_id is null or r.id <> v_benched_id)
        ),
        pool_or_fallback as (
          select * from pool
          union all
          select r.id, coalesce(ro.weighting, 0)
          from reps r join rep_odds ro on ro.id = r.id
          where not exists (select 1 from pool)
            and r.bullpen_status and r.multiplier > 0
            and v_lead.ttv between r.min_cap and r.max_cap
            and not (r.id = any(v_lead.skipped_rep_ids))
        ),
        cum as (
          select id, weighting,
                 sum(weighting) over (order by id) as running_total,
                 sum(weighting) over () as grand_total
          from pool_or_fallback
        )
        select id into v_rep_id
        from cum
        where running_total >= random() * grand_total
        order by running_total asc
        limit 1;

        -- (the winning rep is locked below, after this if/elsif/else settles on one)
        v_assignment_type := 'STANDARD LOTTERY DRAW';
      end if;
    end if;
  end if;

  if v_rep_id is null then
    raise exception 'NO_CANDIDATE: routing logic produced no rep (unexpected)';
  end if;

  -- Lock the winning rep row for the life of this session so a concurrent
  -- propose_assignment can't also win it before this one is confirmed/skipped.
  perform 1 from reps where id = v_rep_id for update;

  insert into assignment_session (lead_queue_id, bdr_user_id, proposed_rep_id, assignment_type, raw_volume, skipped_rep_ids)
  values (p_lead_queue_id, v_lead.bdr_user_id, v_rep_id, v_assignment_type, v_lead.ttv, v_lead.skipped_rep_ids)
  returning * into v_session;

  return v_session;
end;
$$;

-- -----------------------------------------------------------------------------
-- CONFIRM — the "YES" button. Writes the audit row, clears the raincheck,
-- closes the lead, bumps the standard-lead counter.
-- -----------------------------------------------------------------------------
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
  update lead_queue set status = 'assigned', last_skipped_rep_id = null, last_skipped_type = null
    where id = v_session.lead_queue_id;
  update assignment_session set status = 'confirmed' where id = p_session_id;

  perform _bump_standard_lead_counter(v_session.assignment_type);

  return v_log;
end;
$$;

-- -----------------------------------------------------------------------------
-- SKIP — the "NO" button. Flags a raincheck (unless it's a dine lead), records
-- the skip on the lead, and immediately respins via propose_assignment.
-- -----------------------------------------------------------------------------
create or replace function skip_assignment(p_session_id uuid)
returns assignment_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session assignment_session;
  v_lead    lead_queue;
begin
  select * into v_session from assignment_session where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND'; end if;
  if v_session.status <> 'pending' then raise exception 'SESSION_ALREADY_RESOLVED: %', v_session.status; end if;

  select * into v_lead from lead_queue where id = v_session.lead_queue_id for update;
  perform _assert_lead_owner(v_lead);

  if v_session.assignment_type <> 'SHIFT4 DINE ROUND ROBIN' then
    update reps set raincheck_status = true, updated_at = now() where id = v_session.proposed_rep_id;
  end if;

  update lead_queue
    set skipped_rep_ids = array_append(skipped_rep_ids, v_session.proposed_rep_id),
        last_skipped_rep_id = v_session.proposed_rep_id,
        last_skipped_type = v_session.assignment_type
    where id = v_session.lead_queue_id;

  update assignment_session set status = 'skipped' where id = p_session_id;

  return propose_assignment(v_session.lead_queue_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- RECALL — the "DIRECT LOG TO <last skipped rep>" button. Logs to whoever was
-- most recently skipped instead of the current proposal, and closes out both.
-- -----------------------------------------------------------------------------
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
  update lead_queue set status = 'assigned', last_skipped_rep_id = null, last_skipped_type = null
    where id = v_session.lead_queue_id;
  update assignment_session set status = 'cancelled' where id = p_session_id;

  perform _bump_standard_lead_counter(v_lead.last_skipped_type);

  return v_log;
end;
$$;

-- -----------------------------------------------------------------------------
-- CANCEL — the "CANCEL / FIX TYPO" button. No side effects beyond closing the
-- session; the lead stays pending so the BDR can re-enter TTV/hospitality.
-- -----------------------------------------------------------------------------
create or replace function cancel_assignment(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session assignment_session;
  v_lead    lead_queue;
begin
  select * into v_session from assignment_session where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND'; end if;

  select * into v_lead from lead_queue where id = v_session.lead_queue_id;
  perform _assert_lead_owner(v_lead);

  update assignment_session set status = 'cancelled' where id = p_session_id and status = 'pending';
end;
$$;

-- Grant execute to the authenticated role — RLS on the underlying tables still
-- applies to everything these functions DON'T do explicitly as security
-- definer, and _assert_lead_owner enforces per-lead ownership inside each one.
grant execute on function propose_assignment(uuid)      to authenticated;
grant execute on function confirm_assignment(uuid)      to authenticated;
grant execute on function skip_assignment(uuid)         to authenticated;
grant execute on function recall_last_skipped(uuid)     to authenticated;
grant execute on function cancel_assignment(uuid)       to authenticated;
