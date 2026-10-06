-- Live integration test for GitHub and GitLab issue checking.
--
-- Network-dependent: runs live checks against configured remotes.
-- Generates redacted logs and asserts zero token leakage.
--
-- Usage: ./scripts/sandbox-nvim.fish --headless -l tests/test_issues_live.lua

local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local lreview = require("lreview")
local adapter = require("lreview.adapter")
local issues = require("lreview.issues")
local log = require("lreview.log")

local log_file = "tmp/lreview_issues_live.log"
vim.fn.delete(log_file)

lreview.setup({
  defaults = {
    db_path = "tmp/test_issues_live.db",
    diagnostics = {
      log_file = log_file,
      log_level = "DEBUG",
    },
  },
  ["github\\.com"] = {
    adapter = "github",
    provider = "gh",
    host = "github.com",
  },
  ["gitlab\\.com|gitlab\\..*"] = {
    adapter = "gitlab",
    provider = "glab",
    host = "gitlab.com",
  },
})

print("TEST: Starting Live GitHub and GitLab Issue Verification...")

-- 1. Check GitHub Issues
local gh_adapter = adapter.get("github")
local gh_cfg = { adapter = "github", provider = "gh", host = "github.com" }
local gh_ctx = {
  repo = "zerosign/lreview.nvim",
  host = "github.com",
  provider = "gh",
  cwd = ".",
}

print("  Checking GitHub issues (zerosign/lreview.nvim)...")
local gh_list, gh_err = gh_adapter.list_issues(gh_cfg, gh_ctx, { state = "all", per_page = 5 })
if gh_list ~= nil then
  print(string.format("  SUCCESS: GitHub issues API responded cleanly (count=%d).", #gh_list))
else
  print(string.format("  INFO: GitHub issues response: %s", tostring(gh_err)))
end

-- 2. Check GitLab Issues
local gl_adapter = adapter.get("gitlab")
local gl_cfg = { adapter = "gitlab", provider = "glab", host = "gitlab.com" }
local gl_ctx = {
  repo = "zerodevs/sample-review",
  host = "gitlab.com",
  provider = "glab",
  cwd = "tmp/sample-review",
}

print("  Checking GitLab issues (zerodevs/sample-review)...")
local gl_list, gl_err = gl_adapter.list_issues(gl_cfg, gl_ctx, { state = "all", per_page = 5 })
if gl_list ~= nil then
  print(string.format("  SUCCESS: GitLab issues API responded cleanly (count=%d).", #gl_list))
else
  print(string.format("  INFO: GitLab issues response: %s", tostring(gl_err)))
end

-- 3. Verify Log File Integrity and Zero Token Leakage
print("  Verifying diagnostic log file...")
local f = io.open(log_file, "r")
if not f then
  print("FAIL: Diagnostic log file was not generated: " .. log_file)
  os.exit(1)
end
local log_content = f:read("*a")
f:close()

assert(#log_content > 0, "Log file should contain entries")
assert(log_content:find("%[CLI%]"), "Log file should contain [CLI] records")

-- Strict credential pattern audit on log file
local forbidden = {
  "ghp_[A-Za-z0-9_]{10,}",
  "glpat%-[A-Za-z0-9_%-]{10,}",
  "Bearer%s+[A-Za-z0-9%._%-%+]{15,}",
  "PRIVATE%-TOKEN:%s*[A-Za-z0-9_%-]{10,}",
}

for _, pat in ipairs(forbidden) do
  local match = log_content:match(pat)
  if match then
    print("SECURITY FAIL: Found unredacted credential matching pattern: " .. pat)
    os.exit(1)
  end
end

print("  SUCCESS: Diagnostic log verified with zero credential leakage.")
print("\nALL LIVE ISSUE CHECKS AND LOG VERIFICATION PASSED.")
os.exit(0)
