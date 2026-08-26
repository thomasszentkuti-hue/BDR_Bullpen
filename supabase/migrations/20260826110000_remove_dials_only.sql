-- =============================================================================
-- Remove the dials_only concept entirely. Bullpen IN/OUT (bullpen_status) is
-- now the single control for whether a rep is eligible for leads — dials_only
-- was a second, redundant on/off switch layered on top of it, which was
-- confusing from the manager panel with no real benefit over just leaving
-- someone OUT.
--
-- rep_odds previously excluded dials_only reps from both the lottery pool
-- and the odds denominator; now everyone (regardless of the old flag) is
-- included in rep_odds, and bullpen_status/caps alone decide who's actually
-- eligible for a given lead in propose_assignment.
-- =============================================================================

create or replace view rep_odds as
  with latest as (
    select distinct on (rep_id) rep_id, rank
    from leaderboard_snapshot
    order by rep_id, report_date desc
  ),
  n as (select count(*) as total from reps),
  base as (
    select
      r.id, r.name, r.multiplier, r.bullpen_status, r.dine_eligible,
      l.rank,
      (n.total + 1) - coalesce(l.rank, n.total) as inverse
    from reps r
    left join latest l on l.rep_id = r.id
    cross join n
  )
  select
    id, name, rank, inverse, multiplier,
    inverse * multiplier as weighting,
    (inverse * multiplier) / nullif(sum(inverse * multiplier) over (), 0) as odds
  from base;

alter table reps drop column if exists dials_only;
