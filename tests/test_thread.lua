-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local thread = require("lreview.thread")

print("TEST: Starting Thread Launcher Unit Tests...")

local done = false
local res = nil

local worker = thread.create_worker("lreview.thread", "test_worker", function(payload)
  res = payload
  done = true
end)

worker:queue({ val = 21, message = "hello thread" })

local ok = vim.wait(3000, function() return done end, 10)
if not ok or not res then
  print("FAIL: Thread execution timed out or returned nil")
  os.exit(1)
end

if not res.ok or not res.echo_args or res.computed ~= 42 then
  print("FAIL: Thread returned unexpected result: " .. vim.inspect(res))
  os.exit(1)
end

print("== Slot queue: per-call callbacks for cached workers ==")

-- Unit semantics: FIFO pairing, empty dispatch is a no-op, bounded growth.
thread.arm("t.slot", function() error("first should have been popped") end)
thread.arm("t.slot", function() end)
local popped = thread.pop_cb("t.slot")
local second = thread.pop_cb("t.slot")
if popped == nil or second == nil then
  print("FAIL: pop_cb should drain armed callbacks in order")
  os.exit(1)
end
if thread.pop_cb("t.slot") ~= nil then
  print("FAIL: pop_cb on an empty slot must return nil")
  os.exit(1)
end
if thread.dispatch_cb("t.slot.missing", 1) ~= false then
  print("FAIL: dispatch_cb with nothing armed must report false, not error")
  os.exit(1)
end
local fired = nil
thread.arm("t.slot", function(x, y) fired = { x, y } end)
thread.dispatch_cb("t.slot", 7, 8)
if not fired or fired[1] ~= 7 or fired[2] ~= 8 then
  print("FAIL: dispatch_cb must forward varargs to the armed callback")
  os.exit(1)
end

-- The bug this guards: a worker is a module-level singleton, so its completion
-- closure captures ONE callback forever. Two sequential queues must reach two
-- distinct callers, in order, with their own results.
local seen = {}
local worker2 = thread.create_worker("lreview.thread", "test_worker", function(res)
  thread.dispatch_cb("t.pair", res and res.computed)
end)
thread.arm("t.pair", function(v) seen[#seen + 1] = { slot = 1, v = v } end)
worker2:queue({ val = 10 })
thread.arm("t.pair", function(v) seen[#seen + 1] = { slot = 2, v = v } end)
worker2:queue({ val = 20 })

local ok2 = vim.wait(5000, function() return #seen >= 2 end, 10)
if not ok2 then
  print("FAIL: both queued jobs must complete (got " .. #seen .. " callbacks)")
  os.exit(1)
end
if seen[1].slot ~= 1 or seen[1].v ~= 20 or seen[2].slot ~= 2 or seen[2].v ~= 40 then
  print("FAIL: callback/result pairing wrong: " .. vim.inspect(seen))
  os.exit(1)
end

print("SUCCESS: Thread environment bootstrap and MessagePack serialization verified.")
print("ALL THREAD LAUNCHER TESTS PASSED.")
