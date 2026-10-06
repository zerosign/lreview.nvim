-- Issue tracker tests: hub mapping, cache round-trip, search, correlation, and
-- the sequential page driver.
--
-- Fully offline: adapter.resolve is stubbed, adapter.base.executor_override
-- answers every CLI call, and lreview.thread.create_worker is replaced with a
-- synchronous fake so the paging driver can be asserted without a real libuv
-- thread (whose isolated Lua state would not see the executor override).

local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;"
    .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local issue_store = require("lreview.storage.issues")
local issues = require("lreview.issues")
local mappers = require("lreview.mappers")
local base = require("lreview.adapter.base")
local adapter = require("lreview.adapter")
local github = require("lreview.adapter.github")
local gitlab = require("lreview.adapter.gitlab")
local thread_mod = require("lreview.thread")
local init = require("lreview")

print("TEST: Starting Issue Tracker Tests...")

local test_db = "tmp/test_issues.db"
vim.fn.delete(test_db)
vim.fn.delete(test_db .. "-wal")
vim.fn.delete(test_db .. "-shm")

init.setup({
  defaults = {
    db_path = test_db,
    issues = { per_page = 2, max_pages = 3, stale_after_min = 5 },
  },
})
assert(storage.open())

local pass, fail = 0, 0
local function check(cond, msg)
  if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. msg) end
end

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------
local resolved_gh = {
  adapter = github, provider = "gh", host = "github.com", repo = "acme/widgets",
  cfg = { provider = "gh" }, cwd = project_root,
}
local real_resolve = adapter.resolve
adapter.resolve = function(_cwd) return resolved_gh end

local recorded = {}
local pages = {}   -- page number -> JSON array to return

