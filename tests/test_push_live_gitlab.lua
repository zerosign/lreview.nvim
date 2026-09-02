-- Live integration test: push a comment NEW-THREAD and a REPLY through the
-- gitlab adapter against the real zerodevs/sample-review MR, verifying local
-- state transitions to SYNCED with remote note IDs, then cleaning up remotely.
--
-- Network-dependent: runs under `just test-integration` (skipped by `just test`).

local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local comments = require("lreview.storage.comments")
local review = require("lreview.review")
local adapter = require("lreview.adapter")

require("lreview").setup({
  defaults = {
    db_path = vim.fn.stdpath("data") .. "/lreview/lreview.db",
  },
  ["gitlab\\.com|gitlab\\..*"] = {
    adapter = "gitlab",
    provider = "glab",
    host = "gitlab.com",
  },
})

local ok, err = storage.open()
if not ok then
  print("FAIL: Database failed to open:", err)
  os.exit(1)
end

-- Test fixtures
local REPO_DIR = "tmp/sample-review"
local PATH = "src/calculator_1788362614.py"
local LINE = 8
local BODY_NEW = "live-push new-thread " .. tostring(os.time())
local BODY_REPLY = "live-push reply " .. tostring(os.time())

print("TEST: Initializing live GitLab session for " .. REPO_DIR .. " ...")
local detail, err_gl = review.init_session(REPO_DIR)
if not detail then
  print("FAIL: Could not start GitLab review:", err_gl)
  os.exit(1)
end
print("  mr=" .. tostring(detail.number), "mo_id=" .. detail.mo_id)

-- Resolve adapter + ctx (mirrors submit_review_thread).
local resolved = adapter.resolve(detail.cwd or REPO_DIR)
if not resolved then
  print("FAIL: adapter.resolve failed for live repo.")
  os.exit(1)
end
print("  resolved provider=" .. tostring(resolved.provider), "adapter=" .. tostring(resolved.adapter), "host=" .. tostring(resolved.host))
if resolved.provider ~= "glab" then
  print("FAIL: expected gitlab/glab adapter for gitlab.com, got provider=" .. tostring(resolved.provider))
  os.exit(1)
end

-- Keep only our test drafts for this MR so the push is deterministic.
for _, t in ipairs(comments.threads_for_mr(detail.mo_id)) do
  for _, c in ipairs(comments.comments_for_thread(t.t_id)) do
    comments.delete_comment(c.c_id)
  end
  comments.delete_thread(t.t_id)
end

-- ============================================================================
-- 1. Push a NEW-THREAD inline comment
-- ============================================================================
print("TEST: Push new-thread inline comment...")
local new_tid = "live-new-" .. tostring(os.time())
local new_cid = "live-new-c-" .. tostring(os.time())
comments.create_thread({
  t_id = new_tid, mo_id = detail.mo_id, path = PATH,
  start_line = LINE, end_line = LINE, is_draft = true,
})
comments.add_comment({
  c_id = new_cid, t_id = new_tid, state = comments.STATE.DRAFT,
  body = BODY_NEW, author = "zerodevs", created_at = "2026-09-02T00:00:00Z",
})

local count, push_err = review._submit_pushes(detail, resolved, adapter.ctx(resolved, detail.number), nil, "approve")
if not count or count < 1 or push_err then
  print("FAIL: new-thread push failed. count=" .. tostring(count), "err=" .. tostring(push_err))
  os.exit(1)
end
print("  pushed count=" .. count)

-- Mirror submit_review_thread: reconcile the just-pushed thread from the remote
-- (the local draft was deleted on push; the remote discussion re-imports it).
local remote_threads = review._fetch_remote_threads(detail, resolved, adapter.ctx(resolved, detail.number))
review._reconcile_threads(detail, remote_threads)

-- The pushed draft thread is deleted locally and re-imported from the remote
-- under the remote discussion id; find the synced note by scanning MR threads.
local new_com = nil
local new_thread = nil
for _, t in ipairs(comments.threads_for_mr(detail.mo_id)) do
  for _, c in ipairs(comments.comments_for_thread(t.t_id)) do
    if c.body == BODY_NEW then new_com = c; new_thread = t end
  end
