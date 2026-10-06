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
vim.fn.delete(test_db .. "-wal")
vim.fn.delete(test_db .. "-shm")

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

-- 1. Comment state constants: the push lock no longer lives in comments.state.
if comments.STATE.IN_FLIGHT ~= nil then
  print("FAIL: STATE.IN_FLIGHT should be retired (push lock lives in push_ops)")
  os.exit(1)
end
if comments.STATE.DRAFT ~= 1 or comments.STATE.SYNCED ~= 2
    or comments.STATE.MODIFIED ~= 8 or comments.STATE.DELETED ~= 16
    or comments.STATE.CONFLICT ~= 32 then
  print("FAIL: content state values changed unexpectedly")
  os.exit(1)
end

local outbox = require("lreview.storage.outbox")

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

-- 2. Test Transition: DRAFT -> QUEUED -> FAILED, comment state untouched.
-- v3 flipped the comment itself to IN_FLIGHT, which fell outside
-- PENDING_PUSH_MASK: an interrupted submit left drafts invisible and
-- unpushable until restart. The outbox keeps the lock in its own row.
outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_1", c_id = "c_flight_1", op = outbox.OP.REPLY,
  payload = { body = "Test in flight comment", parent = "r-remote-1" },
} })
local ops = outbox.pending(mo_id)
if #ops ~= 1 then
  print("FAIL: enqueue should create exactly one op, got " .. tostring(#ops))
  os.exit(1)
end
if ops[1].status ~= outbox.STATUS.QUEUED then
  print("FAIL: new op should be QUEUED")
  os.exit(1)
end
if ops[1].c_id ~= "c_flight_1" then
  print("FAIL: op should reference the comment")
  os.exit(1)
end

outbox.mark_running(ops[1].op_id)
outbox.mark_failed(ops[1].op_id, "simulated network failure")
local c2 = storage.query("SELECT * FROM comments WHERE c_id = ?", "c_flight_1")[1]
if not c2 or c2.state ~= comments.STATE.DRAFT then
  print("FAIL: comment must remain DRAFT through a failed push")
  os.exit(1)
end
-- A FAILED op is still pending, so the very next submit retries it.
local retried = 0
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.status == outbox.STATUS.FAILED then retried = retried + 1 end
end
if retried ~= 1 then
  print("FAIL: failed op should remain retryable (pending)")
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
