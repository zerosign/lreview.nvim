-- Repo users storage: cached members/collaborators for @mention completion.
--
-- repo_key is "<provider>:<repo>" (e.g. "gitlab:zerodevs/sample-review").
-- Users are fetched on demand via :LocalReviewPullUser and cached here.
--
-- Flat index columns (queried/indexed):
--   username, name -> FTS5 trigram search
--
-- MessagePack payload (display-only metadata):
--   avatar_url, fetched_at

local storage = require("lreview.storage")
local mpack = vim.mpack

local M = {}

--- Upsert a repo user.
---@param repo_key string  -- "<provider>:<repo>"
---@param user table       -- { username, name, avatar_url }
---@param fetched_at string
function M.upsert(repo_key, user, fetched_at)
  local payload = {
    avatar_url = user.avatar_url,
    fetched_at = fetched_at,
  }
  storage.execute([[
    INSERT OR REPLACE INTO repo_users (repo_key, username, name, payload)
    VALUES (?, ?, ?, ?)
  ]], repo_key, user.username, user.name, mpack.encode(payload))
end

--- List cached users for a repo key.
---@param repo_key string
---@return table[]  -- { username, name, avatar_url }[]
function M.list(repo_key)
  local rows = storage.query([[
    SELECT username, name, payload FROM repo_users
    WHERE repo_key = ?
    ORDER BY username
  ]], repo_key)
  local out = {}
  for _, r in ipairs(rows or {}) do
    local p = r.payload and mpack.decode(r.payload) or {}
    out[#out + 1] = {
      username = r.username,
      name = r.name,
      avatar_url = p.avatar_url,
    }
  end
  return out
end

--- Delete all cached users for a repo key.
---@param repo_key string
function M.clear(repo_key)
  storage.execute("DELETE FROM repo_users WHERE repo_key = ?", repo_key)
end

--- Escape a string for use inside an FTS5 phrase query (doubles quotes).
---@param q string
---@return string
local function fts_phrase(q)
  return '"' .. q:gsub('"', '""') .. '"'
end

--- Search cached users by substring (case-insensitive) using the FTS5
--- trigram index on flat `username` and `name` columns.
--- Queries shorter than 3 chars fall back to Lua filtering.
--- Ranking: username prefix > username substring > full-name substring.
---@param repo_key string
---@param query string|nil
---@return table[]  -- { username, name, avatar_url }[]
function M.search(repo_key, query)
  if not query or query == "" then
    return M.list(repo_key)
  end
  local q = query:lower()
  local candidates

  if #q >= 3 then
    -- FTS5 searches flat `username` and `name` columns directly.
    local rows = storage.query([[
      SELECT r.username, r.name, r.payload
      FROM repo_users_fts f
      JOIN repo_users r ON r.rowid = f.rowid
      WHERE repo_users_fts MATCH ? AND r.repo_key = ?
    ]], fts_phrase(q), repo_key)
    candidates = {}
    for _, r in ipairs(rows or {}) do
      local p = r.payload and mpack.decode(r.payload) or {}
      candidates[#candidates + 1] = {
        username = r.username,
        name = r.name,
        avatar_url = p.avatar_url,
      }
    end
  else
    -- Short query: Lua-side filter over the full list.
    local all = M.list(repo_key)
    candidates = {}
    for _, u in ipairs(all) do
      if u.username:lower():find(q, 1, true)
          or (u.name and u.name:lower():find(q, 1, true)) then
        candidates[#candidates + 1] = u
      end
    end
  end

  local scored = {}
  for _, u in ipairs(candidates) do
    local uname = u.username:lower()
    local name = (u.name or ""):lower()
    local score
    if uname:sub(1, #q) == q then
      score = 0
    elseif uname:find(q, 1, true) then
      score = 1
    elseif name:find(q, 1, true) then
      score = 2
    end
    if score then
      scored[#scored + 1] = { row = u, score = score }
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return a.row.username < b.row.username
  end)

  local out = {}
  for _, s in ipairs(scored) do
    out[#out + 1] = s.row
  end
  return out
end

return M