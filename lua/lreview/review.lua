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
 
  return table.concat(t, "", 1, 8) .. "-" .. table.concat(t, "", 9, 12)
      .. "-" .. table.concat(t, "", 13, 16) .. "-" .. table.concat(t, "", 17, 20)
      .. "-" .. table.concat(t, "", 21, 32)
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

  -- Crash recovery: revert any comments stuck in IN_FLIGHT state (item 4).
  local recovered = comments.recover_in_flight()
  if recovered > 0 and vim.notify then
    vim.notify(string.format("lreview: recovered %d comment(s) from interrupted push", recovered), vim.log.levels.INFO)
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
---@return table  -- { ok, detail?, err? }
function M.resolve_mr_thread(db_path, lazy_sqlite, args)
  local cwd = args and args.cwd
  if not cwd then
    return { ok = false, err = "no cwd provided" }
  end
  local ok, detail, err = pcall(M.resolve_current_mr, cwd)
  if not ok then
    return { ok = false, err = tostring(detail) }
  end
  if not detail then
    return { ok = false, err = err }
  end
  return { ok = true, detail = detail }
end

local init_worker = nil

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

  -- Crash recovery: revert any comments stuck in IN_FLIGHT state (item 4).
  local recovered = comments.recover_in_flight()
  if recovered > 0 and vim.notify then
    vim.notify(string.format("lreview: recovered %d comment(s) from interrupted push", recovered), vim.log.levels.INFO)
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
  local resolve_started = nil
  if not init_worker then
    init_worker = thread.create_worker("lreview.review", "resolve_mr_thread", function(res)
      local detail = res and res.ok and res.detail
      if timing.enabled() and resolve_started then
        timing.record(timing.CAT_FLOW, "resolve_mr_roundtrip", (vim.uv.hrtime() / 1e6) - resolve_started)
      end
      if detail and M.current and M.current.cwd == cwd then
        -- Upgrade the session to the real (linked) MR detail.
        pull_request.upsert(detail)
        M.current.detail = detail
        -- Auto-pull remote updates only in interactive sessions. The headless
        -- pull job sets vim.g.lreview_pull_job before calling init_session,
        -- which would otherwise spawn an unbounded chain of nested pull jobs.
        if not vim.g.lreview_pull_job and not detail.unlinked then
          M.pull_review_async(cwd)
        end
        -- Refresh any open UI (decor) now that the real MR is known.
        local sync2 = require("lreview.sync")
        sync2.invalidate_diff_cache(cwd)
        for bufnr, _ in pairs(require("lreview.ui.decor").enabled_buffers) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            sync2.mark_dirty(bufnr)
          end
        end
        sync2.schedule()
      end
      if callback and type(callback) == "function" then
        callback(detail, (not detail) and (res and res.err) or nil)
      end
    end)
  end

  if timing.enabled() then
    resolve_started = vim.uv.hrtime() / 1e6
  end
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

