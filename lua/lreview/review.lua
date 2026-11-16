---@meta

-- Local-first review flow.
--
--   start_review()  -> resolve current MR by branch, open storage, cache detail
--   add_comment()   -> visual selection -> draft thread + comment INSERT
--   submit_review() -> push all draft inline comments to the platform (only
--                      inline comments; no platform review-state per user req)
--
-- "Submit" never changes platform review state (no approve/request-changes).
-- It only pushes the pending inline comments.

local config = require("lreview.config")
local thread = require("lreview.thread")
local git = require("lreview.git")
local model = require("lreview.model")
local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local comments = require("lreview.storage.comments")
local outbox = require("lreview.storage.outbox")

local M = {}

-- Current active review context (per-buffer state lives in the UI layer).
---@type table|nil
M.current = nil

-- ---------------------------------------------------------------------------
-- Notification accumulation (doc 12 §3.8 / doc 09 §2.6)
--
-- vim.notify is nil on worker threads, so any notify() fired inside a
-- thread-executed function (e.g. sync_review conflict warnings) would be
-- silently lost. Instead we accumulate into M._notifications and replay them
-- on the main thread via drain_notifications(). On the main thread (thread_mode
-- false) we drain immediately so synchronous callers behave as before.
-- ---------------------------------------------------------------------------
M._notifications = {}
local thread_mode = false

--- Emit a notification. On the main thread it fires immediately; on a worker
--- thread it is queued for replay by drain_notifications().
---@param msg string
---@param level integer|nil
local function notify(msg, level)
  M._notifications[#M._notifications + 1] = { msg = msg, level = level }
  if not thread_mode then
    M.drain_notifications()
  end
end

--- Replay any queued notifications via vim.notify and clear the queue.
function M.drain_notifications()
  local notifs = M._notifications
  M._notifications = {}
  for _, n in ipairs(notifs) do
    if vim.notify then
      vim.notify(n.msg, n.level)
    end
  end
end

--- Generate a local uuid (v4-ish) for draft ids.
---@return string
local function uuid()
  local t = {}
  for i = 1, 32 do
    local r = math.random(0, 15)
    t[i] = string.format("%x", r)
  end
  -- variant/version bits
  t[13] = "4"
  t[17] = string.format("%x", math.floor(math.random(8, 11)))

  -- Time-prefixed: an unseeded LuaJIT math.random replays the same order every
  -- start, and add_comment uses INSERT OR REPLACE, so a repeated id would
  -- silently overwrite an existing draft rather than fail loudly.
  local stamp = string.format("%08x", os.time() % 0x100000000)
  return stamp .. "-" .. table.concat(t, "", 2, 5)
      .. "-" .. table.concat(t, "", 6, 9) .. "-" .. table.concat(t, "", 10, 13)
      .. "-" .. table.concat(t, "", 14, 32)
end

--- Resolve the current MR for a directory (by branch, or current branch).
---@param cwd string|nil
---@return lreview.MRDetail|nil, string|nil
function M.resolve_current_mr(cwd)
  local resolved = adapter.resolve(cwd)
  if not resolved then
    return nil, "no git remote detected in this repo"
  end
  local branch = git.current_branch(cwd)
  local ctx = adapter.ctx(resolved, branch)
  local detail, err = resolved.adapter.get_mr_detail(resolved.cfg, ctx)
  if not detail then
    -- fall back to branch resolution
    local mr, err2 = resolved.adapter.get_mr_by_branch(resolved.cfg, ctx, branch)
    if not mr then
      return nil, err or err2
    end
    detail = mr
  end
  return detail, nil
end

--- Build a local (unlinked) fallback MR detail without any network call.
--- Used to render the UI immediately while the real MR resolves in the
--- background (async init_session). Fast: only git subprocesses + SQLite.
---@param cwd string
---@return lreview.MRDetail
local function local_fallback_detail_raw(cwd)
  local branch = git.current_branch(cwd) or "head"
  local resolved = adapter.resolve(cwd)
  local ctx = resolved and adapter.ctx(resolved, branch) or {}
  local def_branch = git.default_branch(cwd) or "main"
  return {
    mo_id = "local:" .. (ctx.repo or "workspace") .. ":" .. branch,
    provider = (resolved and resolved.cfg and resolved.cfg.adapter) or "local",
    repo = (ctx.owner and ctx.repo) and (ctx.owner .. "/" .. ctx.repo) or ctx.repo or "workspace",
    number = 0,
    title = "Local Draft Review (" .. branch .. ")",
    description = "No remote PR/MR currently linked.",
    state = "draft",
    unlinked = true,
    source_branch = branch,
    target_branch = def_branch,
    files = git.changed_files(cwd, def_branch) or {},
  }
end

local function local_fallback_detail(cwd)
  local timing = require("lreview.timing")
  if not timing.enabled() then
    return local_fallback_detail_raw(cwd)
  end
  local start = vim.uv.hrtime() / 1e6
  local detail = local_fallback_detail_raw(cwd)
  timing.record(timing.CAT_FLOW, "local_fallback_detail", (vim.uv.hrtime() / 1e6) - start)
  return detail
end

--- Start a review: resolve MR, open storage, cache the MR detail.
--- Synchronous (may block on the network call to resolve the MR). For a
--- non-blocking variant that renders immediately and resolves the MR in the
--- background, use init_session_async.
---@param cwd string|nil
---@return lreview.MRDetail|nil, string|nil
function M.init_session(cwd)
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p")
  if cwd:sub(-1) == "/" or cwd:sub(-1) == "\\" then
    cwd = cwd:sub(1, -2)
  end

  local detail, err = M.resolve_current_mr(cwd)
  if not detail then
    detail = local_fallback_detail(cwd)
  end
  local ok, oerr = storage.open()
  if not ok then
    return nil, oerr
  end

  -- Crash recovery: an op that was RUNNING when the process died has an unknown
  -- outcome. Re-queue it flagged `uncertain` so the next reconcile adopts the
  -- comment if it actually landed, instead of posting a duplicate (item 4).
  local recovered = outbox.recover_stale()
  if recovered > 0 and vim.notify then
    vim.notify(string.format("lreview: %d interrupted push op(s) re-queued for verification", recovered), vim.log.levels.INFO)
  end

  pull_request.upsert(detail)
  M.current = {
    detail = detail,
    cwd = cwd,
  }

  -- Invalidate diff cache when starting a new session (branch may have changed). (item 5)
  local sync = require("lreview.sync")
  sync.invalidate_diff_cache(cwd)

  -- Auto-pull remote updates only in interactive sessions. The headless pull
  -- job sets vim.g.lreview_pull_job before calling init_session, which would
  -- otherwise spawn an unbounded chain of nested pull jobs (each job spawning
  -- another) and pile up orphaned nvim processes contending on the SQLite DB.
  if not vim.g.lreview_pull_job and not detail.unlinked then
    M.pull_review_async(cwd)
  end
  return detail, nil
end

--- Worker-thread entry point: resolve the current MR (network call) off the
--- main thread. Runs inside uv.new_work via thread.create_worker, so it must
--- be self-contained (no closures) and use io.popen fallbacks for git/CLI.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd = string }
---@return table  -- { ok, detail?, err?, cwd }
function M.resolve_mr_thread(db_path, lazy_sqlite, args)
  local cwd = args and args.cwd
  if not cwd then
    return { ok = false, err = "no cwd provided" }
  end
  local ok, detail, err = pcall(M.resolve_current_mr, cwd)
  if not ok then
    -- `cwd` is echoed so the completion (a closure created once, ever) can tell
    -- which session this result belongs to instead of trusting a captured value.
    return { ok = false, err = tostring(detail), cwd = cwd }
  end
  if not detail then
    return { ok = false, err = err, cwd = cwd }
  end
  return { ok = true, detail = detail, cwd = cwd }
