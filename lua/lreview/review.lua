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
local submit = require("lreview.review.submit")
local reconcile = require("lreview.review.reconcile")

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

M.compute_change_set = submit.compute_change_set
M.reply_parent = submit.reply_parent
M.build_ops = submit.build_ops
M._submit_pushes = submit.submit_pushes

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
  local can_request_changes = adapter.supports(resolved, "request_changes")
  local can_approve = adapter.supports(resolved, "approve_mr")
  local confirm_ui = require("lreview.ui.confirm")

  if vim.g.lreview_test_mode then
    done("COMMENT", false)
    return
  end

  confirm_ui.ask_confirmation(lines, {
    has_verdict = has_verdict,
    can_request_changes = can_request_changes,
    can_approve = can_approve,
  }, function(choice)
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
  return thread.with_worker_db(db_path, lazy_sqlite, function()
    local old_current = M.current
    if args and args.cwd and args.detail then
      M.current = { cwd = args.cwd, detail = args.detail }
    end

    -- Resolve adapter on thread (uses io.popen fallback for git commands).
    local resolved = adapter.resolve(M.current.cwd)
    if not resolved then
      M.current = old_current
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

    return {
      ok = (err == nil),
      count = count or 0,
      err = err,
      remaining = remaining or 0,
      notifications = notifications,
    }
  end)
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

    -- Always refresh review UI so open thread views, diff signs, and summary panels
    -- are updated regardless of whether submit succeeded completely or partially.
    refresh_review_ui()

    if not success and err then
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
      refresh_review_ui()
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

M._fetch_remote_threads = reconcile.fetch_remote_threads

--- Reconcile remote threads into local storage (batched, O(n)).
--- Pure DB work — no network calls. Separated from fetch so both
--- sync_review and submit_review_thread can share it.
---@param detail lreview.MRDetail
---@param remote_threads table[]
---@return integer synced  -- number of remote threads processed
function M._reconcile_threads(detail, remote_threads)
  return reconcile.reconcile_threads(detail, remote_threads, notify)
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
  return thread.with_worker_db(db_path, lazy_sqlite, function()
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

    if err then
      return { ok = false, err = err, notifications = notifications }
    end
    return { ok = true, count = count, notifications = notifications }
  end)
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
  return thread.with_worker_db(db_path, lazy_sqlite, function(db)
    local old_current = M.current
    if args and args.cwd and args.detail then
      M.current = { cwd = args.cwd, detail = args.detail }
    end

    local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
    local resolved = adapter.resolve(M.current.cwd)
    if not resolved then
      M.current = old_current
      return { ok = false, err = "no git remote detected" }
    end
    local ctx = adapter.ctx(resolved, num)
    local ok, err = resolved.adapter.close_mr(resolved.cfg, ctx, num)

    M.current = old_current
    return { ok = ok, err = err, number = num }
  end)
end

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

  thread.run_task("review.close", "lreview.review", "close_review_thread",
    { cwd = cwd, detail = detail, number = num },
    callback,
    function(res)
      if res and res.ok then
        local pull_request_storage = require("lreview.storage.pull_request")
        local pr_detail = M.current and M.current.detail
        if pr_detail and pr_detail.mo_id then
          pull_request_storage.update_state(pr_detail.mo_id, "closed")
        end
      end
    end)
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
  return thread.with_worker_db(db_path, lazy_sqlite, function(db)
    local old_current = M.current
    if args and args.cwd and args.detail then
      M.current = { cwd = args.cwd, detail = args.detail }
    end

    local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
    local resolved = adapter.resolve(M.current.cwd)
    if not resolved then
      M.current = old_current
      return { ok = false, err = "no git remote detected" }
    end
    local ctx = adapter.ctx(resolved, num)
    local ok, err = resolved.adapter.approve_mr(resolved.cfg, ctx, num)

    M.current = old_current
    return { ok = ok, err = err, number = num }
  end)
end

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

  thread.run_task("review.approve", "lreview.review", "approve_review_thread",
    { cwd = cwd, detail = detail, number = num },
    callback,
    function(res)
      if res and res.ok then
        local pull_request_storage = require("lreview.storage.pull_request")
        local pr_detail = M.current and M.current.detail
        if pr_detail and pr_detail.mo_id then
          pull_request_storage.update_state(pr_detail.mo_id, "approved")
        end
      end
    end)
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
  return thread.with_worker_db(db_path, lazy_sqlite, function()
    local old_current = M.current
    if args and args.cwd and args.detail then
      M.current = { cwd = args.cwd, detail = args.detail }
    end

    local resolved = adapter.resolve(M.current.cwd)
    if not resolved then
      M.current = old_current
      return { ok = false, err = "no git remote detected" }
    end
    local ctx = adapter.ctx(resolved, M.current.detail.number)
    local ok, err = resolved.adapter.resolve_thread(
      resolved.cfg, ctx, M.current.detail.number, args.thread_id, args.resolved_val)

    M.current = old_current
    -- Echo which thread this result belongs to: the completion closure is shared
    -- across all calls, so it must not use a captured `thread_id`.
    return { ok = ok, err = err, thread_id = args.thread_id, resolved_val = args.resolved_val }
  end)
end

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

  return thread.run_task(
    "review.resolve_thread",
    "lreview.review",
    "resolve_thread_thread",
    { cwd = cwd, detail = detail, thread_id = thread_id, resolved_val = resolved_val },
    callback,
    function(res, slot_cb)
      if res and res.ok and res.thread_id then
        comments.resolve_thread(res.thread_id, res.resolved_val == true)
      end
      if slot_cb then slot_cb(res and res.ok, res and res.err or nil) end
    end
  )
end

--- Thread-entry point for create_review_async.
--- Runs the MR/PR create CLI call on a uv.new_work worker.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, opts }
---@return table
function M.create_review_thread(db_path, lazy_sqlite, args)
  return thread.with_worker_db(db_path, lazy_sqlite, function()
    if args and args.cwd then
      M.current = { cwd = args.cwd, detail = M.current and M.current.detail }
    end
    local resolved = adapter.resolve(args.cwd)
    if not resolved then
      return { ok = false, err = "no git remote detected" }
    end
    local ctx = adapter.ctx(resolved)
    local url, err = resolved.adapter.create_mr(resolved.cfg, ctx, args.opts)
    return { ok = (url ~= nil), url = url, err = err }
  end)