--- Push the actual network calls for submit_review.
--- Extracted so both main-thread and thread paths can share it.
--- (Plan 07 §2.7 — item 3 decomposition.)
---@param detail lreview.MRDetail
---@param resolved table
---@param ctx table
---@param thread_id string|nil  -- optional filter
---@param verdict string
---@return integer count, string|nil err
function M._submit_pushes(detail, resolved, ctx, thread_id, verdict)
  -- Query pending comments via storage
  local drafts = comments.get_pending_comments(detail.mo_id)

  if thread_id then
    local filtered = {}
    for _, d in ipairs(drafts) do
      if d.t_id == thread_id then
        filtered[#filtered + 1] = d
      end
    end
    drafts = filtered
  end

  -- Block push if any unresolved conflicts exist.
  local conflict_count = comments.count_conflicts(detail.mo_id)
  if conflict_count > 0 then
    return 0, string.format(
      "%d conflict(s) must be resolved before pushing. Use :LocalReviewConflicts to review.",
      conflict_count)
  end

  if not drafts or #drafts == 0 then
    return 0, "no draft, edited, or deleted comments to submit"
  end

  local new_threads_batch = {}
  local replies = {}
  local edits = {}
  local deletes = {}

  for _, d in ipairs(drafts) do
    if d.state == comments.STATE.DELETED then
      deletes[#deletes + 1] = {
        t_id = d.t_id,
        c_id = d.c_id,
        remote_id = d.remote_id,
        body = d.body or "",
      }
    elseif d.state == comments.STATE.MODIFIED then
      edits[#edits + 1] = {
        t_id = d.t_id,
        c_id = d.c_id,
        remote_id = d.remote_id,
        body = d.body,
      }
    elseif comments.thread_is_draft(d.thread_state) then
      new_threads_batch[#new_threads_batch + 1] = {
        path = d.path,
        line = d.start_line,
        body = d.body,
        t_id = d.t_id,
        c_id = d.c_id,
      }
    else
      local reply_to_id = d.t_id
      if resolved.provider == "gh" or resolved.provider == "github" then
        local cs = comments.comments_for_thread(d.t_id)
        if #cs > 0 then
          reply_to_id = cs[1].remote_id
        end
      end
      replies[#replies + 1] = {
        t_id = d.t_id,
        c_id = d.c_id,
        body = d.body,
        reply_to_id = reply_to_id,
      }
    end
  end

  local count = 0

  -- Mark all pending items as IN_FLIGHT before pushing, as one DB transaction
  -- (Plan 07 §2.7 — wrap local writes, never the network).
  local function mark_all_in_flight()
    storage.with_transaction(function()
      for _, nt in ipairs(new_threads_batch) do comments.mark_in_flight(nt.c_id) end
      for _, r in ipairs(replies) do comments.mark_in_flight(r.c_id) end
      for _, e in ipairs(edits) do comments.mark_in_flight(e.c_id) end
      for _, dl in ipairs(deletes) do comments.mark_in_flight(dl.c_id) end
    end)
  end
  mark_all_in_flight()

  -- 1. Submit new threads in a batch
  if #new_threads_batch > 0 then
    local ok, err = resolved.adapter.submit_inline_review(resolved.cfg, ctx, detail.number, new_threads_batch, nil, { verdict = verdict })
    if not ok then
      for _, nt in ipairs(new_threads_batch) do comments.revert_in_flight(nt.c_id, comments.STATE.DRAFT) end
      for _, r in ipairs(replies) do comments.revert_in_flight(r.c_id, comments.STATE.DRAFT) end
      for _, e in ipairs(edits) do comments.revert_in_flight(e.c_id, comments.STATE.MODIFIED) end
      for _, dl in ipairs(deletes) do comments.revert_in_flight(dl.c_id, comments.STATE.DELETED) end
      return 0, err
    end
    -- Clear local drafts on success
    for _, nt in ipairs(new_threads_batch) do
      comments.delete_comment(nt.c_id)
      comments.delete_thread(nt.t_id)
    end
    count = count + #new_threads_batch
  end

  -- 2. Push replies
  for _, r in ipairs(replies) do
    local comment_id, err = resolved.adapter.submit_reply(resolved.cfg, ctx, detail.number, r.reply_to_id, r.body)
    if not comment_id then
      comments.revert_in_flight(r.c_id, comments.STATE.DRAFT)
      return count, err
    end
    comments.mark_comment_synced(r.c_id, comment_id)
    count = count + 1
  end

  -- 3. Push edits
  for _, e in ipairs(edits) do
    local ok, err = resolved.adapter.update_comment(resolved.cfg, ctx, detail.number, e.remote_id, e.body)
    if not ok then
      comments.revert_in_flight(e.c_id, comments.STATE.MODIFIED)
      return count, err
    end
    comments.mark_clean(e.c_id)
    count = count + 1
  end

  -- 4. Push deletes
  for _, dl in ipairs(deletes) do
    local ok, err = resolved.adapter.delete_comment(resolved.cfg, ctx, detail.number, dl.remote_id)
    if not ok then
      comments.revert_in_flight(dl.c_id, comments.STATE.DELETED)
      return count, err
    end
    comments.delete_comment(dl.c_id)
    count = count + 1
  end

  return count, nil
end

--- Build the confirmation summary and verdict choice for submit_review.
--- Runs on the main thread (UI required).
---@param resolved table
---@param thread_id string|nil
---@return string|nil verdict, boolean cancelled
local function confirm_submit(resolved, thread_id)
  local detail = M.current.detail
  local drafts = comments.get_pending_comments(detail.mo_id)
  if thread_id then
    local filtered = {}
    for _, d in ipairs(drafts) do
      if d.t_id == thread_id then
        filtered[#filtered + 1] = d
      end
    end
    drafts = filtered
  end

  local new_threads_batch = {}
  local replies = {}
  local edits = {}
  local deletes = {}

  for _, d in ipairs(drafts) do
    if d.state == comments.STATE.DELETED then
      deletes[#deletes + 1] = { t_id = d.t_id, c_id = d.c_id, body = d.body or "" }
    elseif d.state == comments.STATE.MODIFIED then
      edits[#edits + 1] = { t_id = d.t_id, c_id = d.c_id, body = d.body }
    elseif comments.thread_is_draft(d.thread_state) then
      new_threads_batch[#new_threads_batch + 1] = {
        path = d.path, line = d.start_line, body = d.body,
        t_id = d.t_id, c_id = d.c_id,
      }
    else
      replies[#replies + 1] = {
        t_id = d.t_id, c_id = d.c_id, body = d.body,
      }
    end
  end

  if #new_threads_batch == 0 and #replies == 0 and #edits == 0 and #deletes == 0 then
    return nil, false
  end

  -- Format confirmation summary
  local summary = { "Pending Review Changes:" }
  for _, nt in ipairs(new_threads_batch) do
    local snippet = nt.body:gsub("\n", " "):sub(1, 45)
    summary[#summary + 1] = string.format("  [New Thread]  %s:%d: %s", nt.path, nt.line, snippet)
  end
  for _, r in ipairs(replies) do
    local snippet = r.body:gsub("\n", " "):sub(1, 45)
    summary[#summary + 1] = string.format("  [New Reply]   %s", snippet)
  end
  for _, e in ipairs(edits) do
    local snippet = e.body:gsub("\n", " "):sub(1, 45)
    summary[#summary + 1] = string.format("  [Edit Note]   %s", snippet)
  end
  for _, dl in ipairs(deletes) do
    local snippet = dl.body:gsub("\n", " "):sub(1, 45)
    summary[#summary + 1] = string.format("  [Delete Note] %s", snippet)
  end

  local has_verdict = adapter.supports(resolved, "review_verdict")

  local confirm_ui = require("lreview.ui.confirm")
  local choice_verdict = nil

  if vim.g.lreview_test_mode then
    return "COMMENT", false
  else
    confirm_ui.ask_confirmation(summary, { has_verdict = has_verdict }, function(choice)
      choice_verdict = choice
    end)
    if not choice_verdict then
      return nil, true
    end
    return choice_verdict, false
  end
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

  -- Push network calls
  local count, err = M._submit_pushes(args.detail, resolved, ctx, args.thread_id, args.verdict)

  -- Reconcile after push (fetch fresh remote threads + reconcile)
  if not err then
    local remote_threads = M._fetch_remote_threads(args.detail, resolved, ctx)
    if remote_threads then
      M._reconcile_threads(args.detail, remote_threads)
    end
  else
    -- On error, still reconcile to pick up any partial state
    local remote_threads = M._fetch_remote_threads(args.detail, resolved, ctx)
    if remote_threads then
      M._reconcile_threads(args.detail, remote_threads)
    end
  end

  local notifications = M._notifications
  M._notifications = {}
  thread_mode = false

  M.current = old_current
  db:close()

  return { ok = (err == nil), count = count or 0, err = err, notifications = notifications }
end

local submit_worker = nil

--- Submit the review: push draft inline comments (new threads and replies) for the current MR.
--- Only pushes inline comments; does NOT change platform review state.
--- Runs the network push on a worker thread. The confirmation UI runs on the
--- main thread first. In test mode (vim.g.lreview_test_mode) the push runs
--- synchronously on the main thread for deterministic testing. (item 3)
---@param thread_id string|nil  -- optional thread ID to submit only comments from a single thread
---@param callback fun(ok: boolean, count: integer, err: string|nil)|nil
---@return integer pushed, string|nil err  -- in test mode: synchronous; async mode: returns 0, nil
function M.submit_review(thread_id, callback)
  if not M.current then
    if callback then callback(false, 0, "no active review") end
    return 0, "no active review"
  end

  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    if callback then callback(false, 0, "no git remote detected") end
    return 0, "no git remote detected"
  end

  -- Check conflicts before showing UI
  local conflict_count = comments.count_conflicts(detail.mo_id)
  if conflict_count > 0 then
    local err = string.format(
      "%d conflict(s) must be resolved before pushing. Use :LocalReviewConflicts to review.",
      conflict_count)
    if callback then callback(false, 0, err) end
    return 0, err
  end

  -- Confirmation UI (main thread)
  local verdict, cancelled = confirm_submit(resolved, thread_id)
  if cancelled then
    if vim.notify then
      vim.notify("lreview: push cancelled", vim.log.levels.INFO)
    end
    if callback then callback(false, 0, nil) end
    return 0, nil
  end
  if not verdict then
    if callback then callback(false, 0, "no draft, edited, or deleted comments to submit") end
    return 0, "no draft, edited, or deleted comments to submit"
  end

  -- Test mode: run synchronously on the main thread for deterministic testing.
  if vim.g.lreview_test_mode then
    local count, err = M._submit_pushes(detail, resolved, adapter.ctx(resolved, detail.number), thread_id, verdict)
    -- Reconcile
    M.sync_review()
    if callback then callback(err == nil, count or 0, err) end
    return count or 0, err
  end

  -- Normal mode: queue thread for network push (item 3).
  if not submit_worker then
    submit_worker = thread.create_worker("lreview.review", "submit_review_thread", function(res)
      -- Replay notifications collected on the worker thread (item 1).
      if res and res.notifications then
        for _, n in ipairs(res.notifications) do
          M._notifications[#M._notifications + 1] = n
        end
        M.drain_notifications()
      end

      local success = res and res.ok
      if success then
        -- Refresh UI via sync bus (item 6).
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
      elseif res and res.err then
        -- Never fail silently: surface the push error to the user (item 3).
        if vim.notify then
          vim.notify("lreview: push failed: " .. res.err, vim.log.levels.ERROR)
        end
      end

      if callback then
        callback(success == true, (res and res.count) or 0, res and res.err)
      end
    end)
  end

  submit_worker:queue({
    cwd = M.current.cwd,
    detail = M.current.detail,
    thread_id = thread_id,
    verdict = verdict,
  })

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
      if callback and type(callback) == "function" then
        callback(success == true)
      end
    end)
  end

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
      if callback and type(callback) == "function" then
        callback(res and res.ok, res and res.err or nil)
      end
    end)
  end

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
      if callback and type(callback) == "function" then
        callback(res and res.ok, res and res.err or nil)
      end
    end)
  end

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
  return { ok = ok, err = err }
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
      if res and res.ok then
        comments.resolve_thread(thread_id, resolved_val)
      end
      if callback and type(callback) == "function" then
        callback(res and res.ok, res and res.err or nil)
      end
    end)
  end

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
      if callback and type(callback) == "function" then
        callback(res and res.url, res and res.err or nil)
      end
    end)
  end
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
      if callback and type(callback) == "function" then
        callback(res and res.ok, res and res.err or nil)
      end
    end)
  end
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
  return { ok = ok, err = err }
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
      if res and res.ok and M.current and M.current.detail.number == num then
        M.current.detail.title = title
        M.current.detail.body = body
        local pull_request = require("lreview.storage.pull_request")
        local ok_storage = storage.open()
        if ok_storage then
          local key = (M.current and M.current.detail.provider) .. ":" .. (M.current and M.current.detail.repo) .. ":" .. num
          local cached = pull_request.get(key)
          if cached then
            cached.title = title
            cached.body = body
            pull_request.upsert(cached)
          end
        end
      end
      if callback and type(callback) == "function" then
        callback(res and res.ok, res and res.err or nil)
      end
    end)
  end
  update_worker:queue({ cwd = cwd, detail = M.current and M.current.detail, number = num, title = title, body = body })
  return false, nil
end

return M