end

local init_worker = nil
-- Set per call, read by the singleton completion closure.
local resolve_started = nil

--- Non-blocking variant of init_session. Sets M.current with a local fallback
--- detail immediately (no network), then resolves the real MR on a worker
--- thread and upgrades M.current.detail when it arrives. The network call never
--- blocks the UI. Used by the summary panel and other instant-UI entry points.
---@param cwd string|nil
---@param callback fun(detail: lreview.MRDetail|nil, err: string|nil)|nil  -- called when the real MR resolves
---@return lreview.MRDetail  -- local fallback detail (immediate, non-blocking)
function M.init_session_async(cwd, callback)
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p")
  if cwd:sub(-1) == "/" or cwd:sub(-1) == "\\" then
    cwd = cwd:sub(1, -2)
  end

  local ok, oerr = storage.open()
  if not ok then
    if callback then callback(nil, oerr) end
    return nil, oerr
  end

  -- Crash recovery: an op that was RUNNING when the process died has an unknown
  -- outcome. Re-queue it flagged `uncertain` so the next reconcile adopts the
  -- comment if it actually landed, instead of posting a duplicate (item 4).
  local recovered = outbox.recover_stale()
  if recovered > 0 and vim.notify then
    vim.notify(string.format("lreview: %d interrupted push op(s) re-queued for verification", recovered), vim.log.levels.INFO)
  end

  -- Set M.current with a local fallback immediately so the UI never blocks.
  local fallback = local_fallback_detail(cwd)
  pull_request.upsert(fallback)
  M.current = {
    detail = fallback,
    cwd = cwd,
  }

  -- Invalidate diff cache when starting a new session (branch may have changed). (item 5)
  local sync = require("lreview.sync")
  sync.invalidate_diff_cache(cwd)

  -- Resolve the real MR on a worker thread (network off the main thread).
  local timing = require("lreview.timing")
  if not init_worker then
    init_worker = thread.create_worker("lreview.review", "resolve_mr_thread", function(res)
      local detail = res and res.ok and res.detail
      if timing.enabled() and resolve_started then
        timing.record(timing.CAT_FLOW, "resolve_mr_roundtrip", (vim.uv.hrtime() / 1e6) - resolve_started)
        resolve_started = nil
      end
      local cb_cwd = res and res.cwd
      if detail and M.current and M.current.cwd == cb_cwd then
        -- Upgrade the session to the real (linked) MR detail.
        pull_request.upsert(detail)
        M.current.detail = detail
        -- Auto-pull remote updates only in interactive sessions. The headless
        -- pull job sets vim.g.lreview_pull_job before calling init_session,
        -- which would otherwise spawn an unbounded chain of nested pull jobs.
        if not vim.g.lreview_pull_job and not detail.unlinked then
          M.pull_review_async(nil)
        end
        -- Refresh any open UI (decor) now that the real MR is known.
        local sync2 = require("lreview.sync")
        sync2.invalidate_diff_cache(cb_cwd)
        for bufnr, _ in pairs(require("lreview.ui.decor").enabled_buffers) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            sync2.mark_dirty(bufnr)
          end
        end
        sync2.schedule()
      end
      -- Per-call callback comes out of the slot queue: this closure is created
      -- once, so capturing `callback` would replay the FIRST session's callback.
      thread.dispatch_cb("review.init", detail, (not detail) and (res and res.err) or nil)
    end)
  end

  if timing.enabled() then
    resolve_started = vim.uv.hrtime() / 1e6
  end
  thread.arm("review.init", callback)
  init_worker:queue({ cwd = cwd })
  return fallback, nil
end

--- Add a draft comment on a line range of a file in the current review.
---@param path string
---@param start_line integer
---@param end_line integer|nil
---@param body string
---@return lreview.Thread|nil, string|nil
function M.add_comment(path, start_line, end_line, body)
  if not M.current then
    return nil, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local t_id = uuid()
  local thread = {
    t_id = t_id,
    mo_id = detail.mo_id,
    path = path,
    commit_sha = detail.head_sha,
    start_line = start_line,
    end_line = end_line or start_line,
    is_draft = true,
    last_synced_at = nil,
    comments = {},
  }
  comments.create_thread(thread)
  local c = {
    c_id = uuid(),
    t_id = t_id,
    remote_id = nil,
    author = nil, -- filled at submit time from CLI identity
    body = body,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    in_reply_to = nil,
  }
  comments.add_comment(c)
  thread.comments[1] = c
  return thread, nil
end

--- Create and submit a new comment thread immediately to the remote forge.
---@param path string
---@param start_line integer
---@param end_line integer
---@param body string
---@return boolean, string|nil
function M.push_thread_immediately(path, start_line, end_line, body)
  if not M.current then
    return false, "no active review"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return false, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)
  local batch = {
    { path = path, line = start_line, body = body }
  }
  local ok, err = resolved.adapter.submit_inline_review(resolved.cfg, ctx, detail.number, batch)
  if not ok then
    return false, err
  end
  M.sync_review()
  return true, nil
end

--- Submit a reply comment immediately to the remote forge.
---@param thread_id string
---@param body string
---@return string|nil, string|nil  -- remote_comment_id, error
function M.push_reply_immediately(thread_id, body)
  if not M.current then
    return nil, "no active review"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return nil, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)

  local reply_to_id = thread_id
  if resolved.provider == "gh" or resolved.provider == "github" then
    local cs = comments.comments_for_thread(thread_id)
    if #cs > 0 then
      reply_to_id = cs[1].remote_id
    end
  end

  local comment_id, err = resolved.adapter.submit_reply(resolved.cfg, ctx, detail.number, reply_to_id, body)
  if comment_id then
    M.sync_review()
  end
  return comment_id, err
end

--- Update/edit a comment immediately on the remote forge.
---@param c_id string
---@param body string
---@return boolean, string|nil
function M.push_edit_immediately(c_id, body)
  if not M.current then
    return false, "no active review"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return false, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)

  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if not c then
    return false, "comment not found"
  end
  local thread_id = c.t_id

  if c.remote_id then
    local ok, err = resolved.adapter.update_comment(resolved.cfg, ctx, detail.number, thread_id, c.remote_id, body)
    if not ok then
      return false, err
    end
    M.sync_review()
  end
  return true, nil
end

