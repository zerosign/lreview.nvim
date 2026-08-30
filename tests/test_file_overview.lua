-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local summary = require("lreview.ui.summary")
local review = require("lreview.review")

print("TEST: Starting Summary Panel File Overview Unit Tests...")

-- Set mock review session with changed files
review.current = {
  cwd = vim.fn.getcwd(),
  detail = {
    mo_id = "github:test/repo:1",
    files = {
      { path = "src/main.lua", additions = 15, deletions = 2 },
      { path = "lua/lreview/sync.lua", additions = 45, deletions = 0 },
    }
  }
}

summary.open()

-- 1. Test View Mode Toggle to "files"
summary.toggle_view_mode()

if not summary.state or summary.state.view_mode ~= "files" then
  print("FAIL: toggle_view_mode failed to set view_mode to 'files'")
  os.exit(1)
end

-- 2. Test File Rows Mapping
if not summary.state.files_map then
  print("FAIL: files_map missing from summary state")
  os.exit(1)
end

-- 3. Test Sort Mode Cycling
summary.cycle_sort_mode()
if summary.state.sort_mode ~= "comments" then
  print("FAIL: cycle_sort_mode failed to switch to 'comments'")
  os.exit(1)
end

summary.close()

print("SUCCESS: Summary panel file overview mode, file row mapping, and sorting verified.")
print("ALL FILE OVERVIEW TESTS PASSED.")
