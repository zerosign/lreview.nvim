-- Submit-path contract tests: the CLI we send, and what the outbox does when a
-- push fails half-way.
--
-- Why this file exists: every bug class below was invisible to the existing
-- suite because it runs with vim.g.lreview_test_mode = true, which bypasses the
-- confirmation UI and never asserts the argv handed to gh/glab. Here the CLI
-- layer is intercepted (adapter.base.executor_override), so:
--   * nothing spawns a subprocess and no credentials are touched;
--   * endpoint/argument drift fails loudly (that is how update_comment was
--     being called with the comment BODY as its id);
--   * partial failures can be scripted, so "did it strand a draft?" is testable.
--
-- It must stay offline: `just test` runs it, `just test-integration` does not.

local config_dir = vim.fn.stdpath("config")
local project_root = vim.fn.fnamemodify(config_dir, ":h:h")
package.path = package.path .. ";" .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?.lua;"
    .. project_root .. "/data/nvim/lazy/sqlite.lua/lua/?/init.lua"

local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local comments = require("lreview.storage.comments")
local outbox = require("lreview.storage.outbox")
local review = require("lreview.review")
local base = require("lreview.adapter.base")
local adapter = require("lreview.adapter")
local github = require("lreview.adapter.github")
local gitlab = require("lreview.adapter.gitlab")
local init = require("lreview")

print("TEST: Starting Submit Contract Tests...")

local test_db = "tmp/test_submit_contract.db"
vim.fn.delete(test_db)
vim.fn.delete(test_db .. "-wal")
vim.fn.delete(test_db .. "-shm")

init.setup({ defaults = { db_path = test_db } })
assert(storage.open())

