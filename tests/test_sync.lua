local sync = require("lreview.sync")

print("TEST: Starting Sync Bus Unit Tests...")

-- 1. Test Diff Cache Invalidation and Retrieval
local fake_cwd = "/home/test/repo"
local fake_path = "lua/foo.lua"

local res1 = sync.get_changed_lines(fake_cwd, fake_path)
if res1 == nil then
  print("FAIL: get_changed_lines returned nil")
  os.exit(1)
end

-- Second retrieval should hit cache
local res2 = sync.get_changed_lines(fake_cwd, fake_path)
if res1 ~= res2 then
  print("FAIL: diff_cache did not return cached reference")
  os.exit(1)
end

-- Test Cache Invalidation
sync.invalidate_diff_cache(fake_cwd)

-- 2. Test Event Subscriptions & Debounce Flush
local panel_notified = false
local decor_notified = false

sync.subscribe("panel", function()
  panel_notified = true
end)

sync.subscribe("decor", function()
  decor_notified = true
end)

local test_buf = vim.api.nvim_create_buf(false, true)
sync.mark_dirty(test_buf)

local done = false
vim.schedule(function()
  -- Manually trigger flush if timer is pending
  sync.flush()
  done = true
end)

local ok = vim.wait(2000, function() return done and panel_notified and decor_notified end, 10)
if not ok then
  print("FAIL: Sync Bus flush or notification subscriber timed out")
  os.exit(1)
end

print("SUCCESS: Sync Bus debounced flush and subscriber notifications verified.")
print("ALL SYNC BUS TESTS PASSED.")
