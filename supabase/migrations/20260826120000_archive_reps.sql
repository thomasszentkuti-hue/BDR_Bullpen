-- =============================================================================
-- Add an `archived` flag for reps who've fully left, instead of hard-deleting
-- their row. assignment_log / leaderboard_snapshot rows reference reps(id) —
-- a hard DELETE would either violate that foreign key (if history exists) or
-- silently blow away historical routing/leaderboard data. bullpen_status
-- means "temporarily out"; archived means "gone, hide everywhere."
--
-- rep_odds is updated to exclude archived reps from both the pool and the
-- odds denominator, same shape as the dials_only exclusion it replaced.
-- =============================================================================

alter table reps add column if not exists archived boolean not null default false;

create or replace view rep_odds as
  with latest as (
    select distinct on (rep_id) rep_id, rank
    from leaderboard_snapshot
    order by rep_id, report_date desc
  ),
  n as (select count(*) as total from reps where archived = false),
  base as (
    select
      r.id, r.name, r.multiplier, r.bullpen_status, r.dine_eligible,
      l.rank,
      (n.total + 1) - coalesce(l.rank, n.total) as inverse
    from reps r
    left join latest l on l.rep_id = r.id
    cross join n
    where r.archived = false
  )
  select
    id, name, rank, inverse, multiplier,
    inverse * multiplier as weighting,
    (inverse * multiplier) / nullif(sum(inverse * multiplier) over (), 0) as odds
  from base;

-- Bella (Bella Floc'h) has left the SE roster.
update reps set archived = true, bullpen_status = false where name = 'Bella';
