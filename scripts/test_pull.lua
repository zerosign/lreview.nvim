-- Integration Test Case for Asynchronous Pull & Edge Cases
-- Run with: nvim --headless -l scripts/test_pull.lua

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local pull_request = require("lreview.storage.pull_request")
local review = require("lreview.review")

-- 1. Setup temporary sandbox database
local db_path = "sandbox/data/nvim/lreview/test_pull.db"
os.remove(db_path)
local ok, err = storage.open(db_path)
if not ok then
  print("FAIL: Database failed to open:", err)
  os.exit(1)
end

-- 2. Mock Active Review Context
pull_request.upsert({
  mo_id = "test:owner/repo:1",
  provider = "test",
  repo = "owner/repo",
  number = 1,
  title = "Test PR",
  author = "me",
})

review.current = {
  detail = { mo_id = "test:owner/repo:1", number = 1 },
  cwd = vim.fn.getcwd()
}

-- 3. Seed a local draft comment (which should be preserved during pulls)
local draft_t_id = "draft-thread-uuid-123"
local draft_c_id = "draft-comment-uuid-456"
comments.create_thread({
  t_id = draft_t_id,
  mo_id = "test:owner/repo:1",
  path = "README.md",
  commit_sha = "abcdef",
  start_line = 5,
  end_line = 5,
  is_draft = true,
  resolved = false,
})
comments.add_comment({
  c_id = draft_c_id,
  t_id = draft_t_id,
  author = "me",
  body = "My local unsaved draft comment",
  created_at = "2026-08-28T00:00:00Z",
})

print("ASSERT: Local draft seeded in database.")

-- 4. Test Case: Running async pull preserves local draft comments
local wait_done = false
local pull_ok = false

print("TEST: Starting asynchronous pull...")
review.pull_review_async(function(success)
  pull_ok = success
  wait_done = true
end)

-- Wait for the async process callback (simulate event loop run)
local timeout = 5000 -- 5 seconds max
local start_time = vim.loop.hrtime()
while not wait_done do
  vim.cmd("sleep 50m")
  local elapsed = (vim.loop.hrtime() - start_time) / 1e6
  if elapsed > timeout then
    print("FAIL: Async pull timed out after 5 seconds.")
    os.exit(1)
  end
end

-- Verify the draft was preserved
local test_thread = comments.get_thread(draft_t_id)
local test_comments = comments.comments_for_thread(draft_t_id)

if not test_thread or #test_comments == 0 then
  print("FAIL: Local draft comment was wiped during async pull!")
  os.exit(1)
end

if test_comments[1].body ~= "My local unsaved draft comment" then
  print("FAIL: Local draft comment content was altered!")
  os.exit(1)
end

print("SUCCESS: Local draft comment was preserved perfectly.")

-- 5. Test Case: Verify failed remote queries handle errors gracefully
-- Mocking a failing context by removing current review detail
review.current = nil
local success_err, err_msg = review.pull_review_async(function(s) end)
if success_err == false and err_msg == "no active review" then
  print("SUCCESS: Missing context error handled gracefully.")
else
  print("FAIL: Expected no active review error, got:", err_msg)
  os.exit(1)
end

-- Clean up
storage.close()
os.remove(db_path)
print("ALL TESTS PASSED.")
os.exit(0)