end

--- Create a new MR/PR on the platform without blocking the UI.
---@param opts table  -- { title, body, source_branch, target_branch, template }
---@param cwd string|nil
---@param callback fun(url: string|nil, err: string|nil)|nil
---@return boolean, string|nil  -- false, nil when queued (async)
function M.create_review_async(opts, cwd, callback)
  cwd = cwd or (M.current and M.current.cwd) or vim.fn.getcwd()
  return thread.run_task(
    "review.create",
    "lreview.review",
    "create_review_thread",
    { cwd = cwd, opts = opts },
    callback,
    function(res, slot_cb)
      if slot_cb then slot_cb(res and res.url, res and res.err or nil) end
    end
  )
end

--- Thread-entry point for request_reviewers_async.
--- Runs the reviewer-assignment CLI call on a uv.new_work worker.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, number, reviewers }
---@return table
function M.request_reviewers_thread(db_path, lazy_sqlite, args)
  return thread.with_worker_db(db_path, lazy_sqlite, function()
    local old_current = M.current
    if args and args.cwd and args.detail then
      M.current = { cwd = args.cwd, detail = args.detail }
    end
    local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
    local resolved = adapter.resolve(args.cwd)
    if not resolved then
      M.current = old_current
      return { ok = false, err = "no git remote detected" }
    end
    if not adapter.supports(resolved, "assign_reviewers") then
      M.current = old_current
      return { ok = false, err = "reviewer assignment capability is not supported by active adapter" }
    end
    local ctx = adapter.ctx(resolved, num)
    local ok, err = resolved.adapter.assign_reviewers(resolved.cfg, ctx, num, args.reviewers)

    M.current = old_current
    return { ok = ok, err = err }
  end)
end

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

  return thread.run_task(
    "review.request_reviewers",
    "lreview.review",
    "request_reviewers_thread",
    {
      cwd = cwd,
      detail = M.current and M.current.detail,
      number = num,
      reviewers = reviewers,
    },
    callback,
    function(res, slot_cb)
      if slot_cb then slot_cb(res and res.ok, res and res.err or nil) end
    end
  )
end

--- Thread-entry point for update_review_async.
--- Runs the MR/PR update CLI call on a uv.new_work worker.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, number, title, body }
---@return table
function M.update_review_thread(db_path, lazy_sqlite, args)
  return thread.with_worker_db(db_path, lazy_sqlite, function()
    local old_current = M.current
    if args and args.cwd and args.detail then
      M.current = { cwd = args.cwd, detail = args.detail }
    end
    local num = args and args.number or (M.current and M.current.detail and M.current.detail.number)
    local resolved = adapter.resolve(args.cwd)
    if not resolved then
      M.current = old_current
      return { ok = false, err = "no git remote detected" }
    end
    local ctx = adapter.ctx(resolved, num)
    local ok, err = resolved.adapter.update_mr(resolved.cfg, ctx, num, args.title, args.body)

    M.current = old_current
    -- Echo the edited fields: the completion closure is shared across all calls,
    -- so reading captured upvalues would write a PREVIOUS edit into the cache.
    return { ok = ok, err = err, number = num, title = args.title, body = args.body }
  end)
end

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

  return thread.run_task(
    "review.update",
    "lreview.review",
    "update_review_thread",
    { cwd = cwd, detail = M.current and M.current.detail, number = num, title = title, body = body },
    callback,
    function(res, slot_cb)
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
      if slot_cb then slot_cb(res and res.ok, res and res.err or nil) end
    end
  )
end

return M