end
if not new_com or new_com.state ~= comments.STATE.SYNCED or not new_com.remote_id then
  print("FAIL: new comment not SYNCED with remote_id. state=" .. tostring(new_com and new_com.state), "remote_id=" .. tostring(new_com and new_com.remote_id))
  os.exit(1)
end
if not new_thread or not comments.thread_is_synced(new_thread.state) then
  print("FAIL: new thread not SYNCED after push.")
  os.exit(1)
end
print("  SUCCESS: new-thread note remote_id=" .. new_com.remote_id .. " thread=" .. new_thread.t_id)

-- ============================================================================
-- 2. Push a REPLY on the pushed thread
-- ============================================================================
print("TEST: Push a reply on the pushed thread...")
local reply_cid = "live-reply-c-" .. tostring(os.time())
comments.add_comment({
  c_id = reply_cid, t_id = new_thread.t_id, state = comments.STATE.DRAFT,
  body = BODY_REPLY, author = "zerodevs", created_at = "2026-09-02T00:00:00Z",
})

local count2, push_err2 = review._submit_pushes(detail, resolved, adapter.ctx(resolved, detail.number), nil, "approve")
if not count2 or count2 < 1 or push_err2 then
  print("FAIL: reply push failed. count=" .. tostring(count2), "err=" .. tostring(push_err2))
  os.exit(1)
end
print("  pushed count=" .. count2)

local reply_com = nil
for _, c in ipairs(comments.comments_for_thread(new_thread.t_id)) do
  if c.body == BODY_REPLY then reply_com = c end
end
if not reply_com or reply_com.state ~= comments.STATE.SYNCED or not reply_com.remote_id then
  print("FAIL: reply not SYNCED with remote_id. state=" .. tostring(reply_com and reply_com.state), "remote_id=" .. tostring(reply_com and reply_com.remote_id))
  os.exit(1)
end
print("  SUCCESS: reply remote_id=" .. reply_com.remote_id .. " on thread=" .. new_thread.t_id)

-- ============================================================================
-- 3. Verify both notes exist on the remote discussion, then clean up
-- ============================================================================
print("TEST: Verifying remote thread carries both notes...")
local project = "zerodevs/sample-review"
local api_project = project:gsub("/", "%%2F")
local disc_res = vim.system({
  "glab", "api", string.format("projects/%s/merge_requests/%d/discussions", api_project, detail.number),
}, { text = true, cwd = REPO_DIR }):wait()
local found_notes = 0
if disc_res.code == 0 then
  local discs = vim.json.decode(disc_res.stdout)
  for _, d in ipairs(discs) do
    for _, n in ipairs(d.notes or {}) do
      if tostring(n.id) == new_com.remote_id or tostring(n.id) == reply_com.remote_id then
        found_notes = found_notes + 1
      end
    end
  end
end
if found_notes ~= 2 then
  print("FAIL: expected 2 test notes on remote, found " .. found_notes)
  os.exit(1)
end
print("  SUCCESS: both notes present on remote discussion.")

-- Cleanup: delete the two notes remotely (replies by id on the discussion).
local del_disc = vim.system({
  "glab", "api", string.format("projects/%s/merge_requests/%d/discussions", api_project, detail.number),
}, { text = true, cwd = REPO_DIR }):wait()
if del_disc.code == 0 then
  for _, d in ipairs(vim.json.decode(del_disc.stdout)) do
    for _, n in ipairs(d.notes or {}) do
      if tostring(n.id) == new_com.remote_id or tostring(n.id) == reply_com.remote_id then
        vim.system({
          "glab", "api", "-X", "DELETE",
          string.format("projects/%s/merge_requests/%d/discussions/%s/notes/%s", api_project, detail.number, d.id, n.id),
        }, { text = true, cwd = REPO_DIR }):wait()
      end
    end
  end
end

-- Local cleanup
for _, t in ipairs(comments.threads_for_mr(detail.mo_id)) do
  for _, c in ipairs(comments.comments_for_thread(t.t_id)) do
    comments.delete_comment(c.c_id)
  end
  comments.delete_thread(t.t_id)
end

storage.close()
print("\nALL LIVE GITLAB COMMENT & REPLY PUSH TESTS PASSED.")
os.exit(0)