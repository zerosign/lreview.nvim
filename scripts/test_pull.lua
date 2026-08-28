-- Real-world Integration Test Case for Asynchronous Pull
-- Runs against actual GitHub and GitLab sandbox repositories.

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local git = require("lreview.git")
local adapter = require("lreview.adapter")

-- Explicitly call setup to configure adapters (needed when running via nvim -l)
require("lreview").setup({
  defaults = {
    db_path = vim.fn.stdpath("data") .. "/lreview/lreview.db",
  },
  ["github\\.com"] = {
    adapter = "github",
    provider = "gh",
    host = "github.com",
  },
  ["gitlab\\.com|gitlab\\..*"] = {
    adapter = "gitlab",
    provider = "glab",
    host = "gitlab.com",
  },
})

-- Setup default database
local ok, err = storage.open()
if not ok then
  print("FAIL: Database failed to open:", err)
  os.exit(1)
end

-- Clear existing sandbox data to ensure we are testing a fresh pull
storage.execute("DELETE FROM comments")
storage.execute("DELETE FROM threads")

local function run_async_wait()
  local wait_done = false
  local pull_ok = false

  review.pull_review_async(function(success)
    pull_ok = success
    wait_done = true
  end)

  local timeout = 12000 -- 12 seconds max for network requests
  local start_time = vim.loop.hrtime()
  while not wait_done do
    vim.cmd("sleep 100m")
    local elapsed = (vim.loop.hrtime() - start_time) / 1e6
    if elapsed > timeout then
      print("FAIL: Async pull timed out after 12 seconds.")
      os.exit(1)
    end
  end

  return pull_ok
end

-- ============================================================================
-- 1. GitHub Sandbox Test
-- ============================================================================
print("TEST: Initializing GitHub sandbox...")
local detail_gh, err_gh = review.start_review("tmp/github-sample-review")
if not detail_gh then
  print("FAIL: Could not start GitHub review:", err_gh)
  os.exit(1)
end

print("TEST: Pulling comments from GitHub...")
local success_gh = run_async_wait()
if not success_gh then
  print("FAIL: GitHub async pull reported failure.")
  os.exit(1)
end

local threads_gh = comments.threads_for_mr(detail_gh.mo_id)
if #threads_gh == 0 then
  print("FAIL: GitHub pull succeeded but no comments were stored in the database.")
  os.exit(1)
end

print(string.format("SUCCESS: Pulled %d thread(s) from GitHub.", #threads_gh))
for _, t in ipairs(threads_gh) do
  local cs = comments.comments_for_thread(t.t_id)
  print(string.format("  - Thread on %s:%d has %d comment(s)", t.path or "PR", t.start_line or 0, #cs))
  for _, c in ipairs(cs) do
    print(string.format("    [%s]: %s", c.author, c.body:gsub("\n", " ")))
  end
end

-- ============================================================================
-- 2. GitLab Sandbox Test
-- ============================================================================
print("\nTEST: Initializing GitLab sandbox...")
local detail_gl, err_gl = review.start_review("tmp/gitlab-sample-review")
if not detail_gl then
  print("FAIL: Could not start GitLab review:", err_gl)
  os.exit(1)
end

print("TEST: Pulling comments from GitLab...")
local success_gl = run_async_wait()
if not success_gl then
  print("FAIL: GitLab async pull reported failure.")
  os.exit(1)
end

local threads_gl = comments.threads_for_mr(detail_gl.mo_id)
if #threads_gl == 0 then
  print("FAIL: GitLab pull succeeded but no comments were stored in the database.")
  os.exit(1)
end

print(string.format("SUCCESS: Pulled %d thread(s) from GitLab.", #threads_gl))
for _, t in ipairs(threads_gl) do
  local cs = comments.comments_for_thread(t.t_id)
  print(string.format("  - Thread on %s:%d has %d comment(s)", t.path or "MR", t.start_line or 0, #cs))
  for _, c in ipairs(cs) do
    print(string.format("    [%s]: %s", c.author, c.body:gsub("\n", " ")))
  end
end

-- Clean up database changes
storage.execute("DELETE FROM comments")
storage.execute("DELETE FROM threads")
storage.close()
print("\nALL ADAPTER PULL TESTS PASSED.")
os.exit(0)
