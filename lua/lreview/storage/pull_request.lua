-- CRUD for the pull_requests table (MR/PR cache + detail).
--
-- Flat index columns (queried/indexed):
--   title      -> FTS5 trigram search
--   state      -> GC filter (merged/closed)
--   updated_at -> GC date threshold
--
-- MessagePack payload (display-only metadata):
--   author, source_branch, target_branch, description,
--   base_sha, head_sha, url, remote_updated_at

local storage = require("lreview.storage")
local mpack = vim.mpack

local M = {}

local function decode_mr(row)
  if not row then return nil end
  local payload = row.payload and mpack.decode(row.payload) or {}
  row.payload = nil
  for k, v in pairs(payload) do
    row[k] = v
  end
  return row
end

--- Upsert an MR (list row or detail) into the cache.
---@param mr lreview.MR|lreview.MRDetail
function M.upsert(mr)
  -- Flat indexed columns for fast SQL filtering and FTS5 search.
  local title = mr.title
  local state = mr.state
  local updated_at = mr.updated_at

  -- Everything else goes into the MessagePack payload.
  local payload = {
    author = mr.author,
    source_branch = mr.source_branch,
    target_branch = mr.target_branch,
    description = mr.description,
    base_sha = mr.base_sha,
    head_sha = mr.head_sha,
    url = mr.url,
    remote_updated_at = mr.remote_updated_at or mr.updated_at,
  }

  storage.execute([[
    INSERT OR REPLACE INTO pull_requests
      (mo_id, provider, repo, number, title, state, updated_at, payload)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ]], mr.mo_id, mr.provider, mr.repo, mr.number,
      title, state, updated_at, mpack.encode(payload))
end

--- Get an MR by mo_id.
---@param mo_id string
---@return table|nil
function M.get(mo_id)
  local rows = storage.query("SELECT * FROM pull_requests WHERE mo_id = ?", mo_id)
  return decode_mr(rows[1])
end

--- List MRs for a provider+repo.
---@param provider string
---@param repo string
---@return table[]
function M.list(provider, repo)
  local rows = storage.query(
    "SELECT * FROM pull_requests WHERE provider = ? AND repo = ? ORDER BY number DESC",
    provider, repo
  )
  for i, r in ipairs(rows) do
    rows[i] = decode_mr(r)
  end
  return rows
end

--- Find an MR by source branch.
---@param provider string
---@param repo string
---@param branch string
---@return table|nil
function M.by_source_branch(provider, repo, branch)
  local list = M.list(provider, repo)
  for _, mr in ipairs(list) do
    if mr.source_branch == branch then
      return mr
    end
  end
  return nil
end

--- Delete an MR and its dependent threads/comments/reviews.
---@param mo_id string
function M.delete(mo_id)
  storage.execute("DELETE FROM comments WHERE t_id IN (SELECT t_id FROM threads WHERE mo_id = ?)", mo_id)
  storage.execute("DELETE FROM threads WHERE mo_id = ?", mo_id)
  storage.execute("DELETE FROM reviews WHERE mo_id = ?", mo_id)
  storage.execute("DELETE FROM pull_requests WHERE mo_id = ?", mo_id)
end

--- Escape a string for use inside an FTS5 phrase query (doubles quotes).
---@param q string
---@return string
local function fts_phrase(q)
  return '"' .. q:gsub('"', '""') .. '"'
end

--- Search cached MRs by number/title substring (case-insensitive) using the
--- FTS5 trigram index on flat columns. Queries shorter than 3 chars fall back
--- to Lua filtering.
--- Ranking: title prefix > title substring > number prefix.
---@param provider string  -- canonical name ("gitlab" | "github")
---@param repo string
---@param query string|nil
---@return table[]
function M.search(provider, repo, query)
  if not query or query == "" then
    return M.list(provider, repo)
  end
  local q = query:lower()
  local rows

  if #q >= 3 then
    -- FTS5 searches flat `title` and `number` columns directly.
    rows = storage.query([[
      SELECT p.*
      FROM pull_requests_fts f
      JOIN pull_requests p ON p.rowid = f.rowid
      WHERE pull_requests_fts MATCH ? AND p.provider = ? AND p.repo = ?
    ]], fts_phrase(q), provider, repo)
    for i, r in ipairs(rows) do
      rows[i] = decode_mr(r)
    end
  else
    local all = M.list(provider, repo)
    rows = {}
    for _, mr in ipairs(all) do
      if tostring(mr.number):find(q, 1, true)
          or (mr.title and mr.title:lower():find(q, 1, true)) then
        rows[#rows + 1] = mr
      end
    end
  end

  local scored = {}
  for _, mr in ipairs(rows or {}) do
    local title = (mr.title or ""):lower()
    local num_str = tostring(mr.number)
    local score
    if title:sub(1, #q) == q then
      score = 0
    elseif title:find(q, 1, true) then
      score = 1
    elseif num_str:sub(1, #q) == q then
      score = 2
    end
    if score then
      scored[#scored + 1] = { row = mr, score = score }
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return a.row.number > b.row.number
  end)

  local out = {}
  for _, s in ipairs(scored) do
    out[#out + 1] = s.row
  end
  return out
end

return M
