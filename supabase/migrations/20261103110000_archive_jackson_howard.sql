-- =============================================================================
-- Jackson Howard has quit — archive him out of the Bullpen entirely, same
-- pattern as Bella's departure in 20260826120000_archive_reps.sql.
--
-- archived = true removes him from rep_odds (both the pool and the odds
-- denominator) and from propose_assignment's eligibility checks everywhere
-- (dine, raincheck, starvation, standard lottery all filter on
-- bullpen_status/archived). bullpen_status = false as belt-and-braces so he's
-- excluded even anywhere that might check bullpen_status without also
-- checking archived. Not a hard DELETE — assignment_log and
-- leaderboard_snapshot rows still reference his rep id for historical
-- reporting.
-- =============================================================================

update reps
   set archived = true,
       bullpen_status = false,
       raincheck_status = false,
       updated_at = now()
 where name = 'Jackson';
