-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local init = require("lreview")

print("TEST: Starting Submit State Machine Unit Tests...")

local test_db = "tmp/test_submit_state_machine.db"
vim.fn.delete(test_db)

init.setup({
  defaults = { db_path = test_db }
})

storage.open()

local mo_id = "github:test/repo:1"

-- Upsert parent pull request for FK constraints
pull_request.upsert({
  mo_id = mo_id,
  provider = "github",
  repo = "test/repo",
  number = 1,
  title = "Test PR",
  source_branch = "feature",
  target_branch = "master",
  state = "open",
})

-- 1. Test Comment State Constants
if comments.STATE.IN_FLIGHT ~= 4 then
  print("FAIL: STATE.IN_FLIGHT is not 4")
  os.exit(1)
end

-- Create parent thread to satisfy foreign key constraints
comments.create_thread({
  t_id = "t_1",
  mo_id = mo_id,
  path = "src/test.lua",
  start_line = 5,
  end_line = 5,
  is_draft = false,
})

-- Create dummy comment
comments.add_comment({
  c_id = "c_flight_1",
  t_id = "t_1",
  body = "Test in flight comment",
  state = comments.STATE.DRAFT,
})

-- 2. Test Transition: DRAFT -> IN_FLIGHT -> REVERT
comments.mark_in_flight("c_flight_1")
local c1 = storage.query("SELECT * FROM comments WHERE c_id = ?", "c_flight_1")[1]
if not c1 or c1.state ~= comments.STATE.IN_FLIGHT then
  print("FAIL: mark_in_flight failed to set STATE.IN_FLIGHT")
  os.exit(1)
end

comments.revert_in_flight("c_flight_1", comments.STATE.DRAFT)
local c2 = storage.query("SELECT * FROM comments WHERE c_id = ?", "c_flight_1")[1]
if not c2 or c2.state ~= comments.STATE.DRAFT then
  print("FAIL: revert_in_flight failed to restore STATE.DRAFT")
  os.exit(1)
end

-- 3. Test Transaction Rollback Helper
local ok_tx, err_tx = storage.with_transaction(function()
  comments.add_comment({
    c_id = "c_tx_fail",
    t_id = "t_1",
    body = "Rollback candidate",
    state = comments.STATE.DRAFT,
  })
  error("Simulated transaction failure")
end)

if ok_tx then
  print("FAIL: with_transaction did not return false on error")
  os.exit(1)
end

local c_tx = storage.query("SELECT * FROM comments WHERE c_id = ?", "c_tx_fail")[1]
if c_tx then
  print("FAIL: Transaction failed to rollback insert")
  os.exit(1)
end

-- 4. Test compute_change_set
comments.create_thread({
  t_id = "t_draft_1",
  mo_id = mo_id,
  path = "src/main.lua",
  start_line = 10,
  end_line = 10,
  is_draft = true,
})

comments.add_comment({
  c_id = "c_add_1",
  t_id = "t_draft_1",
  body = "New addition comment",
  state = comments.STATE.DRAFT,
})

local cs = review.compute_change_set(mo_id)
if not cs or #cs.additions ~= 1 then
  print("FAIL: compute_change_set additions count mismatch")
  os.exit(1)
end

print("SUCCESS: Comment state machine transitions, change-set computation, and transaction rollback verified.")
print("ALL SUBMIT STATE MACHINE TESTS PASSED.")
