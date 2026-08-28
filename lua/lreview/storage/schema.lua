-- SQLite schema version baseline tracking.
-- Incremental updates (v4, v5, etc.) will be defined here.

local M = {}

M.version = 4

M.migrations = {
  [4] = [[
-- v4: add deleted column to comments table (0 = active, 1 = soft-deleted)
ALTER TABLE comments ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
]]
}

return M
