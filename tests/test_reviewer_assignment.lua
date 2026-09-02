-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local review = require("lreview.review")
local adapter = require("lreview.adapter")

print("TEST: Starting Reviewer Assignment Unit Tests...")

-- 1. Mock active review environment
review.current = {
  cwd = vim.fn.getcwd(),
  detail = {
    number = 42,
    mo_id = "github:test/repo:42"
  }
}

-- 2. Mock Adapter with assign_reviewers capability
local assigned_list = nil
adapter.resolve = function()
  return {
    adapter = {
      name = "github",
      capabilities = {
        assign_reviewers = true
      },
      assign_reviewers = function(cfg, ctx, num, reviewers)
        assigned_list = reviewers
        return true, nil
      end
    },
    cfg = {}
  }
end

-- 3. Execute request_reviewers via thread entry point
local req = review.request_reviewers_thread("tmp/test_reviewer_assignment.db", "", {
  cwd = review.current.cwd,
  detail = review.current.detail,
  number = review.current.detail.number,
  reviewers = { "octocat", "mona" },
})
if not (req and req.ok) then
  print("FAIL: request_reviewers failed: " .. tostring(req and req.err))
  os.exit(1)
end

if not assigned_list or #assigned_list ~= 2 or assigned_list[1] ~= "octocat" then
  print("FAIL: assign_reviewers adapter call did not receive expected reviewers list")
  os.exit(1)
end

print("SUCCESS: Reviewer assignment capabilities and adapter dispatch verified.")
print("ALL REVIEWER ASSIGNMENT TESTS PASSED.")
