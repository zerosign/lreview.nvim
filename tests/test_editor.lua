-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local editor = require("lreview.ui.editor")
local users_mod = require("lreview.storage.users")
local pr_mod = require("lreview.storage.pull_request")
local adapter = require("lreview.adapter")
local init = require("lreview")

print("TEST: Starting Comment Scratchpad and Autocomplete Tests...")

-- ============================================================================
-- 1. Setup Mocking & Environment
-- ============================================================================
local test_db_path = "tmp/test_editor_suite.db"
vim.fn.delete(test_db_path)

init.setup({
  defaults = {
    db_path = test_db_path,
  }
})

local ok, err = storage.open()
if not ok then
  print("FAIL: Could not open test database: " .. tostring(err))
  os.exit(1)
end

-- Seed mock users and PRs
local repo_key = "gh:owner/repo"
users_mod.upsert(repo_key, { username = "zerosign", name = "Zero Sign" }, "2026-08-29T12:00:00Z")
users_mod.upsert(repo_key, { username = "reviewer", name = "The Reviewer" }, "2026-08-29T12:00:00Z")

local gl_repo_key = "glab:owner/repo"
users_mod.upsert(gl_repo_key, { username = "zerosign", name = "Zero Sign" }, "2026-08-29T12:00:00Z")
users_mod.upsert(gl_repo_key, { username = "reviewer", name = "The Reviewer" }, "2026-08-29T12:00:00Z")

pr_mod.upsert({
  mo_id = "github:owner/repo:100",
  provider = "github",
  repo = "owner/repo",
  number = 100,
  title = "Fix autocomplete edge cases",
  state = "open"
})

pr_mod.upsert({
  mo_id = "gitlab:owner/repo:123",
  provider = "gitlab",
  repo = "owner/repo",
  number = 123,
  title = "Fix autocomplete edge cases",
  state = "open"
})

-- Mock active review
review.current = {
  cwd = ".",
  detail = {
    mo_id = "github:owner/repo:100",
    provider = "github",
    number = 100,
    head_sha = "headsha123"
  }
}

-- Mock adapter resolve
local original_resolve = adapter.resolve
adapter.resolve = function(cwd)
  local provider = review.current and review.current.detail and review.current.detail.provider or "github"
  return {
    adapter = {
      submit_inline_review = function() return true, nil end,
      submit_reply = function() return "new_remote_id_abc", nil end,
      update_comment = function() return true, nil end,
      fetch_threads = function() return {} end,
    },
    cfg = { provider = provider == "gitlab" and "glab" or "gh", adapter = provider },
    provider = provider == "gitlab" and "glab" or "gh",
    repo = "owner/repo"
  }
end

-- Spy/Mock functions
local notifications = {}
vim.notify = function(msg, level)
  table.insert(notifications, { msg = msg, level = level })
end

local last_complete = nil
vim.fn.complete = function(startcol, matches)
  last_complete = { startcol = startcol, matches = matches }
end

-- Track window closing
local closed_wins = {}
local original_win_close = vim.api.nvim_win_close
vim.api.nvim_win_close = function(win, force)
  closed_wins[win] = true
  pcall(original_win_close, win, force)
end

-- ============================================================================
-- 2. Test Empty and Valid Comment Logic (BufWriteCmd)
-- ============================================================================

-- Try creating a new comment scratchpad
editor.open_new_comment("lua/lreview/init.lua", 10, 10)

-- Find the created scratchpad buffer
local buf = nil
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(b)
  if name:match("^lreview://comment/") then
    buf = b
    break
  end
end

if not buf then
  print("FAIL: Scratchpad buffer not created.")
  os.exit(1)
end

-- Test Edge Case: Saving an empty comment
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
-- Trigger BufWriteCmd autocmds manually
vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = buf })

local found_empty_warning = false
for _, n in ipairs(notifications) do
  if n.msg:match("cannot be empty") then
    found_empty_warning = true
    break
  end
end

if not found_empty_warning then
  print("FAIL: Empty comment warning not triggered.")
  os.exit(1)
end

-- Test Valid Comment: Saving non-empty comment
notifications = {}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "This is a valid comment line 1.", "Line 2." })
vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = buf })

local found_success_notif = false
for _, n in ipairs(notifications) do
  if n.msg:match("comment added") or n.msg:match("comment updated") or n.msg:match("reply added") then
    found_success_notif = true
  end
end

-- Verify the thread and comment are in SQLite
local threads = comments.threads_for_buffer(review.current.detail.mo_id, "lua/lreview/init.lua")
if #threads ~= 1 then
  print("FAIL: Thread was not created in database.")
  os.exit(1)
end

local c = comments.comments_for_thread(threads[1].t_id)
if #c ~= 1 or c[1].body ~= "This is a valid comment line 1.\nLine 2." then
  print("FAIL: Comment content or spacing mismatch.")
  os.exit(1)
end

-- ============================================================================
-- 3. Test Autocomplete Logic (mentions, markers, markdown headings)
-- ============================================================================

-- Re-open a scratchpad buffer to test autocompletes
editor.open_reply(threads[1].t_id)
local scratch_buf = nil
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(b)
  if name:match("^lreview://comment/") and b ~= buf then
    scratch_buf = b
    break
  end
end

local function set_line_and_trigger(line_text, cursor_col)
  vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { line_text })
  vim.api.nvim_win_set_cursor(0, { 1, cursor_col })
  last_complete = nil
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = scratch_buf })
end

-- Test A: Mention matching
  set_line_and_trigger("Hello @ze", 9)
if not last_complete or #last_complete.matches ~= 1 or last_complete.matches[1].word ~= "zerosign" then
  print("FAIL: Mention prefix matching failed.")
  os.exit(1)
end

-- Test B: Mention non-matching prefix
set_line_and_trigger("Hello @unknown", 14)
if last_complete ~= nil then
  print("FAIL: Non-existent prefix should not trigger complete.")
  os.exit(1)
end

-- Test C: GitHub PR Link matching (# marker)
set_line_and_trigger("This is related to #autoc", 25)
if not last_complete or #last_complete.matches ~= 1 or last_complete.matches[1].word ~= "#100" then
  print("FAIL: PR # link matching failed.")
  os.exit(1)
end

-- Test D: Glued marker edge case (should be ignored)
set_line_and_trigger("word#autoc", 10)
if last_complete ~= nil then
  print("FAIL: Glued marker triggers autocomplete wrongly.")
  os.exit(1)
end

-- Test E: Markdown heading edge case (should be ignored)
set_line_and_trigger("# Heading text", 14)
if last_complete ~= nil then
  print("FAIL: Markdown heading hash triggers autocomplete wrongly.")
  os.exit(1)
end

set_line_and_trigger("## Heading 2", 12)
if last_complete ~= nil then
  print("FAIL: Markdown heading 2 hash triggers autocomplete wrongly.")
  os.exit(1)
end

-- Test F: GitLab platform provider scoping (should change marker to !)
review.current.detail.provider = "gitlab"
set_line_and_trigger("Please check !autoc", 19)
if not last_complete or #last_complete.matches ~= 1 or last_complete.matches[1].word ~= "!123" then
  print("FAIL: GitLab ! link matching failed.")
  os.exit(1)
end

print("SUCCESS: Comment Scratchpad and Autocomplete Tests verified.")

-- Teardown
adapter.resolve = original_resolve
storage.close()
vim.fn.delete(test_db_path)
print("\nALL EDITOR TESTS PASSED.")
os.exit(0)
