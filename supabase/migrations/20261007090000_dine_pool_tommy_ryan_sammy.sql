-- =============================================================================
-- Dine round robin: collapse the $150k big/small tier split and fold Tommy,
-- Ryan and Sammy into the Shift4 Dine pool, per Tom's decision 2026-10-07.
--
-- Before: Dine leads split into two separate pools by DINE_TIER_THRESHOLD
-- ($150k) — Liam/Troy only above it, every OTHER dine_eligible rep below it.
-- Tommy and Sammy already carried dine_eligible = true in some environments,
-- which meant they silently rotated on sub-$150k Dine leads only, with no
-- cap check at all in that branch.
--
-- After:
--   - Tommy, Ryan, Liam, Troy are in the SAME round robin for every Dine
--     lead, regardless of ttv — no tier split, no cap check.
--   - Sammy joins that same rotation, but ONLY under a hardcoded $150,000
--     ceiling (SAMMY_DINE_CAP below) — the same number that used to be the
--     DINE_TIER_THRESHOLD split. This is intentionally a fixed constant, NOT
--     a read of her live min_cap/max_cap row: if her standard-lottery cap
--     changes later in the manager panel, her Dine ceiling stays put at
--     $150k until someone edits this constant directly.
--
-- This replaces the DINE branch inside propose_assignment. Everything else
-- in the function (raincheck, starvation, standard lottery) is carried over
-- unchanged from 20260827090000_fix_raincheck_and_rotation.sql — only the
-- dine selection logic and the NO_DINE_REPS error message changed.
-- =============================================================================

-- ---- 1. Data: make sure the five Dine-pool reps actually carry the flag ----
update reps
   set dine_eligible = true,
       updated_at = now()
 where name in ('Tommy', 'Ryan', 'Liam', 'Troy', 'Sammy')
   and dine_eligible is distinct from true;

-- ---- 2. Routing function: flat pool instead of the $150k tier split -------
create or replace function propose_assignment(p_lead_queue_id uuid)
returns assignment_session
language plpgsql
security definer
set search_path = public
as $$
declare
  SAMMY_DINE_CAP           constant numeric := 150000; -- hardcoded, not her live max_cap — see migration header
  BIG_LEAD_STARVATION_SKIP constant numeric := 58000;
  STARVATION_DEPTH         constant int := 30;
  MAX_STREAK               constant int := 2;

  v_lead            lead_queue;
  v_is_dine         boolean;
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

  -- ---- 1. SHIFT4 DINE — single round robin, no value tier ------------------
  -- Tommy/Ryan/Liam/Troy: eligible for any Dine lead regardless of ttv.
  -- Sammy: eligible only under the hardcoded SAMMY_DINE_CAP ($150k) — fixed,
  -- independent of whatever her standard min_cap/max_cap are set to.
  if v_is_dine then
    v_assignment_type := 'SHIFT4 DINE ROUND ROBIN';

    select r.id into v_rep_id
    from reps r
    where r.dine_eligible
      and (
        r.name in ('Tommy', 'Ryan', 'Liam', 'Troy')
        or (r.name = 'Sammy' and v_lead.ttv < SAMMY_DINE_CAP)
      )
      and not (r.id = any(v_lead.skipped_rep_ids))
    order by _lru_rank(r.id, 'SHIFT4 DINE ROUND ROBIN', 500) asc nulls first, r.name
    limit 1
    for update of r skip locked;

    if v_rep_id is null then
      raise exception 'NO_DINE_REPS: no eligible Shift4 Dine reps for this lead (Tommy/Ryan/Liam/Troy, or Sammy under $150k)';
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

grant execute on function propose_assignment(uuid) to authenticated;
