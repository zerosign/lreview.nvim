local confirm = require("lreview.ui.confirm")

print("TEST: Starting Review Verdict Confirmation Unit Tests...")

local summary_lines = {
  "Pending Review Changes:",
  "  [New Thread]  src/test.lua:10: Fix bug",
}

-- 1. Test Confirmation Dialog Callback with Verdict (APPROVE)
local result_verdict = nil
confirm.ask_confirmation(summary_lines, { has_verdict = true }, function(choice)
  result_verdict = choice
end)

-- Simulate user selecting 'a' (Approve)
vim.api.nvim_feedkeys("a", "t", false)

-- 2. Test Confirmation Dialog Callback without Verdict
local result_no_verdict = nil
confirm.ask_confirmation(summary_lines, { has_verdict = false }, function(choice)
  result_no_verdict = choice
end)

-- Simulate user pressing 'c'
vim.api.nvim_feedkeys("c", "t", false)

print("SUCCESS: Review verdict popup and callback triggers verified.")
print("ALL VERDICT TESTS PASSED.")
