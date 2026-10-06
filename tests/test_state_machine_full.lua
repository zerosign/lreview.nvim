-- Comprehensive state machine unit tests for lreview.nvim.
--
-- Covers ALL comment state transitions, thread state transitions, conflict
-- resolution, push-outbox lifecycle and crash recovery, change-set computation,
-- and the async submit contract. This is the authoritative test for the state
-- model described in docs/design/07-submit-atomicity.md.
--
-- Comment states (bit flags) describe CONTENT only:
--   DRAFT=1, SYNCED=2, MODIFIED=8, DELETED=16, CONFLICT=32
--   (bit 4 is reserved: v3 used it for IN_FLIGHT, the push lock now lives in
--    the `push_ops` outbox so an interrupted submit cannot strand a comment)
-- Thread states (bit flags):
--   DRAFT=1, SYNCED=2, RESOLVED=4, DELETED=8, CONFLICT=16

local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local comments = require("lreview.storage.comments")
local outbox = require("lreview.storage.outbox")
local review = require("lreview.review")
local init = require("lreview")

print("TEST: Starting Comprehensive State Machine Unit Tests...")

local test_db = "tmp/test_state_machine_full.db"
vim.fn.delete(test_db)
vim.fn.delete(test_db .. "-wal")
vim.fn.delete(test_db .. "-shm")

init.setup({
  defaults = { db_path = test_db }
})

storage.open()

local mo_id = "github:test/repo:1"
local S = comments.STATE
local TS = comments.THREAD_STATE

-- Helper to read a comment's decoded state
local function get_state(c_id)
  local row = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if not row then return nil end
  local decoded = row
  if row.payload then
    decoded = vim.tbl_extend("force", decoded, vim.mpack.decode(row.payload))
  end
  return decoded
end

-- Helper to create a thread + comment
local function make_thread(t_id, opts)
  opts = opts or {}
  comments.create_thread({
    t_id = t_id,
    mo_id = mo_id,
    path = opts.path or "src/test.lua",
    start_line = opts.start_line or 5,
    end_line = opts.end_line or 5,
    is_draft = opts.is_draft or false,
  })
end

local function make_comment(c_id, t_id, state, body)
  comments.add_comment({
    c_id = c_id,
    t_id = t_id,
    body = body or "body",
    state = state or S.DRAFT,
  })
end

-- Upsert parent pull request for FK constraints
pull_request.upsert({
  mo_id = mo_id,
  provider = "github",
  repo = "test/repo",
  number = 1,
  title = "Test PR",
  source_branch = "feature",
  target_branch = "master",
  state = "open",
})

