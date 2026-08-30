-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local init = require("lreview")

print("==========================================================================")
print("  lreview.nvim — Benchmark: Core Plan 3 (Submit Atomicity & State Machine)")
print("==========================================================================")

local test_db = "tmp/bench_submit_atomicity.db"
vim.fn.delete(test_db)

init.setup({
  defaults = { db_path = test_db }
})

storage.open()

local mo_id = "github:test/repo:1"

-- Upsert parent pull request and 100 threads/comments
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

for i = 1, 100 do
  local t_id = "thread_" .. i
  comments.create_thread({
    t_id = t_id,
    mo_id = mo_id,
    path = "src/file_" .. i .. ".lua",
    start_line = i,
    end_line = i,
    is_draft = true,
  })
  comments.add_comment({
    c_id = "comment_" .. i,
    t_id = t_id,
    body = "Draft comment body " .. i,
    state = comments.STATE.DRAFT,
  })
end

-- Benchmark 1: compute_change_set performance
local iters = 1000
local t0_cs = vim.uv.hrtime()

for _ = 1, iters do
  review.compute_change_set(mo_id)
end

local dt_cs = (vim.uv.hrtime() - t0_cs) / iters / 1e6

print(string.format("  [Change-Set Diff]     compute_change_set (%d ops): %8.3f ms / call", iters, dt_cs))

-- Benchmark 2: State transition latency (mark_in_flight)
local t0_flight = vim.uv.hrtime()
for i = 1, 100 do
  comments.mark_in_flight("comment_" .. i)
end
local dt_flight = (vim.uv.hrtime() - t0_flight) / 100 / 1e6

print(string.format("  [State Transition]    mark_in_flight (100 ops):      %8.3f ms / call", dt_flight))

-- Benchmark 3: Batch SQLite Transaction (100 updates in 1 txn)
local t0_batch = vim.uv.hrtime()
storage.with_transaction(function()
  for i = 1, 100 do
    comments.revert_in_flight("comment_" .. i, comments.STATE.DRAFT)
  end
end)
local dt_batch = (vim.uv.hrtime() - t0_batch) / 1e6

print(string.format("  [Atomic Transaction]  100 state reverts in 1 txn:    %8.3f ms total", dt_batch))
print("==========================================================================")