--- Compute explicit change-set of pending local modifications for an MR.
---@param mo_id string
---@return table
function M.compute_change_set(mo_id)
  local pending = comments.get_pending_comments(mo_id)
  local cs = {
    additions = {},
    replies = {},
    updates = {},
    deletions = {},
  }
  for _, d in ipairs(pending or {}) do
    if d.state == comments.STATE.DELETED then
      cs.deletions[#cs.deletions + 1] = d
    elseif d.state == comments.STATE.MODIFIED then
      cs.updates[#cs.updates + 1] = d
    elseif comments.thread_is_draft(d.thread_state) then
      cs.additions[#cs.additions + 1] = d
    else
      cs.replies[#cs.replies + 1] = d
    end
  end
  return cs
end

--- Resolve the comment a reply should be threaded under.
---
--- GitHub replies need a *comment* id; GitLab needs the discussion id. A synced
--- thread whose only remote comment is pending-delete (or whose first comment is
--- itself an unpushed draft) has no valid parent, so this returns nil and the
--- caller reports it — instead of concatenating nil into a CLI argument, which
--- is what v3 did.
---@param resolved table
---@param t_id string
---@return string|nil parent, string|nil err
function M.reply_parent(resolved, t_id)
  local cs = comments.comments_for_thread(t_id)
  if resolved.provider == "gh" or resolved.provider == "github" then
    for _, c in ipairs(cs) do
      if c.remote_id and c.remote_id ~= "" and not comments.is_deleted(c.state) then
        return c.remote_id, nil
      end
    end
    return nil, "thread has no pushed comment to reply to"
  end
  if #cs == 0 then
    return nil, "unknown thread"
  end
  -- GitLab threads replies by discussion id, which is our t_id.
  return t_id, nil
end

--- Translate pending comment states into push ops. Pure: reads storage only.
---
--- Ops are keyed by (c_id, op), so re-running submit never queues the same
--- mutation twice. The verdict becomes its own op whenever it cannot ride along
--- with a comment batch — exactly the case (approve/request-changes with only
--- replies or edits) where v3 dropped it silently.
---@param detail lreview.MRDetail
---@param resolved table
---@param thread_id string|nil
---@param verdict string|nil
---@return table[] ops, string[] skipped
function M.build_ops(detail, resolved, thread_id, verdict)
  local cs = M.compute_change_set(detail.mo_id)
  local ops, skipped = {}, {}
  local function keep(item)
    return not thread_id or item.t_id == thread_id
  end

  local has_new = false
  for _, d in ipairs(cs.additions) do
    if keep(d) then
      has_new = true
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id,
        op = outbox.OP.CREATE_THREAD,
        payload = { path = d.path, line = d.start_line, end_line = d.end_line, body = d.body },
      }
    end
  end

  for _, d in ipairs(cs.replies) do
    if keep(d) then
      local parent, perr = M.reply_parent(resolved, d.t_id)
      if parent then
        ops[#ops + 1] = {
          mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id, op = outbox.OP.REPLY,
          payload = { body = d.body, parent = parent },
        }
      else
        skipped[#skipped + 1] = string.format("%s:%d (%s)",
          d.path or "?", d.start_line or 0, perr or "unthreadable")
      end
    end
  end

  for _, d in ipairs(cs.updates) do
    if keep(d) then
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id, op = outbox.OP.EDIT,
        payload = { body = d.body, remote_id = d.remote_id },
      }
    end
  end

  for _, d in ipairs(cs.deletions) do
    if keep(d) then
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = d.t_id, c_id = d.c_id, op = outbox.OP.DELETE,
        payload = { remote_id = d.remote_id, body = d.body or "" },
      }
    end
  end

  if not thread_id and verdict and verdict ~= "COMMENT"
      and adapter.supports(resolved, "review_verdict") then
    local rides_along = has_new and adapter.supports(resolved, "atomic_inline_batch")
    if not rides_along then
      ops[#ops + 1] = {
        mo_id = detail.mo_id, t_id = "__mr__", c_id = "__mr__", op = outbox.OP.VERDICT,
        payload = { verdict = verdict, body = detail.description or "" },
      }
    end
  end

  return ops, skipped
end

--- Push the pending changes, driven by the outbox.
---
--- Replaces v3's "mark everything IN_FLIGHT, abort the batch on the first
--- error", which stranded the untouched items in a state PENDING_PUSH_MASK
--- excluded — i.e. drafts that were silently unpushable until a restart. Now:
---   * each op is committed the moment it succeeds (status DONE + the local
---     transition, in one transaction), so a later failure can never re-send a
---     note that already landed;
---   * a failure marks that op FAILED and stops its category, leaving the rest
---     QUEUED — they get retried, not resurrected from a lock;
---   * returns (pushed, err, remaining) so the caller can say "4 pushed, 2 left"
---     instead of pretending a per-note API was atomic.
---@param detail lreview.MRDetail
---@param resolved table
---@param ctx table
---@param thread_id string|nil  -- optional filter
---@param verdict string|nil
---@return integer pushed, string|nil err, integer remaining
function M._submit_pushes(detail, resolved, ctx, thread_id, verdict)
  -- Hubs expect an uppercase event, and callers outside the confirm UI (tests,
  -- scripts, custom adapters) may pass "approve"/"comment". Normalize once.
  if verdict then verdict = tostring(verdict):upper() end

  local conflict_count = comments.count_conflicts(detail.mo_id)
  if conflict_count > 0 then
    return 0, string.format(
      "%d conflict(s) must be resolved before pushing. Use :LocalReviewConflicts to review.",
      conflict_count), outbox.count_pending(detail.mo_id)
  end

  local ops, skipped = M.build_ops(detail, resolved, thread_id, verdict)
  outbox.enqueue(ops)

  local function take_pending()
    local all = outbox.pending(detail.mo_id)
    if not thread_id then return all end
    local out = {}
    for _, op in ipairs(all) do
      if op.t_id == thread_id then out[#out + 1] = op end
    end
    return out
  end

  if #take_pending() == 0 then
    if #skipped > 0 then
      return 0, "nothing pushable: " .. table.concat(skipped, "; "), 0
    end
    return 0, "no draft, edited, or deleted comments to submit", 0
  end

  local number = detail.number
  local pushed = 0
  local first_err = nil
  local function record(err)
    if err and not first_err then first_err = tostring(err) end
  end

  --- Commit a successful op together with its local state transition.
  local function commit(op, remote_id, local_fn)
    local ok_tx, tx_err = storage.with_transaction(function()
      outbox.mark_done(op.op_id, remote_id)
      if local_fn then local_fn(op) end
    end)
    if not ok_tx then
      -- The call landed but the bookkeeping did not. Keep the op non-terminal
      -- and flag it uncertain: reconcile adopts it by body match instead of the
      -- next submit posting a second copy.
      outbox.mark_uncertain(op.op_id, "pushed but not recorded locally: " .. tostring(tx_err))
      record("pushed a change that could not be recorded locally: " .. tostring(tx_err))
      return false
    end
    pushed = pushed + 1
    return true
  end

  local function group(kind)
    local out = {}
    for _, op in ipairs(take_pending()) do
      if op.op == kind then out[#out + 1] = op end
    end
    return out
  end

  local function consume_draft(op)
    comments.delete_comment(op.c_id)
    comments.delete_thread(op.t_id)
  end

  -- 1. New threads -----------------------------------------------------------
  local creates = group(outbox.OP.CREATE_THREAD)
  if #creates > 0 then
    local function to_batch(list)
      local batch = {}
      for _, op in ipairs(list) do
        batch[#batch + 1] = {
          path = op.path, line = op.line, start_line = op.line, end_line = op.end_line,
          body = op.body, t_id = op.t_id, c_id = op.c_id,
        }
      end
      return batch
    end

    if adapter.supports(resolved, "atomic_inline_batch") then
      -- One review POST: GitHub creates all comments or none. Lock the group
      -- first: if the process dies mid-call, recovery flags these ops
      -- uncertain and reconcile adopts whatever actually landed.
      for _, op in ipairs(creates) do outbox.mark_running(op.op_id) end
      local ok, err = resolved.adapter.submit_inline_review(
        resolved.cfg, ctx, number, to_batch(creates), nil, { verdict = verdict })
      if ok then
        for _, op in ipairs(creates) do
          -- The synced copy arrives via the reconcile that follows: a batch
          -- review POST does not hand back per-comment ids.
          commit(op, nil, consume_draft)
        end
      else
        -- Nothing landed (all-or-nothing), so the group goes back to QUEUED.
        for _, op in ipairs(creates) do outbox.mark_queued(op.op_id) end
        record(err)
      end
    else
      -- Per-note platforms: drive the loop here so every success is committed
      -- immediately. This is what stops a mid-loop failure from re-posting the
      -- notes that already landed.
      for _, op in ipairs(creates) do
        outbox.mark_running(op.op_id)
        local ok, err = resolved.adapter.submit_inline_review(
          resolved.cfg, ctx, number, to_batch({ op }))
        if not ok then
          outbox.mark_failed(op.op_id, err)
          record(err)
          break
        end
        commit(op, nil, consume_draft)
      end
    end
  end

  -- 2. Replies --------------------------------------------------------------
  for _, op in ipairs(group(outbox.OP.REPLY)) do
    outbox.mark_running(op.op_id)
    local remote_id, err = resolved.adapter.submit_reply(
      resolved.cfg, ctx, number, op.parent, op.body)
    if not remote_id then
      outbox.mark_failed(op.op_id, err)
      record(err)
      break
    end
    local rid = remote_id
    commit(op, rid, function(o) comments.mark_comment_synced(o.c_id, rid) end)
  end

  -- 3. Edits ----------------------------------------------------------------
  for _, op in ipairs(group(outbox.OP.EDIT)) do
    if not op.remote_id or op.remote_id == "" then
      outbox.mark_failed(op.op_id, "comment was never pushed")
      record("an edited comment has no remote id; pull to reconcile before editing it")
      break
    end
    outbox.mark_running(op.op_id)
    local ok, err = resolved.adapter.update_comment(
      resolved.cfg, ctx, number, op.t_id, op.remote_id, op.body)
    if not ok then
      outbox.mark_failed(op.op_id, err)
      record(err)
      break
    end
    commit(op, op.remote_id, function(o) comments.mark_clean(o.c_id) end)
  end

  -- 4. Deletions ------------------------------------------------------------
  for _, op in ipairs(group(outbox.OP.DELETE)) do
    if not op.remote_id or op.remote_id == "" then
      -- Local-only draft: there is no remote object to delete, so consuming it
      -- locally IS the whole job (v3 sent a real API call and 404'd).
      commit(op, nil, function(o) comments.delete_comment(o.c_id) end)
    else
      outbox.mark_running(op.op_id)
      local ok, err = resolved.adapter.delete_comment(
        resolved.cfg, ctx, number, op.t_id, op.remote_id)
      if not ok then
        outbox.mark_failed(op.op_id, err)
        record(err)
        break
      end
      commit(op, op.remote_id, function(o) comments.delete_comment(o.c_id) end)
    end
  end

  -- 5. Verdict --------------------------------------------------------------
  -- Only reached when build_ops decided the verdict could not ride along with a
  -- comment batch. An adapter that claims review_verdict but ships no
  -- submit_verdict is reported as a failure rather than a silent no-op.
  for _, op in ipairs(group(outbox.OP.VERDICT)) do
    local ok, err
    outbox.mark_running(op.op_id)
    if resolved.adapter.submit_verdict then
      ok, err = resolved.adapter.submit_verdict(
        resolved.cfg, ctx, number, op.verdict, op.body)
    else
      ok, err = false, "active adapter declares review_verdict but has no submit_verdict"
    end
    if not ok then
      outbox.mark_failed(op.op_id, err)
      record(err)
      break
    end
    commit(op, nil)
  end

  local remaining = #take_pending()
  if #skipped > 0 then
    record("skipped: " .. table.concat(skipped, "; "))
  end
  return pushed, first_err, remaining
end

--- Build the confirmation summary and verdict choice for submit_review.
--- Runs on the main thread (UI required).
---
--- `done(verdict, cancelled)` is invoked LATER when the float is shown: the
--- answer arrives on a keypress. v3 read the choice immediately after
--- ask_confirmation returned, so it always saw nil and reported every push as
--- cancelled — interactive submit never pushed anything.
---@param resolved table
---@param thread_id string|nil
---@param done fun(verdict: string|nil, cancelled: boolean)
local function confirm_submit(resolved, thread_id, done)
  local detail = M.current.detail
  local cs = M.compute_change_set(detail.mo_id)
  local function keep(item)
    return not thread_id or item.t_id == thread_id
  end

  local lines = {}
  local total = 0
  local function snippet(body)
    return ((body or ""):gsub("\n", " ")):sub(1, 45)
  end
  local function add(kind, text)
    lines[#lines + 1] = string.format("  [%-12s] %s", kind, text)
  end

  for _, d in ipairs(cs.additions) do
    if keep(d) then total = total + 1; add("New Thread", string.format("%s:%d: %s", d.path, d.start_line, snippet(d.body))) end
  end
  for _, d in ipairs(cs.replies) do
    if keep(d) then total = total + 1; add("New Reply", snippet(d.body)) end
  end
  for _, d in ipairs(cs.updates) do
    if keep(d) then total = total + 1; add("Edit Note", snippet(d.body)) end
  end
  for _, d in ipairs(cs.deletions) do
    if keep(d) then total = total + 1; add("Delete Note", snippet(d.body)) end
  end

  if total == 0 then
    -- Nothing queued and nothing to confirm.
    done(nil, false)
    return
  end

  table.insert(lines, 1, "Pending Review Changes:")

  local has_verdict = adapter.supports(resolved, "review_verdict")
  local confirm_ui = require("lreview.ui.confirm")

  if vim.g.lreview_test_mode then
    done("COMMENT", false)
    return
  end

  confirm_ui.ask_confirmation(lines, { has_verdict = has_verdict }, function(choice)
    if not choice then
      done(nil, true)
    else
      done(choice, false)
    end
  end)
end

--- Thread-entry point for submit_review.
--- Executed on worker thread with an isolated Lua state.
--- Handles the network push + reconciliation off the main thread.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, detail, thread_id, verdict }
---@return table
function M.submit_review_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  local old_current = M.current
  if args and args.cwd and args.detail then
    M.current = { cwd = args.cwd, detail = args.detail }
  end

  -- Resolve adapter on thread (uses io.popen fallback for git commands).
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    M.current = old_current
    db:close()
    return { ok = false, err = "no git remote detected", notifications = {} }
  end
  local ctx = adapter.ctx(resolved, args.detail.number)

  thread_mode = true
  M._notifications = {}

  local count, err, remaining = M._submit_pushes(
    args.detail, resolved, ctx, args.thread_id, args.verdict)

  -- Reconcile on success AND on partial failure: a half-pushed batch needs the
  -- remote's truth to adopt what landed (and to surface conflicts) before the
  -- next submit retries the rest.
  local remote_threads = M._fetch_remote_threads(args.detail, resolved, ctx)
  if remote_threads then
    M._reconcile_threads(args.detail, remote_threads)
    outbox.prune_done(args.detail.mo_id)
  end

  local notifications = M._notifications
  M._notifications = {}
  thread_mode = false

  M.current = old_current
  db:close()

  return {
    ok = (err == nil),
    count = count or 0,
    err = err,
    remaining = remaining or 0,
    notifications = notifications,
  }
end

local submit_worker = nil

--- Refresh every buffer that shows review state, through the sync bus.
local function refresh_review_ui()
  local sync = require("lreview.sync")
  local cwd = M.current and M.current.cwd
  if cwd then
    sync.invalidate_diff_cache(cwd)
  end
  for bufnr, _ in pairs(require("lreview.ui.decor").enabled_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      sync.mark_dirty(bufnr)
    end
  end
  sync.schedule()
end

--- Ensure the (singleton) submit worker exists.
---
--- The completion closure is created ONCE, so it must not capture a per-call
--- `callback` — it pulls the caller's callback out of the thread slot queue that
--- `submit_review` armed for this specific job.
local function ensure_submit_worker()
  if submit_worker then return end
  submit_worker = thread.create_worker("lreview.review", "submit_review_thread", function(res)
    -- Replay notifications collected on the worker thread (item 1).
    if res and res.notifications then
      for _, n in ipairs(res.notifications) do
        M._notifications[#M._notifications + 1] = n
      end
      M.drain_notifications()
    end

    local success = (res and res.ok) == true
    local count = (res and res.count) or 0
    local remaining = (res and res.remaining) or 0
    local err = res and res.err

    if success then
      refresh_review_ui()
    elseif err then
      -- Never fail silently: surface the push error to the user (item 3).
      vim.notify("lreview: push failed: " .. tostring(err), vim.log.levels.ERROR)
    end
    if remaining > 0 then
      vim.notify(string.format(
        "lreview: %d change(s) still queued — they stay as drafts, run :LocalReviewSubmit again",
        remaining), vim.log.levels.WARN)
    end

    thread.dispatch_cb("review.submit", success, count, err, remaining)
  end)
end

--- Submit the review: push draft inline comments (new threads, replies, edits,
--- deletions) for the current MR.
---
--- Runs the network push on a worker thread. The confirmation UI runs on the
--- main thread first and the push continues from its callback. In test mode
--- (vim.g.lreview_test_mode) everything runs synchronously for deterministic
--- testing.
---@param thread_id string|nil  -- optional thread ID to submit only one thread's comments
---@param callback fun(ok: boolean, count: integer, err: string|nil, remaining: integer|nil)|nil
---@return integer pushed, string|nil err  -- in test mode: synchronous; async mode: returns 0, nil
function M.submit_review(thread_id, callback)
  if not M.current then
    if callback then callback(false, 0, "no active review", 0) end
    return 0, "no active review"
  end

  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    if callback then callback(false, 0, "no git remote detected", 0) end
    return 0, "no git remote detected"
  end

  -- Check conflicts before showing UI.
  local conflict_count = comments.count_conflicts(detail.mo_id)
  if conflict_count > 0 then
    local err = string.format(
      "%d conflict(s) must be resolved before pushing. Use :LocalReviewConflicts to review.",
      conflict_count)
    if callback then callback(false, 0, err, outbox.count_pending(detail.mo_id)) end
    return 0, err
  end

  -- Results captured when the confirmation resolves synchronously (test mode).
  local sync_pushed, sync_err

  confirm_submit(resolved, thread_id, function(verdict, cancelled)
    if cancelled then
      vim.notify("lreview: push cancelled", vim.log.levels.INFO)
      if callback then callback(false, 0, nil, 0) end
      return
    end
    if not verdict then
      local err = "no draft, edited, or deleted comments to submit"
      if callback then callback(false, 0, err, 0) end
      return
    end

    -- Test mode: run synchronously on the main thread for deterministic tests.
    if vim.g.lreview_test_mode then
      local count, err, remaining = M._submit_pushes(
        detail, resolved, adapter.ctx(resolved, detail.number), thread_id, verdict)
      M.sync_review()
      sync_pushed, sync_err = count, err
      if callback then callback(err == nil, count or 0, err, remaining) end
      return
    end

    -- Normal mode: push on the worker thread (item 3), with THIS call's
    -- callback armed so the singleton worker replies to the right caller.
    ensure_submit_worker()
    thread.arm("review.submit", callback)
    submit_worker:queue({
      cwd = M.current.cwd,
      detail = M.current.detail,
      thread_id = thread_id,
      verdict = verdict,
    })
  end)

  if sync_pushed ~= nil then return sync_pushed, sync_err end
  return 0, nil
end

--- List draft comments for the current MR (for a review summary UI).
---@return table[]
function M.list_drafts()
  if not M.current then
    return {}
  end
  return comments.draft_threads(M.current.detail.mo_id)
end

--- Fetch remote threads/comments for an MR (network call).
--- Separated so submit-on-thread can reuse it without duplicating the
--- adapter interaction. (Plan 07 §2.8 — item 2 decomposition.)
---@param detail lreview.MRDetail
---@param resolved table
---@param ctx table
---@return table[]|nil remote_threads, string|nil err
function M._fetch_remote_threads(detail, resolved, ctx)
  return resolved.adapter.fetch_threads(resolved.cfg, ctx, detail.number, detail.mo_id)
end

--- Reconcile remote threads into local storage (batched, O(n)).
--- Pure DB work — no network calls. Separated from fetch so both
--- sync_review and submit_review_thread can share it.
--- (Plan 07 §2.8.1 — ~11x faster on large MRs.)
---@param detail lreview.MRDetail
---@param remote_threads table[]
---@return integer synced  -- number of remote threads processed
function M._reconcile_threads(detail, remote_threads)
  local remote_t_ids = {}
  local remote_c_ids = {}
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local n = 0

  -- Batched reconcile: load all local comments for this MR once, index them in
  -- memory by t_id -> c_id. Turns the N+1 inner-loop lookup into O(1) lookups.
  local local_by_thread = {}
  local local_comments = storage.query([[
    SELECT c.*, t.path, t.line_start, t.line_end, t.state as thread_state
    FROM comments c JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ?
  ]], detail.mo_id)
  for _, lc in ipairs(local_comments) do
    local_by_thread[lc.t_id] = local_by_thread[lc.t_id] or {}
    local_by_thread[lc.t_id][lc.c_id] = lc
  end

  -- Crash-recovery index: ops that were RUNNING when the process died have an
  -- unknown outcome. If the remote turns out to already contain that body, we
  -- adopt it (mark the op DONE, consume the local draft) instead of leaving the
  -- draft queued to be posted a second time on the next submit.
  local uncertain = outbox.uncertain_by_body(detail.mo_id)

  for _, t in ipairs(remote_threads) do
    remote_t_ids[t.t_id] = true
    local local_t = comments.get_thread(t.t_id)

    if local_t == nil then
      -- Brand new remote thread — insert as SYNCED.
      comments.create_thread({
        t_id = t.t_id,
        mo_id = detail.mo_id,
        path = t.path,
        commit_sha = t.commit_sha,
        start_line = t.start_line,
        end_line = t.end_line,
        is_draft = false,
        resolved = t.resolved == 1,
        last_synced_at = now,
      })
    elseif comments.thread_is_draft(local_t.state) then
      -- Local DRAFT thread: never overwrite it with remote data.
    else
      -- Existing synced thread: update resolved bit and payload.
      comments.create_thread({
        t_id = t.t_id,
        mo_id = detail.mo_id,
        path = t.path,
        commit_sha = t.commit_sha,
        start_line = t.start_line,
        end_line = t.end_line,
        is_draft = false,
        resolved = t.resolved == 1,
        last_synced_at = now,
      })
    end

    -- Process comments inside this thread.
    for _, c in ipairs(t.comments or {}) do
      remote_c_ids[c.c_id] = true

      -- Find our local copy by remote_id (c_id on remote == c_id in our DB
      -- once synced; for first-time arrivals, look by remote_id field).
      local local_c
      local t_idx = local_by_thread[t.t_id]
      if t_idx then
        local_c = t_idx[c.c_id]
        if not local_c then
          for _, lc in pairs(t_idx) do
            if lc.remote_id == c.remote_id then
              local_c = lc
              break
            end
          end
        end
      end

      if local_c then
        local decoded_lc = local_c
        if decoded_lc.payload then
          local mpack_payload = vim.mpack.decode(decoded_lc.payload) or {}
          decoded_lc = vim.tbl_extend("force", decoded_lc, mpack_payload)
          decoded_lc.payload = nil
        end

        if decoded_lc then
          local lstate = decoded_lc.state

          if lstate == comments.STATE.DRAFT then
            -- DRAFT: never overwrite.
          elseif lstate == comments.STATE.SYNCED then
            comments.add_comment({
              c_id = c.c_id,
              t_id = t.t_id,
              remote_id = c.remote_id,
              author = c.author,
              body = c.body,
              created_at = c.created_at,
              in_reply_to = c.in_reply_to,
              state = comments.STATE.SYNCED,
            })
          elseif lstate == comments.STATE.MODIFIED then
            local synced_body = decoded_lc.synced_body
            if c.body ~= synced_body then
              comments.mark_comment_conflict(decoded_lc.c_id, c.body, "remote_edited")
              notify(
                string.format("lreview: conflict on %s:%d — remote edited a comment you are editing",
                  t.path, t.start_line or 0),
                vim.log.levels.WARN)
            end
          elseif lstate == comments.STATE.DELETED then
            local synced_body = decoded_lc.synced_body
            if c.body ~= synced_body then
              comments.mark_comment_conflict(decoded_lc.c_id, c.body, "remote_edited")
              notify(
                string.format("lreview: conflict on %s:%d — remote edited a comment you deleted",
                  t.path, t.start_line or 0),
                vim.log.levels.WARN)
            end
          elseif lstate == comments.STATE.CONFLICT then
            comments.mark_comment_conflict(decoded_lc.c_id, c.body, decoded_lc.conflict_reason or "remote_edited")
          end
        end
      else
        -- No local copy. Before inserting a fresh SYNCED row, check whether
        -- this is a comment WE pushed whose result was never recorded locally
        -- (crash between the network call and the outbox write). Adopting it
        -- consumes the local draft so it cannot be posted twice.
        local adopt = uncertain[c.body or ""]
        if adopt then
          outbox.mark_done(adopt.op_id, c.remote_id)
          comments.delete_comment(adopt.c_id)
          if adopt.op == outbox.OP.CREATE_THREAD then
            comments.delete_thread(adopt.t_id)
          end
          uncertain[c.body or ""] = nil
        end
        comments.add_comment({
          c_id = c.c_id,
          t_id = t.t_id,
          remote_id = c.remote_id,
          author = c.author,
          body = c.body,
          created_at = c.created_at,
          in_reply_to = c.in_reply_to,
          state = comments.STATE.SYNCED,
        })
      end
    end
    n = n + 1
  end

  -- Handle remote-side deletions
  local all_synced = storage.query([[
    SELECT c.c_id, c.remote_id, c.state, c.payload, t.path, t.line_start
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND c.remote_id IS NOT NULL
  ]], detail.mo_id)

  for _, ec in ipairs(all_synced or {}) do
    if not remote_c_ids[ec.remote_id] then
      local lstate = ec.state

      if lstate == comments.STATE.SYNCED then
        comments.delete_comment(ec.c_id)
      elseif lstate == comments.STATE.MODIFIED then
        comments.mark_comment_conflict(ec.c_id, "", "remote_deleted")
        notify(
          string.format("lreview: conflict on %s:%d — remote deleted a comment you are editing",
            ec.path or "?", ec.line_start or 0),
          vim.log.levels.WARN)
      elseif lstate == comments.STATE.DELETED then
        comments.delete_comment(ec.c_id)
      end
    end
  end

  -- Handle threads deleted on the remote
  local all_local_threads = comments.threads_for_mr(detail.mo_id)
  for _, lt in ipairs(all_local_threads) do
    if not comments.thread_is_draft(lt.state) and not remote_t_ids[lt.t_id] then
      local draft_children = storage.query([[
        SELECT COUNT(*) as n FROM comments WHERE t_id = ? AND state = ?
      ]], lt.t_id, comments.STATE.DRAFT)
      local has_orphaned_drafts = (draft_children[1] and draft_children[1].n or 0) > 0

      if has_orphaned_drafts then
        comments.mark_thread_conflict(lt.t_id, "remote_deleted_has_drafts")
        notify(
          string.format("lreview: conflict — thread on %s deleted remotely but you have unsent replies",
            lt.path or "?"),
          vim.log.levels.WARN)
      else
        comments.delete_thread(lt.t_id)
      end
    end
  end

  return n
end

--- Sync remote MR threads/comments into local storage.
--- Fetches the platform's inline comments/discussions for the current MR and
--- upserts them as synced (is_draft=0) threads. Local drafts (is_draft=1) are
--- preserved. Returns the number of remote threads synced.
---@return integer synced, string|nil err
function M.sync_review()
  if not M.current then
    return 0, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return 0, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)
  local remote_threads, err = M._fetch_remote_threads(detail, resolved, ctx)
  if not remote_threads then
    return 0, err
  end
  return M._reconcile_threads(detail, remote_threads)
end

--- List available MR/PR templates for the current repo.
---@param cwd string|nil
---@return table[]|nil templates, string|nil err
function M.list_templates(cwd)
  local resolved = adapter.resolve(cwd or vim.fn.getcwd())
  if not resolved then
    return nil, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved)
  return resolved.adapter.list_templates(resolved.cfg, ctx)
end

--- Thread-entry point for sync_review.
--- Executed on worker thread with an isolated Lua state.
--- Returns notifications collected during sync_review so they can be
--- replayed on the main thread. (doc 12 §3.8 / doc 09 §2.6 — item 1.)
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, detail }
---@return table
function M.sync_review_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  local old_current = M.current
  if args and args.cwd and args.detail then
    M.current = {
      cwd = args.cwd,
      detail = args.detail,
    }
  end

  thread_mode = true
  M._notifications = {}
  local count, err = M.sync_review()
  local notifications = M._notifications
  M._notifications = {}
  thread_mode = false

  M.current = old_current
  db:close()

  if err then
    return { ok = false, err = err, notifications = notifications }
  end
  return { ok = true, count = count, notifications = notifications }
end

local thread_worker = nil

--- Fetch remote reviews asynchronously (non-blocking).
--- Runs sync_review on a libuv thread with MessagePack serialization.
--- Notifications collected on the thread are replayed here on the main thread.
--- Uses the sync-bus for UI refresh instead of direct refresh. (items 1, 5, 6)
---@param callback fun(success: boolean)|nil
---@return boolean, string|nil
function M.pull_review_async(callback)
  if not M.current then
    if callback then callback(false) end
    return false, "no active review"
  end

  if not thread_worker then
    thread_worker = thread.create_worker("lreview.review", "sync_review_thread", function(res)
      local success = res and res.ok
      if success then
        -- Replay notifications collected on the worker thread (item 1).
        if res.notifications then
          for _, n in ipairs(res.notifications) do
            M._notifications[#M._notifications + 1] = n
          end
          M.drain_notifications()
        end

        -- Invalidate diff cache after pull (item 5) and use sync-bus
        -- for UI refresh instead of direct refresh (item 6).
        local sync = require("lreview.sync")
        local cwd = M.current and M.current.cwd
        if cwd then
          sync.invalidate_diff_cache(cwd)
        end
        for bufnr, _ in pairs(require("lreview.ui.decor").enabled_buffers) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            sync.mark_dirty(bufnr)
          end
        end
        sync.schedule()
      end
      thread.dispatch_cb("review.pull", success == true)
    end)
  end

  thread.arm("review.pull", callback)
  thread_worker:queue({
    cwd = M.current.cwd or vim.fn.getcwd(),
    detail = M.current.detail,
  })
  return true, nil
end

--- Thread-entry point for close_review_async.
--- Executed on a uv.new_work worker thread with an isolated Lua state.
--- Runs the remote close CLI call (io.popen fallback for git/adapter) off the
--- main thread. Storage state is NOT touched here; the main-thread callback
--- updates SQLite after a successful close.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, detail, number }
---@return table
function M.close_review_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  local old_current = M.current
  if args and args.cwd and args.detail then
    M.current = { cwd = args.cwd, detail = args.detail }
  end

  local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    M.current = old_current
    db:close()
    return { ok = false, err = "no git remote detected" }
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.close_mr(resolved.cfg, ctx, num)

  M.current = old_current
  db:close()
  return { ok = ok, err = err, number = num }
end

local close_worker = nil

--- Close an MR on the platform without blocking the UI.
--- Resolves the remote close call on a uv.new_work worker and updates local
--- storage on the main thread via the callback.
---@param number integer|nil -- remote MR/PR number
---@param callback fun(ok: boolean, err: string|nil)|nil
---@return boolean, string|nil  -- false, "" when queued (async)
function M.close_review_async(number, callback)
  if not M.current then
    if callback then callback(false, "no active review") end
    return false, "no active review"
  end
  local detail = M.current.detail
  local num = number or detail.number
  if not num then
    if callback then callback(false, "no active review; run LocalReviewStart first (or pass an MR number)") end
    return false, "no active review; run LocalReviewStart first (or pass an MR number)"
  end
  local cwd = M.current.cwd or vim.fn.getcwd()

  if not close_worker then
    close_worker = thread.create_worker("lreview.review", "close_review_thread", function(res)
      if res and res.ok then
        local pull_request_storage = require("lreview.storage.pull_request")
        local pr_detail = M.current and M.current.detail
        if pr_detail and pr_detail.mo_id then
          pull_request_storage.update_state(pr_detail.mo_id, "closed")
        end
      end
      thread.dispatch_cb("review.close", res and res.ok, res and res.err or nil)
    end)
  end

  thread.arm("review.close", callback)
  close_worker:queue({ cwd = cwd, detail = detail, number = num })
  return false, nil
end

--- Thread-entry point for approve_review_async.
--- Runs the remote approve CLI call on a worker thread. Storage updated by the
--- main-thread callback.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, detail, number }
---@return table
function M.approve_review_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  local old_current = M.current
  if args and args.cwd and args.detail then
    M.current = { cwd = args.cwd, detail = args.detail }
  end

  local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    M.current = old_current
    db:close()
    return { ok = false, err = "no git remote detected" }
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.approve_mr(resolved.cfg, ctx, num)

  M.current = old_current
  db:close()
  return { ok = ok, err = err, number = num }
end

local approve_worker = nil

--- Approve an MR on the platform without blocking the UI.
--- Runs the remote approve call on a uv.new_work worker.
---@param number integer|nil -- remote MR/PR number
---@param callback fun(ok: boolean, err: string|nil)|nil
---@return boolean, string|nil  -- false, nil when queued (async)
function M.approve_review_async(number, callback)
  if not M.current then
    if callback then callback(false, "no active review") end
    return false, "no active review"
  end
  local detail = M.current.detail
  local num = number or detail.number
  if not num then
    if callback then callback(false, "no active review; run LocalReviewStart first (or pass an MR number)") end
    return false, "no active review; run LocalReviewStart first (or pass an MR number)"
  end
  local cwd = M.current.cwd or vim.fn.getcwd()

  if not approve_worker then
    approve_worker = thread.create_worker("lreview.review", "approve_review_thread", function(res)
      if res and res.ok then
        local pull_request_storage = require("lreview.storage.pull_request")
        local pr_detail = M.current and M.current.detail
        if pr_detail and pr_detail.mo_id then
          pull_request_storage.update_state(pr_detail.mo_id, "approved")
        end
      end
      thread.dispatch_cb("review.approve", res and res.ok, res and res.err or nil)
    end)
  end

  thread.arm("review.approve", callback)
  approve_worker:queue({ cwd = cwd, detail = detail, number = num })
  return false, nil
end

--- Thread-entry point for resolve_thread_async.
--- Runs the remote resolve CLI call for a synced thread on a worker thread.
--- Local storage is updated by the main-thread callback once the remote call
--- succeeds (SQLite is owned by the main thread).
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, detail, thread_id, resolved_val }
---@return table
function M.resolve_thread_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  local old_current = M.current
  if args and args.cwd and args.detail then
    M.current = { cwd = args.cwd, detail = args.detail }
  end

  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    M.current = old_current
    db:close()
    return { ok = false, err = "no git remote detected" }
  end
  local ctx = adapter.ctx(resolved, M.current.detail.number)
  local ok, err = resolved.adapter.resolve_thread(
    resolved.cfg, ctx, M.current.detail.number, args.thread_id, args.resolved_val)

  M.current = old_current
  db:close()
  -- Echo which thread this result belongs to: the completion closure is shared
  -- across all calls, so it must not use a captured `thread_id`.
  return { ok = ok, err = err, thread_id = args.thread_id, resolved_val = args.resolved_val }
end

local resolve_worker = nil

--- Resolve a synced thread on the platform without blocking the UI.
--- Draft threads are resolved locally/synchronously; synced threads hit the
--- remote on a uv.new_work worker and update local state via the callback.
---@param thread_id string
---@param resolved_val boolean
---@param callback fun(ok: boolean, err: string|nil)|nil
---@return boolean, string|nil
function M.resolve_thread_async(thread_id, resolved_val, callback)
  local t = comments.get_thread(thread_id)
  if not t then
    if callback then callback(false, "thread not found") end
    return false, "thread not found"
  end

  -- Draft threads: resolve locally (no network).
  if comments.thread_is_draft(t.state) then
    comments.resolve_thread(thread_id, resolved_val)
    if callback then callback(true, nil) end
    return true, nil
  end

  if not M.current then
    if callback then callback(false, "no active review; run LocalReviewStart first") end
    return false, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local cwd = M.current.cwd or vim.fn.getcwd()

  if not resolve_worker then
    resolve_worker = thread.create_worker("lreview.review", "resolve_thread_thread", function(res)
      if res and res.ok and res.thread_id then
        comments.resolve_thread(res.thread_id, res.resolved_val == true)
      end
      thread.dispatch_cb("review.resolve_thread", res and res.ok, res and res.err or nil)
    end)
  end

  thread.arm("review.resolve_thread", callback)
  resolve_worker:queue({ cwd = cwd, detail = detail, thread_id = thread_id, resolved_val = resolved_val })
  return false, nil
end

--- Thread-entry point for create_review_async.
--- Runs the MR/PR create CLI call on a uv.new_work worker.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, opts }
---@return table
function M.create_review_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  if args and args.cwd then
    M.current = { cwd = args.cwd, detail = M.current and M.current.detail }
  end
  local resolved = adapter.resolve(args.cwd)
  if not resolved then
    db:close()
    return { ok = false, err = "no git remote detected" }
  end
  local ctx = adapter.ctx(resolved)
  local url, err = resolved.adapter.create_mr(resolved.cfg, ctx, args.opts)

  db:close()
  return { ok = (url ~= nil), url = url, err = err }