base.executor_override = function(argv, _cwd)
  local joined = table.concat(argv, " ")
  recorded[#recorded + 1] = joined
  -- Order matters: the most specific route first.
  if joined:match("issues/%d+/comments") then
    return { stdout = [[
      [{"id": 11, "user": {"login": "bob"}, "created_at": "2026-01-02T00:00:00Z", "body": "discussion A"}]
    ]], code = 0, stderr = "" }
  end
  if joined:match("search/issues") then
    return { stdout = string.format([[{"total_count": 1, "items": %s}]], pages[1] or "[]"),
             code = 0, stderr = "" }
  end
  if joined:find("issues?", 1, true) then
    -- Anchor on the separator: "page=" also occurs inside "per_page=".
    local page = tonumber(joined:match("[?&]page=(%d+)")) or 1
    return { stdout = pages[page] or "[]", code = 0, stderr = "" }
  end
  if joined:match("/issues/%d+$") then
    return { stdout = [[
      {"number": 1, "title": "Single issue", "body": "only this", "state": "open",
       "user": {"login": "alice"}, "labels": [], "html_url": "https://x/1",
       "comments": 0, "updated_at": "2026-01-01T00:00:00Z"}
    ]], code = 0, stderr = "" }
  end
  return { stdout = "{}", code = 0, stderr = "" }
end

-- Synchronous worker fake: runs the target thread entry in-process. Installed
-- ONCE (before the first pull) because lreview.issues memoizes its worker --
-- replacing create_worker later would have no effect on the live singleton.
-- `park` holds completions back so the in-flight guard can be observed.
local real_create = thread_mod.create_worker
local park = false
local parked = {}
thread_mod.create_worker = function(mod_name, fn_name, cb)
  return {
    queue = function(self, payload)
      local mod = require(mod_name)
      local ok, res = pcall(mod[fn_name], test_db, "", payload)
      local fire = function() cb(ok and res or { ok = false, err = tostring(res) }) end
      if park then
        parked[#parked + 1] = fire
      else
        fire()
      end
    end,
  }
end

local function drain_parked()
  local guard = 0
  while #parked > 0 and guard < 64 do
    guard = guard + 1
    local f = table.remove(parked, 1)
    f()
  end
  return guard < 64
end

-- ===========================================================================
-- 1. Mappers
-- ===========================================================================
print("== 1. mappers ==")

local gh_raw = {
  number = 42, title = "Crash on load", body = "stack trace here", state = "open",
  user = { login = "alice" },
  labels = { { name = "bug" }, { name = "P1" } },
  html_url = "https://github.com/acme/widgets/issues/42",
  comments = 3, updated_at = "2026-01-05T00:00:00Z",
  assignees = { { login = "bob" } },
  milestone = { title = "v1.2" },
}
local issue = mappers.gh_issue_to_issue(gh_raw, "acme/widgets")
check(issue.issue_id == "github:acme/widgets:42", "issue_id is provider:repo:number")
check(issue.number == 42 and issue.title == "Crash on load", "number/title mapped")
check(issue.labels == "bug,P1", "labels flattened to a comma string")
check(issue.state == "open", "state mapped")
check(issue.comment_count == 3, "comment count mapped")
check(issue.assignees and issue.assignees[1] == "bob", "assignees mapped")
check(issue.milestone == "v1.2", "milestone mapped")

-- GraphQL-style uppercase states must normalize.
check(mappers.gh_issue_to_issue({ number = 1, state = "CLOSED" }, "a/b").state == "closed",
  "CLOSED normalizes to closed")

-- The /issues REST endpoint also returns pull requests; they must be dropped.
local mixed = { gh_raw, { number = 43, title = "a PR", pull_request = {} } }
local filtered = mappers.gh_issues_to_issues(mixed, "acme/widgets")
check(#filtered == 1 and filtered[1].number == 42, "PRs filtered out of the issue list")

local gl_issue = mappers.glab_issue_to_issue({
  iid = 7, title = "GL issue", description = "desc", state = "opened",
  author = { username = "carol" }, labels = { "infra", "bug" },
  web_url = "https://gitlab.com/grp/things/-/issues/7",
  user_notes_count = 2, updated_at = "2026-02-01T00:00:00Z",
  assignees = { { username = "dave" } },
}, "grp/things")
check(gl_issue.issue_id == "gitlab:grp/things:7", "gitlab iid becomes number in issue_id")
check(gl_issue.state == "open", "gitlab 'opened' normalized to 'open'")
check(gl_issue.body == "desc", "gitlab description becomes body")
check(gl_issue.labels == "infra,bug", "gitlab label array joined")
check(gl_issue.comment_count == 2, "user_notes_count becomes comment_count")
-- Repo is recoverable from the URL even when the caller passed a stale one.
check(gl_issue.repo == "grp/things", "gitlab repo kept from web_url parsing")

local note = mappers.gh_issue_note_to_note(
  { id = 99, user = { login = "bob" }, created_at = "2026-01-02T00:00:00Z", body = "hi" },
  "acme/widgets", 42)
check(note.note_id == "github:acme/widgets:42:note:99",
  "note_id is namespaced by issue (remote note ids collide across hubs)")
check(note.issue_id == "github:acme/widgets:42" and note.system == false, "note issue link + not system")

local gl_note = mappers.glab_issue_note_to_note(
  { id = 5, author = { username = "eve" }, body = "added label ~1", system = true },
  "grp/things", 7)
check(gl_note.system == true, "gitlab system notes flagged")
check(gl_note.note_id == "gitlab:grp/things:7:note:5", "gitlab note id namespaced")

-- ===========================================================================
-- 2. Cache round-trip + search
-- ===========================================================================
print("== 2. cache and search ==")
issue_store.upsert(issue)
local back = issue_store.by_number("github", "acme/widgets", 42)
check(back ~= nil, "issue readable by number (PK path)")
check(back and back.title == "Crash on load", "title survives flat round-trip")
check(back and back.labels == "bug,P1", "labels survive")
check(back and back.assignees and back.assignees[1] == "bob", "payload extras survive MessagePack")
check(back and back.milestone == "v1.2", "milestone survives")

issue_store.upsert_many({ gl_issue, mappers.gh_issue_to_issue(
  { number = 77, title = "Auth regression", body = "login flow broken on Safari", state = "open" },
  "acme/widgets") })
check(issue_store.count("github", "acme/widgets", "open") == 2, "count by repo+state")
check(issue_store.count("gitlab", "grp/things") == 1, "count other provider isolated in one db")

-- FTS trigram search over title AND body.
local s1 = issue_store.search("github", "acme/widgets", "regression")
check(#s1 == 1 and s1[1].number == 77, "title search finds the issue")
local s2 = issue_store.search("github", "acme/widgets", "Safari")
check(#s2 == 1 and s2[1].number == 77, "body search finds the issue")
-- Shorter than the trigram window: must fall back without erroring.
local s3 = issue_store.search("github", "acme/widgets", "77")
check(#s3 == 1, "sub-3-char query falls back to number match")
check(#issue_store.search("github", "acme/widgets", "nothin')") == 0, "no false positive + quote escape ok")

-- Notes.
issue_store.replace_notes(issue.issue_id, {
  { note_id = "n1", issue_id = issue.issue_id, remote_id = "1", author = "bob",
    created_at = "2026-01-02T00:00:00Z", body = "second", system = false },
  { note_id = "n2", issue_id = issue.issue_id, remote_id = "2", author = "bot",
    created_at = "2026-01-01T00:00:00Z", body = "first", system = true },
})
local notes = issue_store.notes_for(issue.issue_id)
check(#notes == 1, "system notes hidden by default")
local all_notes = issue_store.notes_for(issue.issue_id, { include_system = true })
check(#all_notes == 2 and all_notes[1].body == "first",
  "notes ordered oldest-first when included")
issue_store.replace_notes(issue.issue_id, {
  { note_id = "n3", issue_id = issue.issue_id, body = "replaced", system = false },
})
check(#issue_store.notes_for(issue.issue_id) == 1
    and issue_store.notes_for(issue.issue_id)[1].note_id == "n3",
  "replace_notes is a true replacement, not an append")

-- Staleness.
check(issue_store.is_stale("github", "acme/widgets", "open", 5) == true, "stale before first pull")
issue_store.mark_synced("github", "acme/widgets", "open")
check(issue_store.is_stale("github", "acme/widgets", "open", 5) == false, "fresh after mark_synced")
check(issue_store.is_stale("github", "acme/widgets", "closed", 5) == true, "staleness is per state")

-- ===========================================================================
-- 3. Worker entry point (page fetch) stays pure and offline
-- ===========================================================================
print("== 3. fetch_page_thread ==")
pages[1] = vim.json.encode({ gh_raw, { number = 43, title = "another", state = "open" } })
local res = issues.fetch_page_thread(test_db, "", { cwd = project_root, kind = "list", page = 1, per_page = 2 })
check(res.ok == true, "list page fetched through the worker entry")
check(res.issues and #res.issues == 2, "page rows returned (PRs already filtered)")
local argv1 = recorded[#recorded]
check(argv1:match("repos/{owner}/{repo}/issues%?state=open") ~= nil, "github list issues endpoint + state")
check(argv1:match("per_page=2") ~= nil and argv1:match("page=1") ~= nil, "explicit pagination args")

-- Capability gating for custom adapters without an issue tracker.
local no_issues = { adapter = { name = "gitea", capabilities = {} }, provider = "tea",
                    repo = "x/y", cfg = {}, cwd = project_root }
local real2 = adapter.resolve
adapter.resolve = function() return no_issues end
local gated = issues.fetch_page_thread(test_db, "", { cwd = project_root, kind = "list" })
check(gated.ok == false and gated.err:match("issue tracker") ~= nil,
  "adapter without the issues capability is refused, not guessed")
adapter.resolve = real2

-- Single issue + notes kinds.
local one = issues.fetch_page_thread(test_db, "", { cwd = project_root, kind = "issue", number = 1 })
check(one.ok and one.issue and one.issue.number == 1, "issue detail fetch works")
local nres = issues.fetch_page_thread(test_db, "", { cwd = project_root, kind = "notes", number = 1 })
check(nres.ok and nres.notes and #nres.notes == 1, "issue notes fetch works")

-- ===========================================================================
-- 4. Sequential page driver with progress (via the synchronous worker fake)
-- ===========================================================================
print("== 4. paging driver ==")
recorded = {}
pages[1] = vim.json.encode({ gh_raw, { number = 44, title = "p1 second", state = "open" } })
pages[2] = vim.json.encode({ { number = 45, title = "p2 first", state = "open" } })
local progress = {}
local done_ok, done_total
local started, serr = issues.pull_async({
  state = "open",
  on_progress = function(page, total) progress[#progress + 1] = { page = page, total = total } end,
  on_done = function(ok, total) done_ok, done_total = ok, total end,
})
check(started == true, "pull_async started (err=" .. tostring(serr) .. ")")
check(done_ok == true, "pull completed without error")
check(done_total == 3, "3 issues cached across 2 pages (got " .. tostring(done_total) .. ")")
check(#progress == 2, "progress fired once per page (got " .. #progress .. ")")
check(progress[1] and progress[1].page == 1 and progress[1].total == 2, "page 1 progress correct")
local list_calls = 0
for _, a in ipairs(recorded) do if a:match("issues%?") then list_calls = list_calls + 1 end end
check(list_calls == 2, "stopped after the short page: exactly 2 list calls")
check(issue_store.by_number("github", "acme/widgets", 45) ~= nil, "page 2 row is queryable")
check(issue_store.is_stale("github", "acme/widgets", "open", 5) == false, "sync timestamp recorded on success")

-- Re-entrancy guard: while a page is outstanding a second pull must refuse
-- rather than interleave two drivers on one worker slot. Parking the
-- completion makes "in flight" observable; the page is deliberately short
-- (1 row < per_page 2) so draining it ends the driver in a single step.
do
  local saved_page1 = pages[1]
  pages[1] = vim.json.encode({ gh_raw })
  park = true

  check(issues.pull_async({ state = "open", on_done = function() end }) == true, "first pull started")
  check(#parked == 1, "exactly one page parked in flight")
  local second_ok, second_err = issues.pull_async({ state = "closed" })
  check(second_ok == false and second_err ~= nil,
    "concurrent pull refused while a page is outstanding: " .. tostring(second_err))
  check(drain_parked(), "first driver drained")

  check(issues.pull_async({ state = "open", on_done = function() end }) == true,
    "pull allowed again once the previous driver drained")
  check(drain_parked(), "second driver drained")
  park = false
  pages[1] = saved_page1
end
check(issue_store.by_number("github", "acme/widgets", 42) ~= nil,
  "issue 42 still cached after the guard runs")

-- ===========================================================================
-- 5. Correlation: refs in an MR description resolve from cache, no network
-- ===========================================================================
print("== 5. description correlation ==")
local issue_views = require("lreview.ui.issues")
local before = #recorded
local refs = issue_views.referenced("Fixes #42 and also see acme/widgets#77; unrelated #9999")
check(#refs == 2, "two cached refs resolved (got " .. #refs .. ")")
check(refs[1].number == 42 and refs[2].number == 77, "refs sorted ascending")
check(refs[1].issue.title == "Crash on load", "resolved ref carries the cached row")
check(#recorded == before, "correlation made zero network calls")
check(#issue_views.referenced(nil) == 0, "nil description returns nothing")
check(#issue_views.referenced("no numbers here") == 0, "text without refs returns nothing")

-- ===========================================================================
-- 6. GitLab issue endpoints
-- ===========================================================================
print("== 6. gitlab endpoints ==")
adapter.resolve = function()
  return { adapter = gitlab, provider = "glab", host = "gitlab.com", repo = "grp/things",
           cfg = { provider = "glab" }, cwd = project_root }
end
recorded = {}
local glres = issues.fetch_page_thread(test_db, "", { cwd = project_root, kind = "list", page = 1, per_page = 2 })
check(glres.ok == true, "gitlab issue list fetched")
local glargv = recorded[#recorded]
-- base_argv inserts `--repo <path>` between the binary and the subcommand.
check(glargv:match("glab") ~= nil and glargv:match(" api projects/") ~= nil,
  "gitlab uses the api subcommand (after --repo)")
check(glargv:match("projects/grp%%2Fthings/issues") ~= nil, "project path url-encoded")
check(glargv:match("state=opened") ~= nil, "logical 'open' translated to gitlab 'opened'")
-- ===========================================================================
-- 7. Commands & UI Picker (:LocalReviewIssues, :LocalReviewIssue)
-- ===========================================================================
print("== 7. commands & picker UI ==")
local selected_items = nil
local original_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  selected_items = items
  if on_choice and #items > 0 then
    on_choice(items[1])
  end
end

-- Ensure test issues exist in cache
issue_store.upsert_many({
  {
    issue_id = "github:grp/things:101",
    provider = "github",
    repo = "grp/things",
    number = 101,
    title = "Test issue for UI picker",
    state = "open",
    body = "Detailed description",
    author = "tester",
    comments_count = 0,
    created_at = "2026-09-01T00:00:00Z",
    updated_at = "2026-09-01T00:00:00Z",
  }
})
issue_store.mark_synced("github", "grp/things", "open")

adapter.resolve = function()
  return { adapter = github, provider = "gh", host = "github.com", repo = "grp/things",
           cfg = { provider = "gh" }, cwd = project_root }
end

vim.cmd("LocalReviewIssues")
check(selected_items ~= nil and #selected_items > 0, ":LocalReviewIssues triggers picker with items")
check(selected_items[1].number == 101, "picker received issue #101")

local expected_buf = "lreview_issue://github/grp/things/101"
local bufnr = vim.fn.bufnr(expected_buf)
check(bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr), "issue buffer was created: " .. expected_buf)
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check(#lines > 0, "issue buffer contains markdown lines")

-- Test :LocalReviewIssue <number>
vim.cmd("LocalReviewIssue 101")
check(vim.api.nvim_get_current_buf() == bufnr, ":LocalReviewIssue 101 focuses issue buffer")

-- Regression: issue body containing build errors must not trigger false Command failed
local mock_err_body = '[{"number":18,"title":"FreeBSD Build?","body":"error: failed to run custom build command\\nfailed to download webrtc: 404 Not Found"}]'
local raw_res = base.run({"gh", "api"}, { executor = function() return { stdout = mock_err_body, stderr = "", code = 0 } end })
check(raw_res.ok == true, "JSON response with error logs in body is NOT treated as failed command")

vim.ui.select = original_select

thread_mod.create_worker = real_create
base.executor_override = nil
adapter.resolve = real_resolve
storage.close()
vim.fn.delete(test_db)
vim.fn.delete(test_db .. "-wal")
vim.fn.delete(test_db .. "-shm")

print("")
print(string.format("== RESULTS: %d passed, %d failed ==", pass, fail))
if fail > 0 then
  print("ALL ISSUE TESTS FAILED.")
  os.exit(1)
end
print("SUCCESS: issue mapping, cache, search, paging driver, correlation, and endpoints verified.")
print("ALL ISSUE TRACKER TESTS PASSED.")
