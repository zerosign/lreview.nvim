-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local review = require("lreview.review")
local init = require("lreview")

print("TEST: Starting Review Orchestrator Unit Tests...")

-- ============================================================================
-- 1. Setup Mocking & Environment
-- ============================================================================
local test_db_path = "tmp/test_review_suite.db"
vim.fn.delete(test_db_path)

init.setup({
  defaults = {
    db_path = test_db_path,
  }
})

-- Mock adapter resolver to completely isolate from git remotes and network
local original_resolve = adapter.resolve
adapter.resolve = function(cwd)
  return {
    adapter = {
      name = "github",
      provider = "gh",
      get_mr_by_branch = function()
        return { provider = "github", repo = "owner/repo", number = 100, mo_id = "github:owner/repo:100", head_sha = "headsha123", source_branch = "feature", target_branch = "master", state = "open" }
      end,
      get_mr_detail = function()
        return { provider = "github", repo = "owner/repo", number = 100, mo_id = "github:owner/repo:100", head_sha = "headsha123", title = "Mock Title", body = "Mock Description", source_branch = "feature", target_branch = "master", state = "open" }
      end,
      fetch_threads = function()
        return {
          {
            t_id = "thread_123",
            mo_id = "github:owner/repo:100",
            path = "lua/lreview/init.lua",
            start_line = 10,
            end_line = 10,
            is_draft = false,
            comments = {
              { c_id = "comment_1", t_id = "thread_123", body = "Remote comment", author = "reviewer" }
            }
          }
        }
      end,
      update_mr = function() return true, nil end,
      close_mr = function() return true, nil end,
      approve_mr = function() return true, nil end,
      submit_inline_review = function() return true, nil end,
      resolve_thread = function() return true, nil end,
    },
    cfg = { provider = "gh", adapter = "github" },
    repo = "owner/repo",
    provider = "github",
    host = "github.com"
  }
end

-- Mock Neovim visual pickers so they auto-select synchronously
local original_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  on_choice(items[1], 1)
end

-- Mock input dialogs
local original_input = vim.ui.input
vim.ui.input = function(opts, on_confirm)
  on_confirm("Mock Entered Title")
end

vim.fn.confirm = function() return 1 end

-- ============================================================================
-- 2. Test Review Orchestration Operations (review.lua)
-- ============================================================================

-- Test init_session
local detail, err = review.init_session(".")
if not detail or detail.number ~= 100 then
  print("FAIL: init_session failed: " .. tostring(err))
  os.exit(1)
end

-- Test sync_review synchronously to populate database
local synced_count, sync_err = review.sync_review()
if not synced_count or synced_count == 0 then
  print("FAIL: sync_review failed: " .. tostring(sync_err))
  os.exit(1)
end

-- Test pull_review_async
local pull_done = false
review.pull_review_async(function(success)
  pull_done = true
end)

-- Test update_review
local ok, err = review.update_review("New Title", "New Description")
if not ok then
  print("FAIL: update_review failed: " .. tostring(err))
  os.exit(1)
end

-- Test resolve_thread
local ok, err = review.resolve_thread("thread_123", true)
if not ok then
  print("FAIL: resolve_thread failed: " .. tostring(err))
  os.exit(1)
end

-- Test approve_review
local ok, err = review.approve_review()
if not ok then
  print("FAIL: approve_review failed: " .. tostring(err))
  os.exit(1)
end

-- Test close_review
local ok, err = review.close_review()
if not ok then
  print("FAIL: close_review failed: " .. tostring(err))
  os.exit(1)
end

print("SUCCESS: Review orchestrator methods verified.")

-- ============================================================================
-- 3. Test Command Entrypoints (init.lua cmd callbacks)
-- ============================================================================

-- Reset review session
review.init_session(".")

-- Test summary command
vim.cmd("LocalReviewSummary")

-- Test detail command
vim.cmd("LocalReviewDetail")

-- Test hover command
vim.cmd("LocalReviewHover")

-- Test toggle command
vim.cmd("LocalReviewToggle")
vim.cmd("LocalReviewToggle") -- toggle back off

-- Test pull command
vim.cmd("LocalReviewPull")

-- Test unlinked fallback when adapter returns nil MR
adapter.resolve = function(cwd)
  return {
    adapter = {
      name = "github",
      provider = "gh",
      get_mr_by_branch = function() return nil, "no pull request" end,
      get_mr_detail = function() return nil, "no pull request" end,
    },
    cfg = { adapter = "github" },
  }
end
local unlinked_detail, uerr = review.init_session(vim.fn.getcwd())
assert(unlinked_detail and unlinked_detail.unlinked == true, "unlinked detail fallback failed")
assert(unlinked_detail.number == 0, "unlinked detail number should be 0")
print("SUCCESS: Unlinked draft review fallback verified.")

-- Restoring environment
adapter.resolve = original_resolve
vim.ui.select = original_select
vim.ui.input = original_input
storage.close()
vim.fn.delete(test_db_path)

print("\nALL REVIEW AND INIT COMMAND TESTS PASSED.")
os.exit(0)
