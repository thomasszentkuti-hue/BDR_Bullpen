-- =============================================================================
-- Fix: "assigning to a fixed order every time" + "raincheck logged against
-- everyone even when cancelled" — these turned out to be the same root cause.
--
-- Bug: skip_assignment auto-flagged raincheck_status = true on EVERY "No"
-- click. Since skips happen constantly across the whole roster and only ever
-- clear on a confirm, raincheck_status crept towards "true for almost
-- everyone" over a normal day. Because the Raincheck Redemption tier
-- outranks the weighted lottery in propose_assignment, once several reps
-- carried the flag, most leads got funneled through that deterministic
-- LRU-ordered tier instead of ever reaching the random draw — which is
-- exactly "fixed order every time."
--
-- Fix, per decision: raincheck becomes fully manual. Skipping a rep no
-- longer touches raincheck_status at all — only a manager's toggle in the
-- panel does. Raincheck Redemption still exists as a tier (so a manager can
-- still manually prioritize someone), it just never self-triggers anymore.
--
-- Also removing the forced "every 3rd standard lead -> Tommy/Ryan" rotation
-- entirely, per decision — every lead now falls through to Starvation
-- Override / Standard Lottery Draw, both of which were already correct.
-- =============================================================================

create or replace function _bump_standard_lead_counter(p_assignment_type text)
returns void language plpgsql as $$
begin
  if p_assignment_type in ('STANDARD LOTTERY DRAW', 'STARVATION OVERRIDE') then
    update routing_counters set value = value + 1 where key = 'standard_lead_count';
  end if;
end;
$$;

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

  -- ---- 2. RAINCHECK REDEMPTION (manual only — never self-triggered) --------
  elsif exists (
    select 1 from reps r
    where r.raincheck_status and r.bullpen_status
      and v_lead.ttv between r.min_cap and r.max_cap
      and not (r.id = any(v_lead.skipped_rep_ids))
  ) then
    v_assignment_type := 'RAINCHECK REDEMPTION';
    select r.id into v_rep_id
    from reps r
    where r.raincheck_status and r.bullpen_status
      and v_lead.ttv between r.min_cap and r.max_cap
      and not (r.id = any(v_lead.skipped_rep_ids))
    order by _lru_rank(r.id, 'RAINCHECK REDEMPTION', 200) asc nulls first, r.name
    limit 1
    for update of r skip locked;

  -- ---- 3-4. STARVATION / STANDARD LOTTERY -----------------------------------
  -- (forced Tommy/Ryan 3rd-lead rotation removed — every lead here now goes
  -- through starvation-check then the weighted lottery, no deterministic tier
  -- in between.)
  else
    if not exists (
      select 1 from reps r
      where r.bullpen_status and r.multiplier > 0
        and v_lead.ttv between r.min_cap and r.max_cap
        and not (r.id = any(v_lead.skipped_rep_ids))
    ) then
      raise exception 'AUTOMATION_TIMEOUT: all qualified reps are busy or out of the bullpen';
    end if;

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

      v_assignment_type := 'STANDARD LOTTERY DRAW';
    end if;
  end if;

  if v_rep_id is null then
    raise exception 'NO_CANDIDATE: routing logic produced no rep (unexpected)';
  end if;

  perform 1 from reps where id = v_rep_id for update;

  insert into assignment_session (lead_queue_id, bdr_user_id, proposed_rep_id, assignment_type, raw_volume, skipped_rep_ids)
  values (p_lead_queue_id, v_lead.bdr_user_id, v_rep_id, v_assignment_type, v_lead.ttv, v_lead.skipped_rep_ids)
  returning * into v_session;

  return v_session;
end;
$$;

-- -----------------------------------------------------------------------------
-- SKIP — the "NO" button. No longer auto-flags raincheck; that's manager-only
-- now. Still records the skip on the lead and respins via propose_assignment.
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

  update lead_queue
    set skipped_rep_ids = array_append(skipped_rep_ids, v_session.proposed_rep_id),
        last_skipped_rep_id = v_session.proposed_rep_id,
        last_skipped_type = v_session.assignment_type
    where id = v_session.lead_queue_id;

  update assignment_session set status = 'skipped' where id = p_session_id;

  return propose_assignment(v_session.lead_queue_id);
end;
$$;
