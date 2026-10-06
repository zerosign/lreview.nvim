---@meta

-- Schema version + migrations registry.

local M = {}

-- v4:
--   * pull_requests gains flat `source_branch` / `target_branch` columns
--     (branch resolution was decoding every payload BLOB to filter in Lua).
--   * new `push_ops` outbox table replaces comments.state = IN_FLIGHT as the
--     submit lock, so nothing can be stranded in a non-pushable state.
--   * new `issues` + `issue_notes` tables (offline issue index + FTS) so MR
--     descriptions can be correlated to what they actually change.
--   * partial indexes on comments(remote_id)/comments(t_id WHERE remote_id IS
--     NULL)/push_ops(status='RUNNING') to match real query shapes.
-- Migration policy is unchanged: version mismatch => clean recreate.
M.version = 4

M.migrations = {}

return M