local pass, fail = 0, 0
local function check(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print("  FAIL: " .. msg)
  end
end

-- ---------------------------------------------------------------------------
-- CLI intercept
-- ---------------------------------------------------------------------------
local recorded = {}      -- every argv we were asked to run
local fail_at = {}       -- [n] = true -> the n-th call reports a hub error
local reply_seq = 900    -- synthetic remote comment ids

local function arm_intercept()
  recorded, fail_at = {}, {}
  base.executor_override = function(argv, _cwd)
    local n = #recorded + 1
    recorded[n] = argv
    if fail_at[n] then
      return { stdout = "", stderr = "glab: 404 Not Found", code = 0 }
    end
    local joined = table.concat(argv, " ")
    -- A reply/edit POST returns the new note id; everything else can be empty.
    if joined:find("comments") and joined:find("POST") then
      reply_seq = reply_seq + 1
      return { stdout = string.format('{"databaseId": %d, "id": %d}', reply_seq, reply_seq),
               stderr = "", code = 0 }
    end
    if joined:find("notes") and joined:find("POST") then
      reply_seq = reply_seq + 1
      return { stdout = string.format('{"id": %d}', reply_seq), stderr = "", code = 0 }
    end
    return { stdout = "{}", stderr = "", code = 0 }
  end
end

local function argv_at(n) return recorded[n] and table.concat(recorded[n], " ") or "" end
local function joined_all()
  local out = {}
  for _, a in ipairs(recorded) do out[#out + 1] = table.concat(a, " ") end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
local GH_MO = "github:acme/widgets:7"
local GL_MO = "gitlab:grp/things:8"

local function resolved_github()
  return {
    adapter = github, provider = "gh", host = "github.com", repo = "acme/widgets",
    cfg = { provider = "gh" }, cwd = project_root,
  }
end
local function resolved_gitlab()
  return {
    adapter = gitlab, provider = "glab", host = "gitlab.com", repo = "grp/things",
    cfg = { provider = "glab" }, cwd = project_root,
  }
end
local function ctx_for(resolved, number)
  return { adapter = resolved.adapter, provider = resolved.provider, host = resolved.host,
           repo = resolved.repo, cfg = resolved.cfg, cwd = resolved.cwd, number = number }
end
local function detail_for(mo_id, provider, repo, number)
  return { mo_id = mo_id, provider = provider, repo = repo, number = number,
           title = "T", state = "open", source_branch = "feat", target_branch = "main",
           description = "Fixes #42" }
end

local function seed_pr(mo_id, provider, repo, number)
  pull_request.upsert({ mo_id = mo_id, provider = provider, repo = repo, number = number,
                        title = "T", state = "open", source_branch = "feat", target_branch = "main" })
end

local function seed_thread(t_id, mo, path, line, is_draft)
  comments.create_thread({ t_id = t_id, mo_id = mo, path = path,
                           start_line = line, end_line = line, is_draft = is_draft })
end

local function seed_comment(c_id, t_id, body, state, remote_id)
  comments.add_comment({ c_id = c_id, t_id = t_id, body = body, state = state,
                         remote_id = remote_id, author = "me" })
end

-- ===========================================================================
-- 1. GitHub: full change-set must hit the documented endpoints
-- ===========================================================================
print("== 1. GitHub argv contract ==")
arm_intercept()
seed_pr(GH_MO, "github", "acme/widgets", 7)
seed_thread("gh_t_new", GH_MO, "src/a.lua", 12, true)
seed_comment("gh_c_new", "gh_t_new", "brand new note", comments.STATE.DRAFT)

seed_thread("gh_t_sync", GH_MO, "src/b.lua", 20, false)
seed_comment("gh_c_parent", "gh_t_sync", "remote parent", comments.STATE.SYNCED, "501")
seed_comment("gh_c_reply", "gh_t_sync", "my reply", comments.STATE.DRAFT)
seed_comment("gh_c_edit", "gh_t_sync", "edited text", comments.STATE.MODIFIED, "502")
seed_comment("gh_c_del", "gh_t_sync", "to be deleted", comments.STATE.DELETED, "503")

local gh_resolved = resolved_github()
local pushed, err, remaining = review._submit_pushes(
  detail_for(GH_MO, "github", "acme/widgets", 7), gh_resolved, ctx_for(gh_resolved, 7), nil, "COMMENT")

check(err == nil, "github submit reported no error (got: " .. tostring(err) .. ")")
check(pushed == 4, "github pushed all four ops (got " .. tostring(pushed) .. ")")
check(remaining == 0, "github nothing left queued (got " .. tostring(remaining) .. ")")

local all = joined_all()
check(all:match("pulls/7/reviews") ~= nil, "new threads ride one POST /pulls/7/reviews")
check(all:find("comments[][path]=src/a.lua", 1, true) ~= nil, "batch carries the comment path")
check(all:find("comments[][line]=12", 1, true) ~= nil, "batch carries the comment line")
check(all:match("pulls/7/comments") ~= nil and all:match("in_reply_to=501") ~= nil,
  "reply posts to /pulls/7/comments with in_reply_to=<parent comment id>")
-- This is the assertion that catches the arity bug: the PATCH target must be the
-- remote comment id, and the body must actually be sent.
check(all:match("pulls/comments/502") ~= nil, "edit targets /pulls/comments/<remote id>")
check(all:match("body=edited text") ~= nil, "edit sends the new body")
check(all:match("DELETE") ~= nil and all:match("pulls/comments/503") ~= nil,
  "delete targets /pulls/comments/<remote id> with DELETE")
check(all:match("pulls/comments/501%s+%-X.-DELETE") == nil, "delete never reuses the parent id")
check(all:find("my reply", 1, true) ~= nil or all:find("comments[][body]=brand new note", 1, true) ~= nil,
  "comment bodies are transmitted")

-- Local state after success: drafts consumed, edit synced, delete gone.
check(comments.get_thread("gh_t_new") == nil, "created thread draft removed locally")
check(storage.query("SELECT c_id FROM comments WHERE c_id='gh_c_new'")[1] == nil, "created comment draft removed")
local edited = storage.query("SELECT state, remote_id FROM comments WHERE c_id='gh_c_edit'")[1]
check(edited and edited.state == comments.STATE.SYNCED, "edited comment now SYNCED")
check(storage.query("SELECT c_id FROM comments WHERE c_id='gh_c_del'")[1] == nil, "deleted comment removed locally")
check(outbox.count_pending(GH_MO) == 0, "outbox drained after a successful submit")
local done_rows = storage.query("SELECT COUNT(*) AS n FROM push_ops WHERE mo_id=? AND status='DONE'", GH_MO)[1]
check(done_rows and done_rows.n >= 4, "successful ops recorded as DONE (idempotency ledger)")

-- ===========================================================================
-- 2. Verdict must be delivered, not dropped
-- ===========================================================================
print("== 2. verdict handling ==")
arm_intercept()
seed_thread("gh_v_t", GH_MO, "src/v.lua", 5, false)
seed_comment("gh_v_parent", "gh_v_t", "parent", comments.STATE.SYNCED, "511")
seed_comment("gh_v_reply", "gh_v_t", "reply text", comments.STATE.DRAFT)

pushed, err = review._submit_pushes(
  detail_for(GH_MO, "github", "acme/widgets", 7), gh_resolved, ctx_for(gh_resolved, 7), nil, "APPROVE")
check(err == nil, "approve-with-only-reply submitted cleanly")
-- The verdict runs after the comment categories, so look in the whole batch.
check(joined_all():match("event=APPROVE") ~= nil, "verdict sent as its own review POST when no new threads")

-- With new threads on GitHub the event must ride the batch (one review, not two).
arm_intercept()
seed_thread("gh_v_t2", GH_MO, "src/v2.lua", 6, true)
seed_comment("gh_v_new2", "gh_v_t2", "inline note", comments.STATE.DRAFT)
review._submit_pushes(
  detail_for(GH_MO, "github", "acme/widgets", 7), gh_resolved, ctx_for(gh_resolved, 7), nil, "REQUEST_CHANGES")
local joined = joined_all()
check(joined:match("event=REQUEST_CHANGES") ~= nil, "batch review carries the verdict")
local event_calls = 0
for _, argv in ipairs(recorded) do
  if table.concat(argv, " "):match("event=") then event_calls = event_calls + 1 end
end
check(event_calls == 1, "verdict sent exactly once (got " .. event_calls .. " event calls)")

-- ===========================================================================
-- 3. Partial failure must not strand drafts (the v3 IN_FLIGHT bug)
-- ===========================================================================
print("== 3. partial failure leaves nothing stranded ==")
arm_intercept()
local PART_MO = "github:acme/widgets:9"
seed_pr(PART_MO, "github", "acme/widgets", 9)
seed_thread("p_t_sync", PART_MO, "src/p.lua", 3, false)
seed_comment("p_parent", "p_t_sync", "parent", comments.STATE.SYNCED, "601")
seed_comment("p_r1", "p_t_sync", "reply one", comments.STATE.DRAFT)
seed_comment("p_r2", "p_t_sync", "reply two", comments.STATE.DRAFT)
seed_comment("p_r3", "p_t_sync", "reply three", comments.STATE.DRAFT)

fail_at = { [2] = true }   -- first reply lands, second fails, third must not be attempted
local det = detail_for(PART_MO, "github", "acme/widgets", 9)
pushed, err, remaining = review._submit_pushes(det, gh_resolved, ctx_for(gh_resolved, 9), nil, "COMMENT")
check(pushed == 1, "one reply committed before the failure (got " .. tostring(pushed) .. ")")
check(err ~= nil, "failure is reported, not swallowed")
check(remaining == 2, "unattempted replies stay QUEUED (got " .. tostring(remaining) .. ")")
check(#recorded == 2, "stopped the category after the failure (no futile calls)")

-- The whole point: the untouched drafts are still pushable by state alone.
for _, cid in ipairs({ "p_r2", "p_r3" }) do
  local row = storage.query("SELECT state FROM comments WHERE c_id = ?", cid)[1]
  check(row and comments.needs_push(row.state), cid .. " still needs_push after a partial submit")
end
local stranded = storage.query("SELECT COUNT(*) AS n FROM push_ops WHERE mo_id=? AND status='RUNNING'", PART_MO)[1]
check(stranded and stranded.n == 0, "no op left RUNNING after a partial submit")

-- Retry: only the two unpushed replies are sent this time.
arm_intercept()
pushed, err, remaining = review._submit_pushes(det, gh_resolved, ctx_for(gh_resolved, 9), nil, "COMMENT")
check(pushed == 2, "retry pushes exactly the remaining two (got " .. tostring(pushed) .. ")")
check(remaining == 0, "retry drained the outbox")
check(outbox.count_pending(PART_MO) == 0, "outbox empty after successful retry")

-- ===========================================================================
-- 4. GitLab is per-note: a mid-loop failure must not re-post what landed
-- ===========================================================================
print("== 4. GitLab non-atomic notes ==")
arm_intercept()
local GL = detail_for(GL_MO, "gitlab", "grp/things", 8)
local gl_resolved = resolved_gitlab()
seed_pr(GL_MO, "gitlab", "grp/things", 8)
seed_thread("gl_t1", GL_MO, "src/x.lua", 1, true)
seed_comment("gl_c1", "gl_t1", "note one", comments.STATE.DRAFT)
seed_thread("gl_t2", GL_MO, "src/x.lua", 2, true)
seed_comment("gl_c2", "gl_t2", "note two", comments.STATE.DRAFT)
seed_thread("gl_t3", GL_MO, "src/x.lua", 3, true)
seed_comment("gl_c3", "gl_t3", "note three", comments.STATE.DRAFT)

fail_at = { [2] = true }
pushed, err, remaining = review._submit_pushes(GL, gl_resolved, ctx_for(gl_resolved, 8), nil, "COMMENT")
check(pushed == 1, "gitlab committed note one before the failure (got " .. tostring(pushed) .. ")")
check(remaining == 2, "gitlab left notes two and three QUEUED (got " .. tostring(remaining) .. ")")
check(storage.query("SELECT c_id FROM comments WHERE c_id='gl_c1'")[1] == nil,
  "landed gitlab note consumed locally (cannot be re-posted)")
check(argv_at(1):match("mr note create") ~= nil and argv_at(1):match("%-%-file") ~= nil,
  "gitlab creates one note per call with --file/--line")

-- Retry must send ONLY the two that never landed.
arm_intercept()
pushed, err, remaining = review._submit_pushes(GL, gl_resolved, ctx_for(gl_resolved, 8), nil, "COMMENT")
check(pushed == 2, "gitlab retry pushed the two remaining notes (got " .. tostring(pushed) .. ")")
check(#recorded == 2, "gitlab retry re-posted nothing that already landed")

-- GitLab cannot carry the verdict inside a note: it must be its own call.
arm_intercept()
seed_thread("gl_v_t", GL_MO, "src/x.lua", 9, true)
seed_comment("gl_v_c", "gl_v_t", "verdict note", comments.STATE.DRAFT)
review._submit_pushes(GL, gl_resolved, ctx_for(gl_resolved, 8), nil, "APPROVE")
local gljoined = joined_all()
check(gljoined:match("mr approve") ~= nil, "gitlab APPROVE issued as its own command")

-- And an unsupported verdict must be reported, not silently dropped.
arm_intercept()
seed_thread("gl_rc_t", GL_MO, "src/x.lua", 11, true)
seed_comment("gl_rc_c", "gl_rc_t", "rc note", comments.STATE.DRAFT)
pushed, err = review._submit_pushes(GL, gl_resolved, ctx_for(gl_resolved, 8), nil, "REQUEST_CHANGES")
check(pushed == 1, "gitlab note still pushed when the verdict is unsupported (got " .. tostring(pushed) .. ")")
check(err ~= nil, "unsupported verdict reports an error instead of a silent no-op")
check(outbox.count_failed(GL_MO) >= 1, "unsupported gitlab verdict recorded as FAILED")
local failed_op = storage.query(
  "SELECT error FROM push_ops WHERE mo_id=? AND status='FAILED' AND op='verdict' ORDER BY created_at DESC LIMIT 1",
  GL_MO)[1]
check(failed_op and failed_op.error:match("request.-changes") ~= nil,
  "failed verdict op carries the reason")

-- ===========================================================================
-- 5. Crash recovery + reconcile adoption
-- ===========================================================================
print("== 5. crash recovery adoption ==")
arm_intercept()
local CR_MO = "github:acme/widgets:11"
seed_pr(CR_MO, "github", "acme/widgets", 11)
seed_thread("cr_t", CR_MO, "src/c.lua", 4, true)
seed_comment("cr_c", "cr_t", "posted but crashed", comments.STATE.DRAFT)
local cr_detail = detail_for(CR_MO, "github", "acme/widgets", 11)

-- Queue the op, take the lock, then "die" before the local write. This is the
-- exact state a killed submit leaves behind.
outbox.enqueue(review.build_ops(cr_detail, gh_resolved, nil, "COMMENT"))
local queued_cr = outbox.pending(CR_MO)
check(#queued_cr == 1, "one op queued for the crash scenario")
outbox.mark_running(queued_cr[1].op_id)
local running_op_id = queued_cr[1].op_id
check(outbox.recover_stale() >= 1, "recover_stale re-queues interrupted ops")
local revived = storage.query("SELECT status, uncertain FROM push_ops WHERE op_id = ?", running_op_id)[1]
check(revived and revived.status == outbox.STATUS.QUEUED, "interrupted op is QUEUED again")
check(revived and revived.uncertain == 1, "interrupted op flagged uncertain")

-- The remote already has the comment: reconcile must adopt, not duplicate.
review._reconcile_threads(cr_detail, { {
  t_id = "remote-disc-1", path = "src/c.lua", start_line = 4, end_line = 4, resolved = 0,
  comments = { { c_id = "7701", remote_id = "7701", author = "me", body = "posted but crashed" } },
} })
local adopted = storage.query("SELECT status, remote_id FROM push_ops WHERE op_id=?", running_op_id)[1]
check(adopted and adopted.status == outbox.STATUS.DONE, "reconcile adopted the crashed op as DONE")
check(adopted and adopted.remote_id == "7701", "adopted op recorded the remote id")
check(storage.query("SELECT c_id FROM comments WHERE c_id='cr_c'")[1] == nil,
  "local draft consumed by adoption (no double post on next submit)")
check(outbox.count_pending(CR_MO) == 0, "nothing left pending after adoption")

-- An uncertain op whose body the remote does NOT have stays queued.
local uncertain = outbox.uncertain_by_body(CR_MO)
check(next(uncertain) == nil, "uncertain index empty once adopted")

-- ===========================================================================
-- 6. Conflicts gate submit, and the gate has an exit
-- ===========================================================================
print("== 6. conflict gate ==")
arm_intercept()
local CF_MO = "github:acme/widgets:13"
seed_pr(CF_MO, "github", "acme/widgets", 13)
seed_thread("cf_t", CF_MO, "src/f.lua", 7, false)
seed_comment("cf_c", "cf_t", "my local edit", comments.STATE.MODIFIED, "801")
comments.mark_comment_conflict("cf_c", "someone else edit", "remote_edited")

pushed, err = review._submit_pushes(
  detail_for(CF_MO, "github", "acme/widgets", 13), gh_resolved, ctx_for(gh_resolved, 13), nil, "COMMENT")
check(pushed == 0, "conflicting comment blocks the push")
check(err:match("LocalReviewConflicts") ~= nil, "error names the command that clears it")
check(#recorded == 0, "no network call attempted while a conflict is open")

-- The command the message promises must actually exist. (exists(":Cmd") returns
-- 2 for user-defined commands, not 1.)
check(vim.fn.exists(":LocalReviewConflicts") == 2, ":LocalReviewConflicts is registered")
check(vim.fn.exists(":LocalReviewIssues") == 2, ":LocalReviewIssues is registered")
check(vim.fn.exists(":LocalReviewIssue") == 2, ":LocalReviewIssue is registered")
check(vim.fn.exists(":LocalReviewIssuePull") == 2, ":LocalReviewIssuePull is registered")

comments.resolve_conflict_keep_local("cf_c")
arm_intercept()
pushed, err = review._submit_pushes(
  detail_for(CF_MO, "github", "acme/widgets", 13), gh_resolved, ctx_for(gh_resolved, 13), nil, "COMMENT")
check(err == nil and pushed == 1, "resolving the conflict unblocks the push (got " .. tostring(pushed) .. ")")

-- ===========================================================================
-- 7. Local-only deletes never hit the API
-- ===========================================================================
print("== 7. local-only delete ==")
arm_intercept()
local LO_MO = "github:acme/widgets:15"
seed_pr(LO_MO, "github", "acme/widgets", 15)
seed_thread("lo_t", LO_MO, "src/l.lua", 2, true)
seed_comment("lo_c", "lo_t", "never pushed", comments.STATE.DELETED)
pushed, err = review._submit_pushes(
  detail_for(LO_MO, "github", "acme/widgets", 15), gh_resolved, ctx_for(gh_resolved, 15), nil, "COMMENT")
check(err == nil, "local-only delete submits cleanly")
check(#recorded == 0, "no API call for a comment that never existed remotely")
check(storage.query("SELECT c_id FROM comments WHERE c_id='lo_c'")[1] == nil,
  "local-only delete consumed the draft row")

-- ===========================================================================
-- 8. A thread with no pushed parent is reported, not crashed on
-- ===========================================================================
print("== 8. reply parent resolution ==")
arm_intercept()
local RP_MO = "github:acme/widgets:17"
seed_pr(RP_MO, "github", "acme/widgets", 17)
seed_thread("rp_t", RP_MO, "src/r.lua", 8, false)
seed_comment("rp_draft", "rp_t", "unpushed first comment", comments.STATE.DRAFT)
seed_comment("rp_reply", "rp_t", "reply needing a parent", comments.STATE.DRAFT)
local parent, perr = review.reply_parent(gh_resolved, "rp_t")
check(parent == nil, "no pushed parent found in a thread of drafts only")
check(perr ~= nil, "reason reported instead of nil concat crash")
pushed, err = review._submit_pushes(
  detail_for(RP_MO, "github", "acme/widgets", 17), gh_resolved, ctx_for(gh_resolved, 17), nil, "COMMENT")
check(err ~= nil, "submit reports the unthreadable reply")
check(err:match("no pushed comment") ~= nil, "message explains why")

-- ===========================================================================
-- 9. Credential/argv masking
-- ===========================================================================
print("== 9. argv redaction ==")
local secret = { "gh", "api", "-H", "Authorization: token ghp_SUPERSECRETTTTTTTTTT",
                 "-f", "body=" .. string.rep("x", 200) }
local red = table.concat(base.redact_argv(secret), " ")
check(red:match("ghp_SUPERSECRETTTTTTTTTT") == nil, "token value never appears in a log label")
check(red:match("<redacted>") ~= nil, "authorization value is masked")
check(#red < 160, "long bodies are truncated in labels (len " .. #red .. ")")

local hidden = { "glab", "api", "--token", "glpatABCDEF0123456789" }
local red2 = table.concat(base.redact_argv(hidden), " ")
check(red2:match("glpatABCDEF0123456789") == nil, "value after --token is masked")

-- ===========================================================================
-- 10. Index usage on the hot paths (EXPLAIN QUERY PLAN)
-- ===========================================================================
print("== 10. index usage ==")
local function plan_uses_index(sql, label, expect)
  local rows = storage.query("EXPLAIN QUERY PLAN " .. sql, unpack(expect))
  local text = ""
  for _, r in ipairs(rows) do text = text .. " " .. tostring(r.detail or "") end
  check(text:match("USING INDEX") or text:match("USING COVERING INDEX") or text:match("SEARCH"),
    label .. ": plan is index-driven (plan:" .. text .. ")")
  return text
end

local p1 = plan_uses_index(
  "SELECT * FROM pull_requests WHERE provider=? AND repo=? AND source_branch=?",
  "by_source_branch", { "github", "acme/widgets", "feat" })
check(p1:match("idx_pr_branch") ~= nil, "by_source_branch uses idx_pr_branch")

local p2 = plan_uses_index("SELECT * FROM push_ops WHERE mo_id=? AND status!='DONE'",
  "outbox pending", { GH_MO })
check(p2:match("idx_push_ops_pending") ~= nil, "outbox pending scan uses idx_push_ops_pending")

local p3 = plan_uses_index("SELECT c.c_id FROM comments c JOIN threads t ON c.t_id=t.t_id WHERE t.mo_id=? AND t.path=?",
  "comments_for_buffer", { GH_MO, "src/a.lua" })
check(p3:match("idx_threads_buffer") ~= nil, "per-buffer refresh uses idx_threads_buffer")

local p4 = plan_uses_index("SELECT op_id FROM push_ops WHERE status='RUNNING'",
  "recover_stale", {})
check(p4:match("idx_push_ops_running") ~= nil, "crash recovery uses the partial RUNNING index")

local p5 = plan_uses_index("SELECT * FROM issues WHERE provider=? AND repo=? AND state=? ORDER BY number DESC",
  "issue list", { "github", "acme/widgets", "open" })
check(p5:match("idx_issues_repo") ~= nil, "issue list uses idx_issues_repo")

local p6 = plan_uses_index("SELECT note_id FROM issue_notes WHERE issue_id=? ORDER BY created_at",
  "issue notes", { "github:acme/widgets:42" })
check(p6:match("idx_issue_notes_issue") ~= nil, "issue notes use idx_issue_notes_issue")

-- Schema version actually landed, and the new tables exist.
local ver = storage.query("SELECT v FROM meta WHERE k='schema_version'")[1]
check(ver and tonumber(ver.v) == 4, "schema_version is 4 (got " .. tostring(ver and ver.v) .. ")")
for _, tbl in ipairs({ "push_ops", "issues", "issue_notes" }) do
  local exists = storage.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", tbl)[1]
  check(exists ~= nil, "table " .. tbl .. " exists")
end

-- by_source_branch resolves through SQL now (regression on the v3 Lua scan).
-- Several seeded PRs share the "feat" branch, so the contract is "the newest
-- number for this branch", which the DESC index serves without a sort pass.
local found = pull_request.by_source_branch("github", "acme/widgets", "feat")
check(found ~= nil, "by_source_branch resolves a row via indexed columns")
check(found and found.source_branch == "feat", "resolved row carries the requested branch")
check(found and found.number and found.number >= 17, "by_source_branch returns the newest match")
check(pull_request.by_source_branch("github", "acme/widgets", "no-such-branch") == nil,
  "by_source_branch returns nil for an unknown branch")

base.executor_override = nil
storage.close()
vim.fn.delete(test_db)
vim.fn.delete(test_db .. "-wal")
vim.fn.delete(test_db .. "-shm")

print("")
print(string.format("== RESULTS: %d passed, %d failed ==", pass, fail))
if fail > 0 then
  print("ALL SUBMIT CONTRACT TESTS FAILED.")
  os.exit(1)
end
print("SUCCESS: submit path endpoints, outbox atomicity, verdicts, recovery, conflicts, and indexes verified.")
print("ALL SUBMIT CONTRACT TESTS PASSED.")
