-- Adapter and CLI Process Profiler for lreview.nvim
-- Profiles subprocess spawn latency, network API round-trip times, and Neovim Lua memory footprint.

local function get_mem_kb()
  collectgarbage("collect")
  return collectgarbage("count")
end

local function profile_cmd(name, cmd)
  local start = vim.uv.hrtime()
  local res = vim.system(cmd, { text = true }):wait()
  local duration_ms = (vim.uv.hrtime() - start) / 1e6
  print(string.format(" %-20s Latency: %8.2f ms | Exit: %d | Size: %d bytes", name, duration_ms, res.code, #res.stdout))
  return res.stdout
end

print("====================================================================")
print("             LOCAL REVIEW CLI AND NETWORK LATENCY PROFILE           ")
print("====================================================================")
print("Subprocess shell spawn + remote network API query times:\n")

-- Check GitHub CLI Authentication
local gh_status = vim.system({ "gh", "auth", "status" }):wait()
if gh_status.code == 0 then
  profile_cmd("gh pr list (5 items)", { "gh", "pr", "list", "--limit", "5" })
  profile_cmd("gh pr view (metadata)", { "gh", "pr", "view", "--json", "title,body,number" })
else
  print(" [Notice] GitHub CLI (gh) not authenticated on this machine. Skipping GH profile.")
end

-- Check GitLab CLI Authentication
local glab_status = vim.system({ "glab", "auth", "status" }):wait()
if glab_status.code == 0 then
  profile_cmd("glab mr list (5 items)", { "glab", "mr", "list", "--per-page", "5" })
else
  print(" [Notice] GitLab CLI (glab) not authenticated on this machine. Skipping GitLab profile.")
end
print(string.rep("─", 68))

-- Profile Memory and JSON Decoding CPU usage
print("\n====================================================================")
print("             LUA MEMORY AND PARSING CPU PROFILE                     ")
print("====================================================================")
print("Decoding a large JSON payload (1000 simulated comments):\n")

-- Construct a simulated 1000-comment JSON string (~250 KB)
local parts = { "[" }
for i = 1, 1000 do
  parts[#parts + 1] = string.format([[
    {
      "id": %d,
      "body": "This is a dummy comment body %d simulating metadata sizes from github/gitlab APIs.",
      "author": { "username": "user-%d", "name": "User Person %d" },
      "created_at": "2026-08-29T12:00:00Z",
      "position": { "new_path": "lua/lreview/init.lua", "new_line": %d }
    }%s]], i, i, i, i, i, (i < 1000 and "," or ""))
end
parts[#parts + 1] = "]"
local sample_json = table.concat(parts)

local mem_before = get_mem_kb()
local start_parse = vim.uv.hrtime()
local parsed = vim.json.decode(sample_json)
local parse_ms = (vim.uv.hrtime() - start_parse) / 1e6
local mem_after = get_mem_kb()

print(string.format(" JSON Decode CPU time (1000 comments): %.2f ms", parse_ms))
print(string.format(" Lua memory footprint of parsed table:  %.2f KB", mem_after - mem_before))
print(string.rep("=", 68))
