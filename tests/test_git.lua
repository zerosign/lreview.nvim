local git = require("lreview.git")

print("TEST: Starting Git Helper Unit Tests...")

-- ============================================================================
-- 1. Test Remote URL Parsing (HTTP, SSH, SCP-like formats)
-- ============================================================================
local test_cases = {
  { url = "https://github.com/zerosign/lreview.nvim.git", domain = "github.com", repo = "zerosign/lreview.nvim" },
  { url = "git@github.com:zerosign/lreview.nvim.git", domain = "github.com", repo = "zerosign/lreview.nvim" },
  { url = "ssh://git@gitlab.com/owner/repo.git", domain = "gitlab.com", repo = "owner/repo" },
  { url = "git://github.com/owner/repo", domain = "github.com", repo = "owner/repo" },
  { url = "  https://github.com/owner/repo/  ", domain = "github.com", repo = "owner/repo" },
}

for _, tc in ipairs(test_cases) do
  local res = git.parse_remote_url(tc.url)
  if not res or res.domain ~= tc.domain or res.repo ~= tc.repo then
    print(string.format("FAIL: parse_remote_url failed for: %s (got %s/%s, expected %s/%s)",
      tc.url, res and res.domain or "nil", res and res.repo or "nil", tc.domain, tc.repo))
    os.exit(1)
  end
end

-- Test parse empty and invalid URLs
if git.parse_remote_url("") ~= nil then
  print("FAIL: parse_remote_url should return nil for empty string.")
  os.exit(1)
end

if git.parse_remote_url("invalid_url_without_separator") ~= nil then
  print("FAIL: parse_remote_url should return nil for invalid URL formats.")
  os.exit(1)
end

print("SUCCESS: Remote URL parser verified.")

-- ============================================================================
-- 2. Test Local Git Workspace Queries
-- ============================================================================
local cwd = vim.fn.getcwd()

-- Test root detection
local root = git.root(cwd)
if not root or root == "" then
  print("FAIL: git.root failed to detect active repository root.")
  os.exit(1)
end

-- Test branch detection
local branch = git.current_branch(cwd)
if not branch or branch == "" then
  print("FAIL: git.current_branch failed to detect active branch.")
  os.exit(1)
end

-- Test head sha resolution
local sha = git.head_sha(cwd)
if not sha or #sha ~= 40 then
  print("FAIL: git.head_sha failed to retrieve a valid 40-character commit hash: " .. tostring(sha))
  os.exit(1)
end

print("SUCCESS: Local workspace queries verified.")

-- ============================================================================
-- 3. Test Remotes and Primary Remote
-- ============================================================================
local remotes = git.remotes(cwd)
if #remotes == 0 then
  print("FAIL: git.remotes failed to query git remotes.")
  os.exit(1)
end

local primary = git.primary_remote(cwd)
if not primary or not primary.name or not primary.url then
  print("FAIL: git.primary_remote failed to detect the main origin remote.")
  os.exit(1)
end

print("SUCCESS: Remotes queries verified.")

-- ============================================================================
-- 4. Test Remote Branches & Default Branch Queries
-- ============================================================================
local remote_branches = git.remote_branches(cwd)
if type(remote_branches) ~= "table" then
  print("FAIL: git.remote_branches query returned invalid type.")
  os.exit(1)
end

local default_b = git.default_branch(cwd)
if not default_b or default_b == "" then
  print("FAIL: git.default_branch query failed.")
  os.exit(1)
end

print("SUCCESS: Remote branches and default branch queries verified.")

print("\nALL GIT HELPER TESTS PASSED.")
os.exit(0)
