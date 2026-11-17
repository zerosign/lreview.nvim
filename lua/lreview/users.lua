---@meta

-- Repo users: fetch (async), cache, and search repo members/collaborators.
--
--   :LocalReviewPullUser -> pull_users_async() -> headless nvim job
--     -> fetch_users(cwd) -> adapter.list_users() -> storage upsert
--
--   scratchpad @mention  -> search_users(cwd, prefix)

local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local repo_users = require("lreview.storage.users")
local thread = require("lreview.thread")

local M = {}

--- Resolve the repo_key ("<provider>:<repo>") for a directory.
---@param cwd string|nil
---@return string|nil repo_key, string|nil err
local function repo_key_for(cwd)
  local resolved = adapter.resolve(cwd or vim.fn.getcwd())
  if not resolved then
    return nil, "no git remote detected"
  end
  return resolved.provider .. ":" .. resolved.repo, nil
end

--- Fetch repo users from the platform and cache them locally.
--- Runs in a headless nvim job via pull_users_async; no active review needed.
---@param cwd string|nil
---@return integer|nil count, string|nil err
function M.fetch_users(cwd)
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
  local users, err = resolved.adapter.list_users(resolved.cfg, ctx)
  if not users then
    return nil, err
  end
  local repo_key = resolved.provider .. ":" .. resolved.repo
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  for _, u in ipairs(users) do
    repo_users.upsert(repo_key, u, now)
  end
  return #users, nil
end

--- List cached users for the current repo.
---@param cwd string|nil
---@return table[]  -- { username, name, avatar_url }[]
function M.list_users(cwd)
  local repo_key = repo_key_for(cwd)
  if not repo_key then
    return {}
  end
  local ok = storage.open()
  if not ok then
    return {}
  end
  return repo_users.list(repo_key)
end

--- Search cached users by prefix/substring (case-insensitive) via the FTS5
--- trigram index (LIKE fallback for < 3 char queries).
--- Ranking: username prefix > username substring > full-name substring.
---@param cwd string|nil
---@param query string|nil
---@return table[]  -- { username, name, avatar_url }[]
function M.search_users(cwd, query)
  local repo_key = repo_key_for(cwd)
  if not repo_key then
    return {}
  end
  local ok = storage.open()
  if not ok then
    return {}
  end
  return repo_users.search(repo_key, query)
end

--- Worker thread entry point for pull_users_async.
---@param db_path string
---@param lazy_sqlite string
---@param args table  -- { cwd }
---@return table
function M.fetch_users_thread(db_path, lazy_sqlite, args)
  local resolved = adapter.resolve(args and args.cwd or nil)
  if not resolved then
    return { ok = false, err = "no git remote detected" }
  end
  local ctx = adapter.ctx(resolved)
  local users, err = resolved.adapter.list_users(resolved.cfg, ctx)
  if not users then
    return { ok = false, err = err }
  end
  local repo_key = resolved.provider .. ":" .. resolved.repo
  return { ok = true, repo_key = repo_key, users = users }
end

--- Fetch repo users asynchronously via a background worker thread (non-blocking).
---@param callback fun(success: boolean, count: integer|nil, err: string|nil)|nil
---@return boolean, string|nil
function M.pull_users_async(callback)
  local cwd = vim.fn.getcwd()
  thread.run_task(
    "users.pull",
    "lreview.users",
    "fetch_users_thread",
    { cwd = cwd },
    callback,
    function(res, slot_cb)
      if res and res.ok and res.users then
        local ok = storage.open()
        if ok then
          local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
          for _, u in ipairs(res.users) do
            repo_users.upsert(res.repo_key, u, now)
          end
        end
        if slot_cb then slot_cb(true, #res.users, nil) end
      else
        if slot_cb then slot_cb(false, nil, res and res.err or "failed to fetch repo users") end
      end
    end
  )
  return true, nil
end

return M