-- Test script to verify multi-repository co-existence in SQLite (GitLab).
-- This script runs pulls against two different repositories and verifies
-- that comments from both are populated side-by-side in the same database.

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local review = require("lreview.review")

-- Configure adapters
require("lreview").setup({
  defaults = {
    db_path = vim.fn.stdpath("data") .. "/lreview/lreview.db",
  },
  ["gitlab\\.com|gitlab\\..*"] = {
    adapter = "gitlab",
    provider = "glab",
    host = "gitlab.com",
  },
})

local ok, err = storage.open()
if not ok then
  print("FAIL: Database failed to open:", err)
  os.exit(1)
end

-- Clear existing data
storage.execute("DELETE FROM comments")
storage.execute("DELETE FROM threads")

local function run_async_wait()
  local wait_done = false
  local pull_ok = false
  review.pull_review_async(function(success)
    pull_ok = success
    wait_done = true
  end)
  while not wait_done do
    vim.cmd("sleep 100m")
  end
  return pull_ok
end

-- ============================================================================
-- 1. Sync First Repository (gitlab-sample-review)
-- ============================================================================
print("TEST: Starting review on first repository...")
local detail1, err1 = review.start_review("tmp/gitlab-sample-review")
if not detail1 then
  print("FAIL: Could not start review 1:", err1)
  os.exit(1)
end
run_async_wait()
local threads1 = comments.threads_for_mr(detail1.mo_id)
print(string.format("Repo 1 (%s) has %d threads in SQLite.", detail1.mo_id, #threads1))

-- ============================================================================
-- 2. Sync Second Repository (gitlab-sample-review2)
-- ============================================================================
local repo2_path = "tmp/gitlab-sample-review2"
if vim.fn.isdirectory(repo2_path) == 0 then
  print("\nINFO: " .. repo2_path .. " not found. Skipping second repo test.")
  os.exit(0)
end

print("\nTEST: Starting review on second repository...")
local detail2, err2 = review.start_review(repo2_path)
if not detail2 then
  print("FAIL: Could not start review 2:", err2)
  os.exit(1)
end
run_async_wait()
local threads2 = comments.threads_for_mr(detail2.mo_id)
print(string.format("Repo 2 (%s) has %d threads in SQLite.", detail2.mo_id, #threads2))

-- ============================================================================
-- 3. Assert Multi-Repo Coexistence
-- ============================================================================
local all_threads = storage.query("SELECT DISTINCT mo_id FROM threads")
print("\nActive MRs stored concurrently in SQLite:")
for _, row in ipairs(all_threads) do
  print("  - " .. row.mo_id)
end

if #all_threads < 2 then
  print("FAIL: Repositories did not populate side-by-side!")
  os.exit(1)
end

print("\nSUCCESS: Multiple GitLab repositories co-exist successfully in SQLite.")
os.exit(0)
