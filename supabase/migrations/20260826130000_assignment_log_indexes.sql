-- The manager panel's new audit log query (order by created_at desc limit 50)
-- and the routing engine's own internal scans (_lru_rank, propose_assignment —
-- both already doing "order by created_at desc" on this table on every
-- propose/skip, not just confirms) were running with no supporting index at
-- all — just the implicit PK on id. As assignment_log has grown from months
-- of confirmed assignments, that forces a full-table sort on every read,
-- which is what's causing the new lag. This adds the missing indexes.

create index if not exists assignment_log_created_at_idx
  on assignment_log (created_at desc);

-- Supports _lru_rank's filter on route_method ordered by created_at.
create index if not exists assignment_log_route_method_created_at_idx
  on assignment_log (route_method, created_at desc);
