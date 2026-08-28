-- Test script to verify Garbage Collection and Cache Reconstitution
-- Targets the GitLab sandbox repository.

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

-- 1. Initial Sync to populate cache
print("1. Initializing GitLab sandbox and populating cache...")
local detail, err = review.start_review("tmp/gitlab-sample-review")
if not detail then
  print("FAIL: Could not start review:", err)
  os.exit(1)
end
run_async_wait()

local count_start = #comments.threads_for_mr(detail.mo_id)
print(string.format("   Loaded %d thread(s) in local SQLite.", count_start))
if count_start == 0 then
  print("FAIL: Initial sync failed to pull threads.")
  os.exit(1)
end

-- 2. Simulate old merged PR in local database
print("\n2. Simulating old merged PR in SQLite...")
storage.execute([[
  UPDATE pull_requests 
  SET state = 'merged', updated_at = '2020-01-01T00:00:00Z'
  WHERE mo_id = ?
]], detail.mo_id)

-- 3. Run garbage collection
print("\n3. Triggering garbage collection (age_days = 30)...")
storage.gc(30)

-- 4. Verify local cache is purged
local count_after_gc = #comments.threads_for_mr(detail.mo_id)
print(string.format("   Active threads in SQLite after GC: %d", count_after_gc))
if count_after_gc > 0 then
  print("FAIL: GC failed to purge threads!")
  os.exit(1)
end
print("   SUCCESS: Local cache successfully purged by GC.")

-- 5. Pull again to verify cache reconstitution
print("\n4. Pulling from remote GitLab to reconstitute cache...")
-- start_review again to refresh state
review.start_review("tmp/gitlab-sample-review")
run_async_wait()

-- 6. Verify threads are restored
local count_restored = #comments.threads_for_mr(detail.mo_id)
print(string.format("   Active threads in SQLite after re-pull: %d", count_restored))
if count_restored ~= count_start then
  print(string.format("FAIL: Restored thread count (%d) does not match original (%d)!", count_restored, count_start))
  os.exit(1)
end

print("\nALL GC AND RECONSTITUTION TESTS PASSED.")
storage.close()
os.exit(0)
