---@meta

-- Repo MR/PR list: fetch (async), cache, and search pull requests for link
-- autocomplete.
--
--   :LocalReviewPullRequest -> pull_async() -> headless nvim job
--     -> fetch(cwd) -> adapter.list_pull_requests() -> pull_requests upsert
--
--   scratchpad !123/#123 -> search(cwd, query)

local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local thread = require("lreview.thread")

local M = {}

-- Adapter provider ids ("glab"/"gh") differ from the canonical provider names
-- stored in pull_requests.provider ("gitlab"/"github"). Map between them.
local CANONICAL = { glab = "gitlab", gh = "github" }

--- Canonical provider name ("gitlab" | "github") for a resolved context.
---@param resolved table
---@return string
local function canonical_provider(resolved)
  return CANONICAL[resolved.provider] or resolved.provider
end

--- Fetch the open MR/PR list from the platform and cache it locally.
--- Runs in a headless nvim job via pull_async; no active review needed.
---@param cwd string|nil
---@return integer|nil count, string|nil err
function M.fetch(cwd)
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p")
  if cwd:sub(-1) == "/" or cwd:sub(-1) == "\\" then
    cwd = cwd:sub(1, -2)
  end
  local resolved = adapter.resolve(cwd)
  if not resolved then
    return nil, "no git remote detected"
  end
  local ok, oerr = storage.open()
  if not ok then
    return nil, oerr
  end
  local ctx = adapter.ctx(resolved)
  local prs, err = resolved.adapter.list_pull_requests(resolved.cfg, ctx, { scope = "all" })
  if not prs then
    return nil, err
  end
  for _, mr in ipairs(prs) do
    pull_request.upsert(mr)
  end
  return #prs, nil
end

--- List cached pull requests for the current repo (newest first).
---@param cwd string|nil
---@return table[]  -- { mo_id, provider, repo, number, title, state, url }[]
function M.list(cwd)
  local resolved = adapter.resolve(cwd or vim.fn.getcwd())
  if not resolved then
    return {}
  end
  local ok = storage.open()
  if not ok then
    return {}
  end
  local provider = canonical_provider(resolved)
  local pr_storage = require("lreview.storage.pull_request")
  local rows = pr_storage.list(provider, resolved.repo)
  local out = {}
  for _, r in ipairs(rows or {}) do
    out[#out + 1] = {
      mo_id = r.mo_id,
      provider = r.provider,
      repo = r.repo,
      number = r.number,
      title = r.title,
      state = r.state,
      url = r.url,
    }
  end
  return out
end

--- Search cached pull requests by number/title substring (case-insensitive) via
--- the FTS5 trigram index (LIKE fallback for < 3 char queries).
--- Ranking: title prefix > title substring > number prefix.
---@param cwd string|nil
---@param query string|nil
---@return table[]
function M.search(cwd, query)
  local resolved = adapter.resolve(cwd or vim.fn.getcwd())
  if not resolved then
    return {}
  end
  local ok = storage.open()
  if not ok then
    return {}
  end
  return pull_request.search(canonical_provider(resolved), resolved.repo, query)
end

--- Worker thread entry point for pull_async.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd }
---@return table
function M.fetch_pull_requests_thread(db_path, lazy_sqlite, args)
  local resolved = adapter.resolve(args and args.cwd or nil)
  if not resolved then
    return { ok = false, err = "no git remote detected" }
  end
  local ctx = adapter.ctx(resolved)
  local prs, err = resolved.adapter.list_pull_requests(resolved.cfg, ctx, { scope = "all" })
  if not prs then
    return { ok = false, err = err }
  end
  return { ok = true, prs = prs }
end

--- Fetch the pull request list asynchronously via a background worker thread (non-blocking).
---@param callback fun(success: boolean, count: integer|nil, err: string|nil)|nil
---@return boolean, string|nil
function M.pull_async(callback)
  local cwd = vim.fn.getcwd()
  thread.run_task(
    "pull_request.pull",
    "lreview.pull_request",
    "fetch_pull_requests_thread",
    { cwd = cwd },
    callback,
    function(res, slot_cb)
      if res and res.ok and res.prs then
        local ok = storage.open()
        if ok then
          for _, mr in ipairs(res.prs) do
            pull_request.upsert(mr)
          end
        end
        if slot_cb then slot_cb(true, #res.prs, nil) end
      else
        if slot_cb then slot_cb(false, nil, res and res.err or "failed to fetch pull request list") end
      end
    end
  )
  return true, nil
end

return M

