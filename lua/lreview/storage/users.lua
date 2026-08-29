-- Repo users storage: cached members/collaborators for @mention completion.
--
-- repo_key is "<provider>:<repo>" (e.g. "gitlab:zerodevs/sample-review").
-- Users are fetched on demand via :LocalReviewPullUser and cached here.

local storage = require("lreview.storage")

local M = {}

--- Upsert a repo user.
---@param repo_key string  -- "<provider>:<repo>"
---@param user table       -- { username, name, avatar_url }
---@param fetched_at string
function M.upsert(repo_key, user, fetched_at)
  storage.execute([[
    INSERT OR REPLACE INTO repo_users (repo_key, username, name, avatar_url, fetched_at)
    VALUES (?, ?, ?, ?, ?)
  ]], repo_key, user.username, user.name, user.avatar_url, fetched_at)
end

--- List cached users for a repo key.
---@param repo_key string
---@return table[]  -- { username, name, avatar_url }[]
function M.list(repo_key)
  local rows = storage.query([[
    SELECT username, name, avatar_url FROM repo_users
    WHERE repo_key = ?
    ORDER BY username
  ]], repo_key)
  local out = {}
  for _, r in ipairs(rows or {}) do
    out[#out + 1] = {
      username = r.username,
      name = r.name,
      avatar_url = r.avatar_url,
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
--- trigram index. Queries shorter than 3 chars fall back to LIKE (the
--- trigram tokenizer cannot index 1-2 char tokens).
--- Ranking: username prefix > username substring > full-name substring.
---@param repo_key string
---@param query string|nil
---@return table[]  -- { username, name, avatar_url }[]
function M.search(repo_key, query)
  if not query or query == "" then
    return M.list(repo_key)
  end
  local q = query:lower()
  local rows
  if #q >= 3 then
    rows = storage.query([[
      SELECT r.username, r.name, r.avatar_url
      FROM repo_users_fts f
      JOIN repo_users r ON r.rowid = f.rowid
      WHERE repo_users_fts MATCH ? AND r.repo_key = ?
    ]], fts_phrase(q), repo_key)
  else
    rows = storage.query([[
      SELECT username, name, avatar_url FROM repo_users
      WHERE repo_key = ? AND (username LIKE ? OR name LIKE ?)
    ]], repo_key, "%" .. q .. "%", "%" .. q .. "%")
  end
  local scored = {}
  for _, r in ipairs(rows or {}) do
    local uname = (r.username or ""):lower()
    local name = (r.name or ""):lower()
    local score
    if uname:sub(1, #q) == q then
      score = 0 -- username prefix
    elseif uname:find(q, 1, true) then
      score = 1 -- username substring
    elseif name:find(q, 1, true) then
      score = 2 -- full-name substring
    end
    if score then
      scored[#scored + 1] = { row = r, score = score }
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    return (a.row.username or "") < (b.row.username or "")
  end)
  local out = {}
  for _, s in ipairs(scored) do
    out[#out + 1] = {
      username = s.row.username,
      name = s.row.name,
      avatar_url = s.row.avatar_url,
    }
  end
  return out
end

return M