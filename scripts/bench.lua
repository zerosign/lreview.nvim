-- SQL Query Latency Benchmark for lreview.nvim
-- Runs in headless Neovim to profile Read/Write/Update/Delete operations.

-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local pull_request = require("lreview.storage.pull_request")

-- Setup a temporary memory database for high-frequency testing,
-- or use a temp file to test disk I/O latency.
local db_path = "sandbox/data/nvim/lreview/bench.db"
os.remove(db_path)

local ok, err = storage.open(db_path)
if not ok then
  print("Failed to open database:", err)
  os.exit(1)
end

-- Profiling wrapper
local function profile(op_name, fn)
  local start = vim.loop.hrtime()
  local success, ret = pcall(fn)
  local duration_ns = vim.loop.hrtime() - start
  if not success then
    print("Error during profiling " .. op_name .. ":", ret)
    os.exit(1)
  end
  return duration_ns / 1e6 -- convert to milliseconds
end

-- Grouped measurements
local results = {
  WRITE = {},
  READ = {},
  UPDATE = {},
  DELETE = {},
}

local function record(group, operation, ms)
  if not results[group][operation] then
    results[group][operation] = {}
  end
  table.insert(results[group][operation], ms)
end

-- Seed a dummy Pull Request
pull_request.upsert({
  mo_id = "bench:repo:1",
  provider = "bench",
  repo = "bench/repo",
  number = 1,
  title = "Bench PR",
  author = "author",
  state = "open",
  source_branch = "feat",
  target_branch = "master",
  description = "description",
  base_sha = "abcdef",
  head_sha = "123456",
  url = "http://bench",
  updated_at = "2026-08-28T00:00:00Z",
})

print("Running benchmarks (1000 iterations)...")

for i = 1, 1000 do
  local t_id = "thread-" .. i
  local c_id = "comment-" .. i

  -- 1. WRITE: Create Thread
  local ms_write_t = profile("create_thread", function()
    comments.create_thread({
      t_id = t_id,
      mo_id = "bench:repo:1",
      path = "src/main.lua",
      commit_sha = "123456",
      start_line = i,
      end_line = i,
      is_draft = true,
      resolved = false,
    })
  end)
  record("WRITE", "create_thread (insert)", ms_write_t)

  -- 2. WRITE: Add Comment
  local ms_write_c = profile("add_comment", function()
    comments.add_comment({
      c_id = c_id,
      t_id = t_id,
      remote_id = nil,
      author = "tester",
      body = "This is comment body " .. i,
      created_at = "2026-08-28T00:00:00Z",
      in_reply_to = nil,
    })
  end)
  record("WRITE", "add_comment (insert)", ms_write_c)

  -- 3. READ: Threads for Buffer
  local ms_read_tb = profile("threads_for_buffer", function()
    comments.threads_for_buffer("bench:repo:1", "src/main.lua", i)
  end)
  record("READ", "threads_for_buffer (seek)", ms_read_tb)

  -- 4. READ: Comments for Thread
  local ms_read_ct = profile("comments_for_thread", function()
    comments.comments_for_thread(t_id)
  end)
  record("READ", "comments_for_thread (index scan)", ms_read_ct)

  -- 4.5 READ: Comments for Buffer (Optimized single JOIN query)
  local ms_read_buf = profile("comments_for_buffer", function()
    comments.comments_for_buffer("bench:repo:1", "src/main.lua")
  end)
  record("READ", "comments_for_buffer (single JOIN)", ms_read_buf)

  -- 5. UPDATE: Update Comment
  local ms_update_c = profile("update_comment", function()
    comments.update_comment(c_id, "Updated body text " .. i)
  end)
  record("UPDATE", "update_comment (modify)", ms_update_c)

  -- 6. UPDATE: Resolve Thread
  local ms_update_r = profile("resolve_thread", function()
    comments.resolve_thread(t_id, true)
  end)
  record("UPDATE", "resolve_thread (modify)", ms_update_r)
end

-- 7. DELETE operations
for i = 1, 1000 do
  local t_id = "thread-" .. i
  local c_id = "comment-" .. i

  local ms_delete_c = profile("delete_comment", function()
    comments.delete_comment(c_id)
  end)
  record("DELETE", "delete_comment (remove)", ms_delete_c)

  local ms_delete_t = profile("delete_thread", function()
    comments.delete_thread(t_id)
  end)
  record("DELETE", "delete_thread (remove)", ms_delete_t)
end

-- Print Report
print("\n" .. string.rep("=", 68))
print(string.format("%-10s %-32s %-8s %-8s %-8s", "GROUP", "OPERATION", "AVG (ms)", "MIN (ms)", "MAX (ms)"))
print(string.rep("=", 68))

for _, group in ipairs({ "READ", "WRITE", "UPDATE", "DELETE" }) do
  for op, latencies in pairs(results[group]) do
    local total = 0
    local min = 999999
    local max = 0
    for _, lat in ipairs(latencies) do
      total = total + lat
      if lat < min then min = lat end
      if lat > max then max = lat end
    end
    local avg = total / #latencies
    print(string.format("%-10s %-32s %-8.4f %-8.4f %-8.4f", group, op, avg, min, max))
  end
  print(string.rep("-", 68))
end

storage.close()
os.remove(db_path)