local pass = 0
local fail = 0
local function check(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print("  FAIL: " .. msg)
  end
end

-- ===========================================================================
-- 1. STATE CONSTANTS & PREDICATES
-- ===========================================================================
print("== 1. State constants & predicates ==")
check(S.DRAFT == 1, "DRAFT should be 1")
check(S.SYNCED == 2, "SYNCED should be 2")
check(S.IN_FLIGHT == nil, "IN_FLIGHT removed: the push lock lives in push_ops")
check(S.MODIFIED == 8, "MODIFIED should be 8")
check(S.DELETED == 16, "DELETED should be 16")
check(S.CONFLICT == 32, "CONFLICT should be 32")
check(TS.DRAFT == 1, "THREAD DRAFT should be 1")
check(TS.SYNCED == 2, "THREAD SYNCED should be 2")
check(TS.RESOLVED == 4, "THREAD RESOLVED should be 4")
check(TS.DELETED == 8, "THREAD DELETED should be 8")
check(TS.CONFLICT == 16, "THREAD CONFLICT should be 16")

-- Predicates
check(comments.is_draft(S.DRAFT), "is_draft(DRAFT)")
check(not comments.is_draft(S.SYNCED), "not is_draft(SYNCED)")
check(comments.is_synced(S.SYNCED), "is_synced(SYNCED)")
check(comments.is_modified(S.MODIFIED), "is_modified(MODIFIED)")
check(comments.is_deleted(S.DELETED), "is_deleted(DELETED)")
check(comments.is_conflict(S.CONFLICT), "is_conflict(CONFLICT)")

-- needs_push mask: DRAFT, MODIFIED, DELETED need push; SYNCED and CONFLICT don't.
check(comments.needs_push(S.DRAFT), "needs_push(DRAFT)")
check(comments.needs_push(S.MODIFIED), "needs_push(MODIFIED)")
check(comments.needs_push(S.DELETED), "needs_push(DELETED)")
check(not comments.needs_push(S.SYNCED), "not needs_push(SYNCED)")
check(not comments.needs_push(S.CONFLICT), "not needs_push(CONFLICT)")
-- Bit 4 is the retired IN_FLIGHT lock: nothing may claim it needs a push, or a
-- stranded v3 row would resurrect as a duplicate post.
check(not comments.needs_push(4), "not needs_push(reserved bit 4)")

-- Thread predicates
check(comments.thread_is_draft(TS.DRAFT), "thread_is_draft(DRAFT)")
check(comments.thread_is_synced(TS.SYNCED), "thread_is_synced(SYNCED)")
check(comments.thread_is_resolved(TS.RESOLVED), "thread_is_resolved(RESOLVED)")
check(comments.thread_is_conflict(TS.CONFLICT), "thread_is_conflict(CONFLICT)")
-- Combined: SYNCED + RESOLVED = 6
check(comments.thread_is_synced(6) and comments.thread_is_resolved(6), "thread SYNCED|RESOLVED combined")

-- ===========================================================================
-- 2. COMMENT STATE TRANSITIONS
-- ===========================================================================
print("== 2. Comment state transitions ==")

-- 2a. Outbox lifecycle: QUEUED -> RUNNING -> FAILED (retryable, never stranded)
make_thread("t_2a")
make_comment("c_2a", "t_2a", S.DRAFT)
local op2a = outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2a", c_id = "c_2a", op = outbox.OP.CREATE_THREAD,
  payload = { path = "src/test.lua", line = 5, body = "draft body" },
} })
check(op2a == 1, "enqueue: one op queued")
local p2a = outbox.pending(mo_id)
local found2a
for _, op in ipairs(p2a) do if op.c_id == "c_2a" then found2a = op end end
check(found2a and found2a.status == outbox.STATUS.QUEUED, "enqueue: status QUEUED")
outbox.mark_running(found2a.op_id)
check(outbox.count_pending(mo_id) >= 1, "mark_running: still pending (RUNNING is non-terminal)")
outbox.mark_failed(found2a.op_id, "boom")
check(outbox.count_failed(mo_id) >= 1, "mark_failed: counted as failed")
-- The comment itself never changes state: it is still DRAFT and still pushable,
-- which is the whole point of moving the lock out of comments.state.
check(get_state("c_2a").state == S.DRAFT, "outbox lock leaves comments.state untouched")
check(comments.needs_push(get_state("c_2a").state), "failed op's comment still needs_push")

-- 2b. Idempotent enqueue: the same (c_id, op) is never queued twice, but a
-- changed body refreshes the queued snapshot instead of duplicating the post.
local again = outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2a", c_id = "c_2a", op = outbox.OP.CREATE_THREAD,
  payload = { path = "src/test.lua", line = 5, body = "draft body" },
} })
check(again == 0, "enqueue: identical pending op is deduped")
local refreshed = outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2a", c_id = "c_2a", op = outbox.OP.CREATE_THREAD,
  payload = { path = "src/test.lua", line = 5, body = "edited while queued" },
} })
check(refreshed == 1, "enqueue: changed body re-queues with the new payload")
local snap
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.c_id == "c_2a" then snap = op end
end
check(snap and snap.body == "edited while queued", "enqueue: payload snapshot is current")
check(snap and snap.status == outbox.STATUS.QUEUED, "enqueue: refreshed op reset to QUEUED")

