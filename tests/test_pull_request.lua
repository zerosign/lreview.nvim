-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local pr = require("lreview.pull_request")
local init = require("lreview")

print("TEST: Starting Pull Request List Unit Tests...")

-- ============================================================================
-- 1. Setup: temp DB + mocked adapter resolver
-- ============================================================================
local test_db_path = "tmp/test_pull_request_suite.db"
vim.fn.delete(test_db_path)
vim.fn.delete(test_db_path .. "-wal")
vim.fn.delete(test_db_path .. "-shm")

init.setup({
  defaults = {
    db_path = test_db_path,
  }
})

local ok, err = storage.open()
if not ok then
  print("FAIL: Could not open test database: " .. tostring(err))
  os.exit(1)
end

-- Mock adapter resolver to isolate from git remotes and network.
local original_resolve = adapter.resolve
adapter.resolve = function(cwd)
  return {
    adapter = {
      name = "gitlab",
      provider = "glab",
      list_pull_requests = function()
        return {
          { mo_id = "gitlab:zerodevs/sample-review:1", provider = "gitlab", repo = "zerodevs/sample-review", number = 1, title = "Add login flow", author = "zerodevs", state = "opened", source_branch = "feat/login", target_branch = "main", url = "https://gitlab.com/zerodevs/sample-review/-/merge_requests/1", updated_at = "2026-01-01T00:00:00Z" },
          { mo_id = "gitlab:zerodevs/sample-review:2", provider = "gitlab", repo = "zerodevs/sample-review", number = 2, title = "Fix login bug", author = "zerodevs", state = "opened", source_branch = "fix/login", target_branch = "main", url = "https://gitlab.com/zerodevs/sample-review/-/merge_requests/2", updated_at = "2026-01-02T00:00:00Z" },
          { mo_id = "gitlab:zerodevs/sample-review:3", provider = "gitlab", repo = "zerodevs/sample-review", number = 3, title = "Refactor database layer", author = "alice", state = "opened", source_branch = "refactor/db", target_branch = "main", url = "https://gitlab.com/zerodevs/sample-review/-/merge_requests/3", updated_at = "2026-01-03T00:00:00Z" },
          { mo_id = "gitlab:zerodevs/sample-review:4", provider = "gitlab", repo = "zerodevs/sample-review", number = 4, title = "Login page redesign", author = "bob", state = "opened", source_branch = "feat/login-page", target_branch = "main", url = "https://gitlab.com/zerodevs/sample-review/-/merge_requests/4", updated_at = "2026-01-04T00:00:00Z" },
        }
      end,
    },
    cfg = { provider = "glab", adapter = "gitlab" },
    repo = "zerodevs/sample-review",
    provider = "gitlab",
    host = "gitlab.com",
    cwd = cwd,
  }
end

-- ============================================================================
-- 2. Test fetch: adapter mapping + DB write
-- ============================================================================
local count, ferr = pr.fetch(".")
if not count or count ~= 4 then
  print("FAIL: fetch returned wrong count: " .. tostring(count) .. " err=" .. tostring(ferr))
  os.exit(1)
end
print("SUCCESS: fetch cached " .. count .. " pull requests.")

-- ============================================================================
-- 3. Test storage round-trip + provider mapping (glab -> gitlab)
-- ============================================================================
local cached = pull_request.list("gitlab", "zerodevs/sample-review")
if #cached ~= 4 then
  print("FAIL: pull_request.list returned " .. #cached .. " rows, expected 4")
  os.exit(1)
end
print("SUCCESS: storage upsert/list round-trip verified.")

-- ============================================================================
-- 4. Test list / search
-- ============================================================================
local listed = pr.list(".")
if #listed ~= 4 then
  print("FAIL: list returned " .. #listed .. " pull requests, expected 4")
  os.exit(1)
end
-- Newest first.
if listed[1].number ~= 4 then
  print("FAIL: list should be ordered newest first")
  os.exit(1)
end

-- Empty query returns all pull requests.
local all = pr.search(".", "")
if #all ~= 4 then
  print("FAIL: search('') should return all pull requests")
  os.exit(1)
end

-- Title substring (FTS5 path, >= 3 chars).
local login = pr.search(".", "login")
if #login ~= 3 then
  print("FAIL: search 'login' should match 3 pull requests, got " .. #login)
  os.exit(1)
end
-- Title prefix ranks first: "Login page redesign" (number 4).
if login[1].number ~= 4 then
  print("FAIL: title prefix 'Login' should rank first, got " .. tostring(login[1] and login[1].number))
  os.exit(1)
end

-- Title prefix match.
local add = pr.search(".", "add")
if #add ~= 1 or add[1].number ~= 1 then
  print("FAIL: search 'add' should match pull request 1 only")
  os.exit(1)
end

-- Number prefix (LIKE fallback path, < 3 chars).
local num = pr.search(".", "3")
if #num ~= 1 or num[1].number ~= 3 then
  print("FAIL: search '3' should match pull request 3 only")
  os.exit(1)
end

-- Case-insensitive title search.
local ci = pr.search(".", "DATABASE")
if #ci ~= 1 or ci[1].number ~= 3 then
  print("FAIL: case-insensitive search 'DATABASE' should match pull request 3")
  os.exit(1)
end

-- No match returns empty.
local none = pr.search(".", "zzz")
if #none ~= 0 then
  print("FAIL: search 'zzz' should return no pull requests")
  os.exit(1)
end
print("SUCCESS: search ranking verified.")

-- ============================================================================
-- 5. Teardown
-- ============================================================================
adapter.resolve = original_resolve
storage.close()
vim.fn.delete(test_db_path)
vim.fn.delete(test_db_path .. "-wal")
vim.fn.delete(test_db_path .. "-shm")
print("\nALL PULL REQUEST LIST TESTS PASSED.")
os.exit(0)