end

local create_worker = nil

--- Create a new MR/PR on the platform without blocking the UI.
---@param opts table  -- { title, body, source_branch, target_branch, template }
---@param cwd string|nil
---@param callback fun(url: string|nil, err: string|nil)|nil
---@return boolean, string|nil  -- false, nil when queued (async)
function M.create_review_async(opts, cwd, callback)
  cwd = cwd or (M.current and M.current.cwd) or vim.fn.getcwd()
  if not create_worker then
    create_worker = thread.create_worker("lreview.review", "create_review_thread", function(res)
      thread.dispatch_cb("review.create", res and res.url, res and res.err or nil)
    end)
  end
  thread.arm("review.create", callback)
  create_worker:queue({ cwd = cwd, opts = opts })
  return false, nil
end

--- Thread-entry point for request_reviewers_async.
--- Runs the reviewer-assignment CLI call on a uv.new_work worker.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, number, reviewers }
---@return table
function M.request_reviewers_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  local old_current = M.current
  if args and args.cwd and args.detail then
    M.current = { cwd = args.cwd, detail = args.detail }
  end
  local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
  local resolved = adapter.resolve(args.cwd)
  if not resolved then
    M.current = old_current
    db:close()
    return { ok = false, err = "no git remote detected" }
  end
  if not adapter.supports(resolved, "assign_reviewers") then
    M.current = old_current
    db:close()
    return { ok = false, err = "reviewer assignment capability is not supported by active adapter" }
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.assign_reviewers(resolved.cfg, ctx, num, args.reviewers)

  M.current = old_current
  db:close()
  return { ok = ok, err = err }
