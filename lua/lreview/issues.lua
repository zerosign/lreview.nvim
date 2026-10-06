---@meta

-- Issue tracker access: pull, cache, search, and per-issue sync.
--
-- An MR description hints at *what* changed; the issue it links to says *why*.
-- This module keeps that context offline: the issue list is cached in SQLite
-- (storage/issues.lua) so "what is #123 about" is an indexed query, and a
-- single issue can be re-synced on demand without re-pulling the list.
--
-- Execution model (docs 09/12): every hub call runs on a `uv.new_work` worker
-- so the UI never blocks; storage writes stay on the main thread. Pages are
-- fetched SEQUENTIALLY — one queued job at a time — because progress is only
-- meaningful in order, and a short page is the end-of-list signal.

local adapter = require("lreview.adapter")
local thread = require("lreview.thread")
local storage = require("lreview.storage")
local issue_store = require("lreview.storage.issues")
local config = require("lreview.config")

local M = {}

-- Adapter CLI ids ("gh"/"glab") differ from the canonical provider names the
-- mappers store in rows ("github"/"gitlab"). Same mapping as pull_request.lua,
-- with the adapter's own name preferred so custom adapters key consistently.
local CANONICAL = { glab = "gitlab", gh = "github" }

--- Canonical provider name for a resolved context.
---@param resolved table
---@return string
function M.canonical(resolved)
  if resolved.adapter and resolved.adapter.name then
    return resolved.adapter.name
  end
  return CANONICAL[resolved.provider] or resolved.provider
end

M.WORKER_KEY = "issues.fetch"
M.WORKER_MODULE = "lreview.issues"

local in_flight = false

---@return table  -- { per_page, max_pages, stale_after_min }
local function issue_cfg()
  local d = config.get_defaults()
  local i = d.issues or {}
  return {
    per_page = i.per_page or 50,
    max_pages = i.max_pages or 20,
    stale_after_min = i.stale_after_min or 30,
  }
end

