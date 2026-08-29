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

--- Fetch repo users asynchronously in a headless nvim job (non-blocking).
--- The job prints a JSON result { n = count, e = err } to stdout.
---@param callback fun(success: boolean, count: integer|nil, err: string|nil)|nil
---@return boolean, string|nil
function M.pull_users_async(callback)
  local cwd = vim.fn.getcwd()
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1).source:match("@(.*)$"), ":h:h:h")
  local cmd = {
    vim.v.progpath,
    "--headless",
    "--cmd",
    "set runtimepath^=" .. vim.fn.escape(plugin_root, " "),
    "-c",
    string.format(
      "lua local n,e=require('lreview').api.fetch_users(%q); io.write(vim.json.encode({n=n,e=e}))",
      cwd
    ),
    "-c",
    "qa"
  }
  vim.system(cmd, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      local data = nil
      if res.stdout then
        local okd, decoded = pcall(vim.json.decode, res.stdout)
        if okd then
          data = decoded
        end
      end
      if callback then
        if data and data.n ~= nil then
          callback(true, data.n, nil)
        else
          callback(false, nil, data and data.e or "failed to fetch repo users")
        end
      end
    end)
  end)
  return true, nil
end

return M