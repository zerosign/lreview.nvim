-- Real-world Integration Test Case for Asynchronous Pull & Remote Consolidation
-- Runs against actual GitHub and GitLab sandbox repositories.

-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local adapter = require("lreview.adapter")

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

-- Setup default database (so the background job and test script share the same file)
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
-- 1. GitHub Sandbox Test (Inject comment -> Pull -> Verify -> Delete)
-- ============================================================================
print("TEST: Initializing GitHub sandbox...")
local detail_gh, err_gh = review.start_review("tmp/github-sample-review")
if not detail_gh then
  print("FAIL: Could not start GitHub review:", err_gh)
  os.exit(1)
end

print("TEST: Injecting remote comment on GitHub...")
local gh_body = "Simulated remote comment from test suite"
local post_gh = {
  "gh", "api", "repos/zerosign/sample-review/pulls/2/comments",
  "-F", "body=" .. gh_body,
  "-F", "commit_id=" .. detail_gh.head_sha,
  "-F", "path=README.md",
  "-F", "line=9",
  "-F", "side=RIGHT"
}
local res_gh = vim.system(post_gh, { text = true }):wait()
if res_gh.code ~= 0 then
  print("FAIL: Could not inject GitHub comment:", res_gh.stderr)
  os.exit(1)
end
local comment_gh = vim.json.decode(res_gh.stdout)
local comment_gh_id = comment_gh.id

print("TEST: Pulling comments from GitHub...")
local success_gh = run_async_wait()
if not success_gh then
  print("FAIL: GitHub async pull reported failure.")
  os.exit(1)
end

-- Verify consolidation in SQLite
local threads_gh = comments.threads_for_mr(detail_gh.mo_id)
local found_gh = false
for _, t in ipairs(threads_gh) do
  local cs = comments.comments_for_thread(t.t_id)
  for _, c in ipairs(cs) do
    if c.body == gh_body then
      found_gh = true
      break
    end
  end
end

if not found_gh then
  print("FAIL: Injected GitHub comment was not pulled into local database!")
  os.exit(1)
end
print("SUCCESS: Injected GitHub comment was pulled and consolidated successfully.")

-- Cleanup GitHub remote comment & test soft-deletion
print("CLEANUP: Deleting injected GitHub comment...")
local del_gh = {
  "gh", "api", "-X", "DELETE",
  "repos/zerosign/sample-review/pulls/comments/" .. comment_gh_id
}
vim.system(del_gh):wait()

print("TEST: Pulling comments again to verify GitHub soft-deletion...")
local success_gh_del = run_async_wait()
if not success_gh_del then
  print("FAIL: GitHub second async pull reported failure.")
  os.exit(1)
end

local found_gh_deleted = false
local threads_gh2 = comments.threads_for_mr(detail_gh.mo_id)
for _, t in ipairs(threads_gh2) do
  local cs = storage.query("SELECT * FROM comments WHERE t_id = ?", t.t_id)
  for _, c in ipairs(cs) do
    if c.body == gh_body and c.state == comments.STATE.DELETED then
      found_gh_deleted = true
      break
    end
  end
end

if not found_gh_deleted then
  print("FAIL: Injected GitHub comment was not marked as soft-deleted locally!")
  os.exit(1)
end
print("SUCCESS: Injected GitHub comment was successfully consolidated as soft-deleted.")


-- ============================================================================
-- 2. GitLab Sandbox Test (Inject note -> Pull -> Verify -> Delete)
-- ============================================================================
print("\nTEST: Initializing GitLab sandbox...")
local detail_gl, err_gl = review.start_review("tmp/gitlab-sample-review")
if not detail_gl then
  print("FAIL: Could not start GitLab review:", err_gl)
  os.exit(1)
end

print("TEST: Injecting remote note on GitLab...")
local gl_body = "Simulated GitLab note from test suite"
local post_gl = {
  "glab", "mr", "note", "create", tostring(detail_gl.number),
  "-m", gl_body
}
local res_gl = vim.system(post_gl, { text = true, cwd = "tmp/gitlab-sample-review" }):wait()
if res_gl.code ~= 0 then
  print("FAIL: Could not inject GitLab note:", res_gl.stderr)
  os.exit(1)
end
local note_gl_id = res_gl.stdout:match("#note_(%d+)")
if not note_gl_id then
  print("FAIL: Could not parse note ID from glab output:", res_gl.stdout)
  os.exit(1)
end

print("TEST: Pulling comments from GitLab...")
local success_gl = run_async_wait()
if not success_gl then
  print("FAIL: GitLab async pull reported failure.")
  os.exit(1)
end

-- Verify consolidation in SQLite
local threads_gl = comments.threads_for_mr(detail_gl.mo_id)
local found_gl = false
for _, t in ipairs(threads_gl) do
  local cs = comments.comments_for_thread(t.t_id)
  for _, c in ipairs(cs) do
    if c.body == gl_body then
      found_gl = true
      break
    end
  end
end

if not found_gl then
  print("FAIL: Injected GitLab note was not pulled into local database!")
  os.exit(1)
end
print("SUCCESS: Injected GitLab note was pulled and consolidated successfully.")

-- Cleanup GitLab remote note & test soft-deletion
print("CLEANUP: Deleting injected GitLab note...")
local del_gl = {
  "glab", "mr", "note", "delete", tostring(detail_gl.number),
  note_gl_id, "-y"
}
vim.system(del_gl, { cwd = "tmp/gitlab-sample-review" }):wait()

print("TEST: Pulling comments again to verify GitLab soft-deletion...")
local success_gl_del = run_async_wait()
if not success_gl_del then
  print("FAIL: GitLab second async pull reported failure.")
  os.exit(1)
end

local found_gl_deleted = false
local threads_gl2 = comments.threads_for_mr(detail_gl.mo_id)
for _, t in ipairs(threads_gl2) do
  local cs = storage.query("SELECT * FROM comments WHERE t_id = ?", t.t_id)
  for _, c in ipairs(cs) do
    if c.body == gl_body and c.state == comments.STATE.DELETED then
      found_gl_deleted = true
      break
    end
  end
end

if not found_gl_deleted then
  print("FAIL: Injected GitLab note was not marked as soft-deleted locally!")
  os.exit(1)
end
print("SUCCESS: Injected GitLab note was successfully consolidated as soft-deleted.")

-- Clean up local database changes
storage.execute("DELETE FROM comments")
storage.execute("DELETE FROM threads")
storage.close()
print("\nALL ADAPTER PULL & CONSOLIDATION TESTS PASSED.")
os.exit(0)
