-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local editor = require("lreview.ui.editor")
local review = require("lreview.review")
local adapter = require("lreview.adapter")

print("TEST: Starting MR Lifecycle & Scratchpad Body Editor Unit Tests...")

-- 1. Test MR Editor Template Pre-fill and Parsing
local parsed_title, parsed_body

local sample_template = "## Summary\n- Implemented feature X\n- Added unit tests"

editor.open_mr_editor(sample_template, function(t, b)
  parsed_title = t
  parsed_body = b
end)

-- Buffer created for MR editor
local current_buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)

-- Check header lines
if not lines[1] or not lines[1]:match("# Title:") then
  print("FAIL: MR editor scratchpad missing Title header line")
  os.exit(1)
end

-- Simulate user save by setting title and writing
vim.api.nvim_buf_set_lines(current_buf, 0, 1, false, { "# Title: Add Feature X" })
vim.cmd("write")

if parsed_title ~= "Add Feature X" then
  print("FAIL: Parsed title mismatch, got: " .. tostring(parsed_title))
  os.exit(1)
end

if not parsed_body:match("Implemented feature X") then
  print("FAIL: Parsed body missing template content")
  os.exit(1)
end

-- 2. Test create_review with Adapter Mocks
adapter.resolve = function()
  return {
    adapter = {
      name = "github",
      create_mr = function(cfg, ctx, opts)
        if opts.title == "Test MR" then
          return "https://github.com/owner/repo/pull/1", nil
        end
        return nil, "invalid title"
      end
    },
    cfg = {}
  }
end

local url, err = review.create_review({ title = "Test MR", body = "Body" }, ".")
if not url or url ~= "https://github.com/owner/repo/pull/1" then
  print("FAIL: create_review failed to return mock URL")
  os.exit(1)
end

print("SUCCESS: MR scratchpad editor parsing and MR creation lifecycle verified.")
print("ALL MR LIFECYCLE TESTS PASSED.")
