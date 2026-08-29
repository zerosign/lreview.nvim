-- Add sandbox lazy directories to path for sqlite.lua
local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local repo_users = require("lreview.storage.users")
local users = require("lreview.users")
local init = require("lreview")

print("TEST: Starting Repo Users Unit Tests...")

-- ============================================================================
-- 1. Setup: temp DB + mocked adapter resolver
-- ============================================================================
local test_db_path = "tmp/test_users_suite.db"
vim.fn.delete(test_db_path)

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
      list_users = function()
        return {
          { username = "zerodevs", name = "Yuri Setiantoko", avatar_url = "https://gitlab.com/avatar/zerodevs.png" },
          { username = "alice", name = "Alice Wonder", avatar_url = "https://gitlab.com/avatar/alice.png" },
          { username = "bob", name = "Bob Builder", avatar_url = "https://gitlab.com/avatar/bob.png" },
          { username = "carol", name = "Carol Dev", avatar_url = "https://gitlab.com/avatar/carol.png" },
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
-- 2. Test fetch_users: adapter mapping + DB write
-- ============================================================================
local count, ferr = users.fetch_users(".")
if not count or count ~= 4 then
  print("FAIL: fetch_users returned wrong count: " .. tostring(count) .. " err=" .. tostring(ferr))
  os.exit(1)
end
print("SUCCESS: fetch_users cached " .. count .. " users.")

-- ============================================================================
-- 3. Test storage round-trip
-- ============================================================================
local cached = repo_users.list("gitlab:zerodevs/sample-review")
if #cached ~= 4 then
  print("FAIL: repo_users.list returned " .. #cached .. " rows, expected 4")
  os.exit(1)
end
local found_alice = false
for _, u in ipairs(cached) do
  if u.username == "alice" and u.name == "Alice Wonder" then
    found_alice = true
  end
end
if not found_alice then
  print("FAIL: alice not found in cached users")
  os.exit(1)
end
print("SUCCESS: storage upsert/list round-trip verified.")

-- ============================================================================
-- 4. Test list_users / search_users ranking
-- ============================================================================
local listed = users.list_users(".")
if #listed ~= 4 then
  print("FAIL: list_users returned " .. #listed .. " users, expected 4")
  os.exit(1)
end

-- Empty query returns all users.
local all = users.search_users(".", "")
if #all ~= 4 then
  print("FAIL: search_users('') should return all users")
  os.exit(1)
end

-- Prefix match on username ranks first.
local pref = users.search_users(".", "al")
if #pref ~= 1 or pref[1].username ~= "alice" then
  print("FAIL: prefix search 'al' should match alice only")
  os.exit(1)
end

-- Case-insensitive prefix.
local ci = users.search_users(".", "AL")
if #ci ~= 1 or ci[1].username ~= "alice" then
  print("FAIL: case-insensitive search 'AL' should match alice")
  os.exit(1)
end

-- Substring in username.
local sub = users.search_users(".", "odev")
if #sub ~= 1 or sub[1].username ~= "zerodevs" then
  print("FAIL: substring search 'odev' should match zerodevs")
  os.exit(1)
end

-- Full-name substring match.
local name = users.search_users(".", "wonder")
if #name ~= 1 or name[1].username ~= "alice" then
  print("FAIL: name search 'wonder' should match alice")
  os.exit(1)
end

-- Ranking: prefix beats substring. 'bob' prefix vs 'bob' in 'bob'... use a
-- case where one user has a prefix match and another only a substring match.
-- 'b' prefix matches bob; 'b' substring also matches bob (same user). Instead
-- verify ordering with 'a': prefix 'a' -> alice; substring 'a' -> carol (name),
-- zerodevs (name). alice must come first.
local ranked = users.search_users(".", "a")
if #ranked < 2 or ranked[1].username ~= "alice" then
  print("FAIL: ranking should put prefix match alice first")
  os.exit(1)
end

-- No match returns empty.
local none = users.search_users(".", "zzz")
if #none ~= 0 then
  print("FAIL: search 'zzz' should return no users")
  os.exit(1)
end
print("SUCCESS: search_users ranking verified.")

-- ============================================================================
-- 5. Test storage clear
-- ============================================================================
repo_users.clear("gitlab:zerodevs/sample-review")
if #repo_users.list("gitlab:zerodevs/sample-review") ~= 0 then
  print("FAIL: clear() should remove all cached users")
  os.exit(1)
end
print("SUCCESS: storage clear verified.")

-- ============================================================================
-- 6. Teardown
-- ============================================================================
adapter.resolve = original_resolve
storage.close()
vim.fn.delete(test_db_path)
print("\nALL REPO USERS TESTS PASSED.")
os.exit(0)