end

local request_reviewers_worker = nil

--- Request reviewers for an MR/PR without blocking the UI.
---@param reviewers string[]
---@param number integer|nil
---@param cwd string|nil
---@param callback fun(ok: boolean, err: string|nil)|nil
---@return boolean, string|nil  -- false, nil when queued (async)
function M.request_reviewers_async(reviewers, number, cwd, callback)
  local num = number or (M.current and M.current.detail and M.current.detail.number)
  if not num then
    if callback then callback(false, "no active review; run LocalReviewStart first (or pass an MR number)") end
    return false, "no active review; run LocalReviewStart first (or pass an MR number)"
  end
  cwd = cwd or (M.current and M.current.cwd) or vim.fn.getcwd()

  if not request_reviewers_worker then
    request_reviewers_worker = thread.create_worker("lreview.review", "request_reviewers_thread", function(res)
      thread.dispatch_cb("review.request_reviewers", res and res.ok, res and res.err or nil)
    end)
  end
  thread.arm("review.request_reviewers", callback)
  request_reviewers_worker:queue({
    cwd = cwd,
    detail = M.current and M.current.detail,
    number = num,
    reviewers = reviewers,
  })
  return false, nil
end

--- Thread-entry point for update_review_async.
--- Runs the MR/PR update CLI call on a uv.new_work worker.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, number, title, body }
---@return table
function M.update_review_thread(db_path, lazy_sqlite, args)
  local sqlite = require("sqlite")
  local db = sqlite.new(db_path, { keep_open = true })
  db:eval("PRAGMA journal_mode=WAL;")
  db:eval("PRAGMA busy_timeout=5000;")
  -- Worker threads must skip `ensure_db()` → `open_raw()` → `vim.fn` (nil on
  -- `uv.new_work` per doc 09 §2.5). Attaching this connection lets
  -- `storage.query`/`execute` and the outbox/comments CRUD modules use it
  -- directly. This is doc 09 §7.5's "target a specific connection" fix,
  -- landed on the module-local side so callers stay unchanged.
  storage.attach_db(db)

  local old_current = M.current
  if args and args.cwd and args.detail then
    M.current = { cwd = args.cwd, detail = args.detail }
  end
  local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
  local resolved = adapter.resolve(args.cwd)
  if not resolved then
    M.current = old_current
    db:close()
    return { ok = false, err = "no git remote detected" }
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.update_mr(resolved.cfg, ctx, num, args.title, args.body)

  M.current = old_current
  db:close()
  -- Echo the edited fields: the completion closure is shared across all calls,
  -- so reading captured upvalues would write a PREVIOUS edit into the cache.
  return { ok = ok, err = err, number = num, title = args.title, body = args.body }