--- Worker-thread entry point: fetch ONE page.
---
--- Runs in an isolated Lua state: no closures, io.popen fallbacks for git/CLI,
--- and returns plain tables only (MessagePack cannot carry our class shapes).
--- Deliberately does NOT write to SQLite — the main thread owns the writes.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd, kind = "list"|"notes"|"issue", number, page, state, filter }
---@return table
function M.fetch_page_thread(db_path, lazy_sqlite, args)
  local kind = args.kind or "list"
  local resolved = adapter.resolve(args.cwd)
  if not resolved then
    return { ok = false, err = "no git remote detected", kind = kind, page = args.page or 1 }
  end
  if not adapter.supports(resolved, "issues") then
    return { ok = false, err = "active adapter has no issue tracker", kind = kind, page = args.page or 1 }
  end
  local ctx = adapter.ctx(resolved)
  local per_page = args.per_page or 50

  local log_ok, log = pcall(require, "lreview.log")
  if log_ok and log then
    log.debug("issues", string.format("fetch_page_thread start kind=%s page=%d per_page=%d",
      kind, args.page or 1, per_page), { repo = ctx and ctx.repo or "", cwd = args.cwd or "" })
  end

  if kind == "issue" then
    local ok, issue, err = pcall(resolved.adapter.get_issue, resolved.cfg, ctx, args.number)
    if not ok then
      if log_ok and log then log.error("issues", "get_issue exception: " .. tostring(issue)) end
      return { ok = false, err = tostring(issue) }
    end
    if not issue then
      if log_ok and log then log.warn("issues", "get_issue not found: " .. tostring(err)) end
      return { ok = false, err = err }
    end
    if log_ok and log then log.info("issues", string.format("get_issue #%d ok", args.number)) end
    return { ok = true, kind = kind, issue = issue }
  end

  if kind == "notes" then
    local ok, notes, err = pcall(resolved.adapter.fetch_issue_notes, resolved.cfg, ctx,
      args.number, { page = args.page or 1, per_page = per_page })
    if not ok then return { ok = false, err = tostring(notes) } end
    if not notes then return { ok = false, err = err } end
    return { ok = true, kind = kind, page = args.page or 1, notes = notes }
  end

  local ok, list, err = pcall(resolved.adapter.list_issues, resolved.cfg, ctx, {
    state = args.state or "open",
    page = args.page or 1,
    per_page = per_page,
    labels = args.labels,
    filter = args.filter,
    author = args.author,
    assignee = args.assignee,
  })
  if not ok then
    if log_ok and log then log.error("issues", "list_issues exception: " .. tostring(list)) end
    return { ok = false, err = tostring(list), kind = kind, page = args.page or 1 }
  end
  if not list then
    if log_ok and log then log.warn("issues", "list_issues error: " .. tostring(err)) end
    return { ok = false, err = err, kind = kind, page = args.page or 1 }
  end
  if log_ok and log then
    log.info("issues", string.format("list_issues page=%d ok, count=%d", args.page or 1, #list))
  end
  return { ok = true, kind = kind, page = args.page or 1, issues = list }
end

local worker = nil

local function has_threads()
  local uv = vim.uv or vim.loop
  return (uv and uv.new_work) ~= nil
end

local function ensure_worker()
  if worker then return end
  worker = thread.create_worker(M.WORKER_MODULE, "fetch_page_thread", function(res)
    -- One completion per queued job, FIFO; the driver keeps exactly one armed.
    thread.dispatch_cb(M.WORKER_KEY, res)
  end)
end

--- Queue one fetch job; `cb(res)` receives the raw worker payload.
--- Falls back to running the fetch on the main thread when libuv worker threads
--- are unavailable, so the page driver never stalls waiting for a completion
--- that can no longer fire.
local function queue_fetch(args, cb)
  if not has_threads() then
    cb(M.fetch_page_thread(config.get_defaults().db_path, "", args))
    return
  end
  ensure_worker()
  thread.arm(M.WORKER_KEY, cb)
  worker:queue(args)
end

--- Pull the issue list page by page, writing each page as it arrives.
---
---@param opts table|nil  -- { state = "open"|"closed"|"all", filter, labels, on_progress, on_done }
---@return boolean started, string|nil err
function M.pull_async(opts)
  opts = opts or {}
  if in_flight then
    return false, "an issue pull is already running"
  end
  local cwd = vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then
    return false, "no git remote detected"
  end
  if not adapter.supports(resolved, "issues") then
    return false, "active adapter has no issue tracker"
  end
  if not storage.open() then
    return false, "could not open the local review database"
  end

  local cfg = issue_cfg()
  local state = opts.state or "open"
  local total, page = 0, 0
  in_flight = true

  local log_ok, log = pcall(require, "lreview.log")
  if log_ok and log then
    log.info("issues", string.format("pull_async start repo=%s state=%s per_page=%d max_pages=%d",
      resolved.repo, state, cfg.per_page, cfg.max_pages))
  end

  local function finish(err)
    in_flight = false
    if err then
      if log_ok and log then log.error("issues", "pull_async error: " .. tostring(err)) end
      vim.notify("lreview: " .. tostring(err), vim.log.levels.ERROR)
    else
      issue_store.mark_synced(M.canonical(resolved), resolved.repo, state)
      if log_ok and log then log.info("issues", string.format("pull_async complete: cached %d issue(s) (%s)", total, state)) end
      vim.notify(string.format("lreview: cached %d issue(s) (%s)", total, state), vim.log.levels.INFO)
    end
    if opts.on_done then opts.on_done(err == nil, total, err) end
  end

  local function step()
    page = page + 1
    if page > cfg.max_pages then
      finish()
      return
    end
    queue_fetch({
      cwd = cwd, kind = "list", page = page, per_page = cfg.per_page,
      state = state, filter = opts.filter, labels = opts.labels,
      author = opts.author, assignee = opts.assignee,
    }, function(res)
      if not res or not res.ok then
        in_flight = false
        finish((res and res.err) or "failed to fetch issues")
        return
      end
      local rows = res.issues or {}
      local written, werr = issue_store.upsert_many(rows)
      if werr then
        in_flight = false
        finish("failed to cache page " .. tostring(page) .. ": " .. werr)
        return
      end
      total = total + written
      if log_ok and log then
        log.info("issues", string.format("pull_async page %d: received %d rows, wrote %d (total=%d)",
          page, #rows, written, total))
      end
      if opts.on_progress then opts.on_progress(page, total) end
      vim.notify(string.format("lreview: issues page %d (%d cached)", page, total), vim.log.levels.DEBUG)
      -- A short page is the end-of-list signal; anything else means more pages.
      if #rows < cfg.per_page then
        finish()
      else
        step()
      end
    end)
  end

  vim.notify(string.format("lreview: pulling %s issues...", state), vim.log.levels.INFO)
  step()
  return true, nil
end

--- Pull a single issue and its discussion, replacing the cached copy.
---@param number integer
---@param on_done fun(ok: boolean, issue: table|nil, err: string|nil)|nil
---@return boolean started, string|nil err
function M.pull_one_async(number, on_done)
  local cwd = vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then return false, "no git remote detected" end
  if not storage.open() then return false, "could not open the local review database" end

  local cfg = issue_cfg()
  local provider, repo = M.canonical(resolved), resolved.repo
  local notes = {}

  local function notes_step(page)
    queue_fetch({ cwd = cwd, kind = "notes", number = number, page = page, per_page = 100 }, function(res)
      local issue = issue_store.by_number(provider, repo, number)
      if not res or not res.ok then
        -- Notes are best-effort: the issue row we already cached stays valid.
        if res and res.err then
          vim.notify("lreview: could not fetch discussion: " .. tostring(res.err), vim.log.levels.WARN)
        end
        if #notes > 0 and issue then issue_store.replace_notes(issue.issue_id, notes) end
        if on_done then on_done(true, issue, nil) end
        return
      end
      for _, n in ipairs(res.notes or {}) do notes[#notes + 1] = n end
      if #(res.notes or {}) < 100 then
        if issue then issue_store.replace_notes(issue.issue_id, notes) end
        if on_done then on_done(true, issue, nil) end
      else
        notes_step(page + 1)
      end
    end)
  end

  queue_fetch({ cwd = cwd, kind = "issue", number = number }, function(res)
    if not res or not res.ok or not res.issue then
      if on_done then on_done(false, nil, (res and res.err) or "issue not found") end
      return
    end
    issue_store.upsert(res.issue)
    notes_step(1)
  end)
  return true, nil
end

--- Ensure the cached list exists (and is not older than the TTL), then continue.
---@param opts table|nil  -- { state, force, on_done = fun(ok: boolean, err: string|nil) }
function M.ensure_fresh_async(opts)
  opts = opts or {}
  local done = opts.on_done
  local cwd = vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then
    if done then done(false, "no git remote detected") end
    return
  end
  local cfg = issue_cfg()
  local state = opts.state or "open"
  if not opts.force
      and not issue_store.is_stale(M.canonical(resolved), resolved.repo, state, cfg.stale_after_min) then
    if done then done(true, nil) end
    return
  end

  local pull_opts = vim.tbl_extend("force", opts, {
    state = state,
    -- pull_async owns its own summary notify; forward only completion.
    on_done = function(ok, _total, err)
      if done then done(ok, err) end
    end,
  })
  M.pull_async(pull_opts)
end

--- Pull a single issue if it is missing from the cache, then hand it over.
---@param number integer
---@param on_ready fun(issue: table|nil, err: string|nil)
function M.with_issue(number, on_ready)
  local cwd = vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then
    on_ready(nil, "no git remote detected")
    return
  end
  local cached = issue_store.by_number(M.canonical(resolved), resolved.repo, number)
  if cached then
    on_ready(cached, nil)
    return
  end
  M.pull_one_async(number, function(ok, issue, err)
    on_ready(ok and issue or nil, err)
  end)
end

--- Cached issues for this repo (no network).
---@param opts table|nil  -- { state, query }
---@return table[]
function M.list(opts)
  opts = opts or {}
  local cwd = vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then return {} end
  if not storage.open() then return {} end
  local provider = M.canonical(resolved)
  if opts.query and opts.query ~= "" then
    return issue_store.search(provider, resolved.repo, opts.query, { state = opts.state })
  end
  return issue_store.list(provider, resolved.repo, { state = opts.state })
end

--- Cached discussion for an issue (no network).
---@param issue_id string
---@param opts table|nil
---@return table[]
function M.notes(issue_id, opts)
  return issue_store.notes_for(issue_id, opts)
end

--- Resolve "what is this number about" for the ACTIVE review's repo. Used by
--- MR-description correlation (#123 / !45 links) without any round trip.
---@param provider string
---@param repo string
---@param number integer|string
---@return table|nil
function M.lookup(provider, repo, number)
  if not storage.open() then return nil end
  return issue_store.by_number(provider, repo, number)
end

M.store = issue_store

return M