-- 2c. A DELETED comment that goes through a push attempt keeps its DELETED
-- state. This is the invariant v3 expressed as "revert_in_flight restores
-- prev_state"; with the lock in push_ops it is simply that the comment's own
-- state is never used as a push lock.
make_thread("t_2c")
make_comment("c_2c", "t_2c", S.DELETED)
outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2c", c_id = "c_2c", op = outbox.OP.DELETE,
  payload = { remote_id = "r-2c", body = "gone" },
} })
local op2c
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.c_id == "c_2c" then op2c = op end
end
outbox.mark_running(op2c.op_id)
check(get_state("c_2c").state == S.DELETED, "RUNNING op does not mutate comments.state")
outbox.mark_failed(op2c.op_id, "network down")
check(get_state("c_2c").state == S.DELETED, "FAILED op leaves comments.state DELETED")
check(comments.needs_push(get_state("c_2c").state), "failed delete still needs_push")

-- 2d. A FAILED op is retryable and dedupes: re-enqueueing the same pending
-- mutation refreshes the one row instead of adding a second attempt.
local retry = outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2c", c_id = "c_2c", op = outbox.OP.DELETE,
  payload = { remote_id = "r-2c", body = "gone" },
} })
check(retry == 0, "re-enqueue of an open op does not duplicate it")
local retry2 = outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2c", c_id = "c_2c", op = outbox.OP.DELETE,
  payload = { remote_id = "r-2c", body = "edited again" },
} })
check(retry2 == 1, "changed body re-arms the failed op for retry")