end

local update_worker = nil

--- Update an MR/PR's title and description without blocking the UI.
---@param title string
---@param body string
---@param number integer|nil
---@param cwd string|nil
---@param callback fun(ok: boolean, err: string|nil)|nil
---@return boolean, string|nil  -- false, nil when queued (async)
function M.update_review_async(title, body, number, cwd, callback)
  local num = number or (M.current and M.current.detail and M.current.detail.number)
  if not num then
    if callback then callback(false, "no active review") end
    return false, "no active review"
  end
  cwd = cwd or (M.current and M.current.cwd) or vim.fn.getcwd()

  if not update_worker then
    update_worker = thread.create_worker("lreview.review", "update_review_thread", function(res)
      if res and res.ok and res.title ~= nil and M.current
          and M.current.detail and M.current.detail.number == res.number then
        -- `description` is the model's field name (mappers write it); the old
        -- code wrote `.body`, which nothing read — the same drift that left the
        -- MR description blank in the detail editor.
        M.current.detail.title = res.title
        M.current.detail.description = res.body
        local pull_request = require("lreview.storage.pull_request")
        local ok_storage = storage.open()
        if ok_storage then
          local key = (M.current.detail.provider) .. ":" .. (M.current.detail.repo) .. ":" .. res.number
          local cached = pull_request.get(key)
          if cached then
            cached.title = res.title
            cached.description = res.body
            pull_request.upsert(cached)
          end
        end
      end
      thread.dispatch_cb("review.update", res and res.ok, res and res.err or nil)
    end)
  end

  thread.arm("review.update", callback)
  update_worker:queue({ cwd = cwd, detail = M.current and M.current.detail, number = num, title = title, body = body })
  return false, nil
end

return M
