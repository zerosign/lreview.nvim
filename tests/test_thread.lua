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

print("SUCCESS: Thread environment bootstrap and MessagePack serialization verified.")
print("ALL THREAD LAUNCHER TESTS PASSED.")