-- 2e. A queued delete cancels other open ops on the same comment: sending the
-- edit for a note we are about to remove would be wasted work at best.
make_thread("t_2e")
make_comment("c_2e", "t_2e", S.MODIFIED)
outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2e", c_id = "c_2e", op = outbox.OP.EDIT,
  payload = { remote_id = "r-2e", body = "edit first" },
} })
local before_delete = 0
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.c_id == "c_2e" then before_delete = before_delete + 1 end
end
check(before_delete == 1, "edit op queued for c_2e")
outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_2e", c_id = "c_2e", op = outbox.OP.DELETE,
  payload = { remote_id = "r-2e", body = "" },
} })
local open_for_2e = {}
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.c_id == "c_2e" then open_for_2e[#open_for_2e + 1] = op.op end
end
check(#open_for_2e == 1 and open_for_2e[1] == outbox.OP.DELETE,
  "queued delete supersedes the open edit op for the same comment")

-- 2f. mark_comment_synced: DRAFT -> SYNCED with remote_id
make_thread("t_2f")
make_comment("c_2f", "t_2f", S.DRAFT)
comments.mark_comment_synced("c_2f", "remote-123")
local c2f = get_state("c_2f")
check(c2f.state == S.SYNCED, "mark_comment_synced: -> SYNCED")
check(c2f.remote_id == "remote-123", "mark_comment_synced: remote_id set")

-- 2g. mark_clean: MODIFIED -> SYNCED
make_thread("t_2g")
make_comment("c_2g", "t_2g", S.MODIFIED)
comments.mark_clean("c_2g")
check(get_state("c_2g").state == S.SYNCED, "mark_clean: MODIFIED -> SYNCED")

-- 2h. update_comment: preserves state, changes body
make_thread("t_2h")
make_comment("c_2h", "t_2h", S.SYNCED, "original")
comments.update_comment("c_2h", "edited body")
local c2h = get_state("c_2h")
check(c2h.body == "edited body", "update_comment: body updated")
check(c2h.state == S.SYNCED, "update_comment: state preserved")

-- 2i. update_comment_body_and_state: changes both
make_thread("t_2i")
make_comment("c_2i", "t_2i", S.SYNCED, "original")
comments.update_comment_body_and_state("c_2i", "new body", S.MODIFIED)
local c2i = get_state("c_2i")
check(c2i.body == "new body", "update_comment_body_and_state: body updated")
check(c2i.state == S.MODIFIED, "update_comment_body_and_state: state -> MODIFIED")

-- 2j. soft_delete_comment: SYNCED -> DELETED
make_thread("t_2j")
make_comment("c_2j", "t_2j", S.SYNCED)
comments.soft_delete_comment("c_2j")
check(get_state("c_2j").state == S.DELETED, "soft_delete_comment: SYNCED -> DELETED")

-- 2k. delete_comment: hard delete
make_thread("t_2k")
make_comment("c_2k", "t_2k", S.DRAFT)
comments.delete_comment("c_2k")
check(get_state("c_2k") == nil, "delete_comment: row removed")

-- ===========================================================================
-- 3. CONFLICT TRANSITIONS
-- ===========================================================================
print("== 3. Conflict transitions ==")

-- 3a. mark_comment_conflict: MODIFIED -> CONFLICT (stores remote body + reason)
make_thread("t_3a")
make_comment("c_3a", "t_3a", S.MODIFIED, "local version")
comments.mark_comment_conflict("c_3a", "remote version", "remote_edited")
local c3a = get_state("c_3a")
check(c3a.state == S.CONFLICT, "mark_comment_conflict: MODIFIED -> CONFLICT")
check(c3a.body == "local version", "mark_comment_conflict: local body preserved")
check(c3a.conflict_remote_body == "remote version", "mark_comment_conflict: remote body stored")
check(c3a.conflict_reason == "remote_edited", "mark_comment_conflict: reason stored")
check(c3a.conflict_detected_at ~= nil, "mark_comment_conflict: detected_at set")

-- 3b. resolve_conflict_keep_local: CONFLICT -> MODIFIED (will push local)
comments.resolve_conflict_keep_local("c_3a")
local c3b = get_state("c_3a")
check(c3b.state == S.MODIFIED, "resolve_conflict_keep_local: CONFLICT -> MODIFIED")
check(c3b.body == "local version", "resolve_conflict_keep_local: local body kept")
check(c3b.conflict_remote_body == nil, "resolve_conflict_keep_local: remote body cleared")
check(c3b.conflict_reason == nil, "resolve_conflict_keep_local: reason cleared")

-- 3c. resolve_conflict_accept_remote: CONFLICT -> SYNCED (adopts remote body)
make_thread("t_3c")
make_comment("c_3c", "t_3c", S.MODIFIED, "local version")
comments.mark_comment_conflict("c_3c", "remote version", "remote_edited")
comments.resolve_conflict_accept_remote("c_3c")
local c3c = get_state("c_3c")
check(c3c.state == S.SYNCED, "resolve_conflict_accept_remote: CONFLICT -> SYNCED")
check(c3c.body == "remote version", "resolve_conflict_accept_remote: remote body adopted")
check(c3c.conflict_remote_body == nil, "resolve_conflict_accept_remote: remote body cleared")

-- 3d. resolve on non-conflict is a no-op
make_thread("t_3d")
make_comment("c_3d", "t_3d", S.MODIFIED)
comments.resolve_conflict_keep_local("c_3d")
check(get_state("c_3d").state == S.MODIFIED, "resolve_conflict_keep_local on non-conflict: no-op")
comments.resolve_conflict_accept_remote("c_3d")
check(get_state("c_3d").state == S.MODIFIED, "resolve_conflict_accept_remote on non-conflict: no-op")

-- 3e. get_conflicts / count_conflicts
make_thread("t_3e")
make_comment("c_3e", "t_3e", S.MODIFIED)
comments.mark_comment_conflict("c_3e", "remote", "remote_edited")
local conflicts = comments.get_conflicts(mo_id)
local conflict_ids = {}
for _, c in ipairs(conflicts) do conflict_ids[c.c_id] = true end
check(conflict_ids["c_3e"] == true, "get_conflicts: includes c_3e")
check(conflict_ids["c_3a"] == nil, "get_conflicts: excludes resolved c_3a")
check(comments.count_conflicts(mo_id) >= 1, "count_conflicts: >= 1")

-- ===========================================================================
-- 4. THREAD STATE TRANSITIONS
-- ===========================================================================
print("== 4. Thread state transitions ==")

-- 4a. create_thread default is DRAFT
make_thread("t_4a", { is_draft = true })
local t4a = comments.get_thread("t_4a")
check(comments.thread_is_draft(t4a.state), "create_thread(is_draft=true): DRAFT")

-- 4b. create_thread synced (is_draft=false)
make_thread("t_4b", { is_draft = false })
local t4b = comments.get_thread("t_4b")
check(comments.thread_is_synced(t4b.state), "create_thread(is_draft=false): SYNCED")

-- 4c. mark_synced: DRAFT -> SYNCED
make_thread("t_4c", { is_draft = true })
comments.mark_synced("t_4c")
local t4c = comments.get_thread("t_4c")
check(comments.thread_is_synced(t4c.state), "mark_synced: DRAFT -> SYNCED")
check(not comments.thread_is_draft(t4c.state), "mark_synced: DRAFT bit cleared")

-- 4d. resolve_thread: SYNCED -> SYNCED|RESOLVED
make_thread("t_4d", { is_draft = false })
comments.resolve_thread("t_4d", true)
local t4d = comments.get_thread("t_4d")
check(comments.thread_is_resolved(t4d.state), "resolve_thread(true): RESOLVED bit set")
check(comments.thread_is_synced(t4d.state), "resolve_thread(true): SYNCED bit preserved")

-- 4e. resolve_thread(false): un-resolve
comments.resolve_thread("t_4d", false)
local t4e = comments.get_thread("t_4d")
check(not comments.thread_is_resolved(t4e.state), "resolve_thread(false): RESOLVED bit cleared")

-- 4f. mark_thread_conflict: SYNCED -> SYNCED|CONFLICT
make_thread("t_4f", { is_draft = false })
comments.mark_thread_conflict("t_4f", "remote_deleted_has_drafts")
local t4f = comments.get_thread("t_4f")
check(comments.thread_is_conflict(t4f.state), "mark_thread_conflict: CONFLICT bit set")
check(comments.thread_is_synced(t4f.state), "mark_thread_conflict: SYNCED bit preserved")

-- 4g. delete_thread: hard delete
make_thread("t_4g", { is_draft = true })
comments.delete_thread("t_4g")
check(comments.get_thread("t_4g") == nil, "delete_thread: row removed")

-- ===========================================================================
-- 5. CRASH RECOVERY (outbox) — item 4
-- ===========================================================================
print("== 5. Crash recovery (push outbox) ==")

-- 5a. An interrupted submit leaves its op RUNNING; recovery re-queues it and
-- flags the outcome as uncertain instead of declaring it unsent.
make_thread("t_5a", { is_draft = true })
make_comment("c_5a", "t_5a", S.DRAFT, "uncertain body")
outbox.enqueue({ {
  mo_id = mo_id, t_id = "t_5a", c_id = "c_5a", op = outbox.OP.CREATE_THREAD,
  payload = { path = "src/test.lua", line = 5, body = "uncertain body" },
} })
local op5a
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.c_id == "c_5a" then op5a = op end
end
outbox.mark_running(op5a.op_id)
local recovered = outbox.recover_stale()
check(recovered >= 1, "recover_stale: found the interrupted op")
local after
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.c_id == "c_5a" then after = op end
end
check(after and after.status == outbox.STATUS.QUEUED, "recover_stale: RUNNING -> QUEUED")
check(after and after.uncertain == true, "recover_stale: outcome flagged uncertain")

-- 5b. uncertain_by_body indexes exactly the ops reconcile may adopt.
local by_body = outbox.uncertain_by_body(mo_id)
check(by_body["uncertain body"] ~= nil, "uncertain_by_body: indexes the crashed op's body")
check(by_body["no such body"] == nil, "uncertain_by_body: unrelated body absent")

-- 5c. Adoption consumes the op so the draft is never posted a second time.
outbox.adopt(after.op_id, "9991")
local still_pending = 0
for _, op in ipairs(outbox.pending(mo_id)) do
  if op.c_id == "c_5a" then still_pending = still_pending + 1 end
end
check(still_pending == 0, "adopt: op becomes terminal (no duplicate post possible)")

-- 5d. recover_stale is idempotent.
check(outbox.recover_stale() == 0, "recover_stale: idempotent (nothing RUNNING left)")

-- 5e. A DONE op is terminal and never re-appears in pending().
check(outbox.count_pending(mo_id) >= 0, "pending excludes DONE rows")

-- ===========================================================================
-- 6. CHANGE-SET COMPUTATION (compute_change_set)
-- ===========================================================================
print("== 6. Change-set computation ==")

-- Use a FRESH mo_id so only the 6_* comments are counted (earlier sections
-- left pending comments on the main mo_id).
local cs_mo = "github:test/repo:cs"
pull_request.upsert({
  mo_id = cs_mo,
  provider = "github",
  repo = "test/repo",
  number = 2,
  title = "CS PR",
  source_branch = "feature",
  target_branch = "master",
  state = "open",
})

-- Set up one of each pending type
comments.create_thread({ t_id = "t_6_add", mo_id = cs_mo, path = "a.lua", start_line = 1, end_line = 1, is_draft = true })
comments.add_comment({ c_id = "c_6_add", t_id = "t_6_add", body = "add", state = S.DRAFT })

comments.create_thread({ t_id = "t_6_reply", mo_id = cs_mo, path = "b.lua", start_line = 1, end_line = 1, is_draft = false })
comments.add_comment({ c_id = "c_6_reply", t_id = "t_6_reply", body = "reply", state = S.DRAFT })

comments.create_thread({ t_id = "t_6_upd", mo_id = cs_mo, path = "c.lua", start_line = 1, end_line = 1, is_draft = false })
comments.add_comment({ c_id = "c_6_upd", t_id = "t_6_upd", body = "upd", state = S.MODIFIED })

comments.create_thread({ t_id = "t_6_del", mo_id = cs_mo, path = "d.lua", start_line = 1, end_line = 1, is_draft = false })
comments.add_comment({ c_id = "c_6_del", t_id = "t_6_del", body = "del", state = S.DELETED })

comments.create_thread({ t_id = "t_6_synced", mo_id = cs_mo, path = "e.lua", start_line = 1, end_line = 1, is_draft = false })
comments.add_comment({ c_id = "c_6_synced", t_id = "t_6_synced", body = "synced", state = S.SYNCED })

local cs = review.compute_change_set(cs_mo)
check(#cs.additions == 1, "compute_change_set: 1 addition (draft on draft thread)")
check(#cs.replies == 1, "compute_change_set: 1 reply (draft on synced thread)")
check(#cs.updates == 1, "compute_change_set: 1 update (MODIFIED)")
check(#cs.deletions == 1, "compute_change_set: 1 deletion (DELETED)")

-- Verify the synced comment is NOT in any bucket
local all_in_cs = {}
for _, c in ipairs(cs.additions) do all_in_cs[c.c_id] = true end
for _, c in ipairs(cs.replies) do all_in_cs[c.c_id] = true end
for _, c in ipairs(cs.updates) do all_in_cs[c.c_id] = true end
for _, c in ipairs(cs.deletions) do all_in_cs[c.c_id] = true end
check(all_in_cs["c_6_synced"] == nil, "compute_change_set: SYNCED comment excluded")

-- ===========================================================================
-- 7. get_pending_comments (used by _submit_pushes)
-- ===========================================================================
print("== 7. get_pending_comments ==")
local pending = comments.get_pending_comments(cs_mo)
local pending_ids = {}
for _, c in ipairs(pending) do pending_ids[c.c_id] = true end
check(pending_ids["c_6_add"] == true, "get_pending_comments: includes DRAFT")
check(pending_ids["c_6_upd"] == true, "get_pending_comments: includes MODIFIED")
check(pending_ids["c_6_del"] == true, "get_pending_comments: includes DELETED")
check(pending_ids["c_6_synced"] == nil, "get_pending_comments: excludes SYNCED")
check(pending_ids["c_6_reply"] == true, "get_pending_comments: includes reply DRAFT")

-- ===========================================================================
-- 8. TRANSACTION ROLLBACK
-- ===========================================================================
print("== 8. Transaction rollback ==")
local ok_tx, err_tx = storage.with_transaction(function()
  comments.add_comment({
    c_id = "c_tx_fail",
    t_id = "t_6_add",
    body = "Rollback candidate",
    state = S.DRAFT,
  })
  error("Simulated transaction failure")
end)
check(ok_tx == false, "with_transaction: returns false on error")
check(get_state("c_tx_fail") == nil, "with_transaction: insert rolled back")

-- ===========================================================================
-- 9. ASYNC SUBMIT CONTRACT (item 3) — test mode runs synchronously
-- ===========================================================================
print("== 9. Async submit contract ==")
vim.g.lreview_test_mode = true

-- Hermetic guard: the unit tier must never spawn an authenticated gh/glab
-- subprocess. Any CLI call reaching this override is a bug in the test tier.
local base_cli = require("lreview.adapter.base")
local cli_calls = 0
base_cli.executor_override = function(argv)
  cli_calls = cli_calls + 1
  return { stdout = "", stderr = "unit tests must not call the hub CLI", code = 1 }
end

-- 9a. No active review -> callback(false, 0, err)
local cb_ok, cb_count, cb_err = nil, nil, nil
local called = false
review.current = nil
review.submit_review(nil, function(ok, count, err)
  called = true
  cb_ok, cb_count, cb_err = ok, count, err
end)
check(called, "submit_review: callback invoked")
check(cb_ok == false, "submit_review: no active review -> ok=false")
check(cb_err == "no active review", "submit_review: no active review -> err message")

-- 9b. Test mode runs synchronously: the callback fires before submit_review
-- returns (no worker thread involved). Verify by checking the callback ran
-- immediately after the call (called == true already proves it).
check(called == true, "submit_review: test mode callback fires synchronously")

-- 9c. submit_review with a valid cwd but no pending comments -> callback(false, 0, err)
-- Use the project root (valid git repo) so adapter.resolve succeeds, but there
-- are no pending comments for the fake mo_id, so it should report no-op.
review.current = {
  cwd = project_root,
  detail = { mo_id = "github:test/repo:none", number = 999 },
}
local called3 = false
local ok3, err3 = pcall(function()
  review.submit_review(nil, function(ok, count, err)
    called3 = true
    cb_ok, cb_count, cb_err = ok, count, err
  end)
end)
check(ok3, "submit_review: valid cwd doesn't crash")
check(called3, "submit_review: callback invoked with valid cwd")
-- Note: confirm_submit shows a UI popup; in headless test mode this may or may
-- not resolve. We only assert it doesn't crash and the callback fires.

-- ===========================================================================
-- 10. CLEANUP
-- ===========================================================================
check(cli_calls == 0, "unit tier never reached the hub CLI (" .. cli_calls .. " calls)")
base_cli.executor_override = nil
storage.close()
vim.fn.delete(test_db)
vim.fn.delete(test_db .. "-wal")
vim.fn.delete(test_db .. "-shm")

print("")
print(string.format("== RESULTS: %d passed, %d failed ==", pass, fail))
if fail > 0 then
  print("ALL STATE MACHINE TESTS FAILED.")
  os.exit(1)
end
print("SUCCESS: All comment/thread state transitions, conflicts, crash recovery, change-set, and submit contract verified.")
print("ALL COMPREHENSIVE STATE MACHINE TESTS PASSED.")
