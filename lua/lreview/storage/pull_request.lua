---@meta

-- CRUD for the pull_requests table (MR/PR cache + detail).

local storage = require("lreview.storage")

local M = {}

--- Upsert an MR (list row or detail) into the cache.
---@param mr lreview.MR|lreview.MRDetail
function M.upsert(mr)
  storage.execute([[
    INSERT OR REPLACE INTO pull_requests
      (mo_id, provider, repo, number, title, author, state,
       source_branch, target_branch, description, base_sha, head_sha, url, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]],
    mr.mo_id, mr.provider, mr.repo, mr.number, mr.title, mr.author, mr.state,
    mr.source_branch, mr.target_branch, mr.description, mr.base_sha, mr.head_sha,
    mr.url, mr.updated_at)
end

--- Get an MR by mo_id.
---@param mo_id string
---@return table|nil
function M.get(mo_id)
  local rows = storage.query("SELECT * FROM pull_requests WHERE mo_id = ?", mo_id)
  return rows[1]
end

--- List MRs for a provider+repo.
---@param provider string
---@param repo string
---@return table[]
function M.list(provider, repo)
  return storage.query(
    "SELECT * FROM pull_requests WHERE provider = ? AND repo = ? ORDER BY number DESC",
    provider, repo
  )
end

--- Find an MR by source branch.
---@param provider string
---@param repo string
---@param branch string
---@return table|nil
function M.by_source_branch(provider, repo, branch)
  local rows = storage.query(
    "SELECT * FROM pull_requests WHERE provider = ? AND repo = ? AND source_branch = ?",
    provider, repo, branch
  )
  return rows[1]
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
--- FTS5 trigram index. Queries shorter than 3 chars fall back to LIKE.
--- Ranking: title prefix > title substring > number prefix.
---@param provider string  -- canonical name ("gitlab" | "github")
---@param repo string
---@param query string|nil
---@return table[]  -- { mo_id, provider, repo, number, title, state, url }[]
function M.search(provider, repo, query)
  if not query or query == "" then
    return M.list(provider, repo)
  end
  local q = query:lower()
  local rows
  if #q >= 3 then
    rows = storage.query([[
      SELECT p.mo_id, p.provider, p.repo, p.number, p.title, p.state, p.url
      FROM pull_requests_fts f
      JOIN pull_requests p ON p.rowid = f.rowid
      WHERE pull_requests_fts MATCH ? AND p.provider = ? AND p.repo = ?
    ]], fts_phrase(q), provider, repo)
  else
    rows = storage.query([[
      SELECT mo_id, provider, repo, number, title, state, url FROM pull_requests
      WHERE provider = ? AND repo = ? AND (CAST(number AS TEXT) LIKE ? OR title LIKE ?)
    ]], provider, repo, "%" .. q .. "%", "%" .. q .. "%")
  end
  local scored = {}
  for _, r in ipairs(rows or {}) do
    local title = (r.title or ""):lower()
    local num_str = tostring(r.number)
    local score
    if title:sub(1, #q) == q then
      score = 0 -- title prefix
    elseif title:find(q, 1, true) then
      score = 1 -- title substring
    elseif num_str:sub(1, #q) == q then
      score = 2 -- number prefix
    end
    if score then
      scored[#scored + 1] = { row = r, score = score }
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    return a.row.number > b.row.number
  end)
  local out = {}
  for _, s in ipairs(scored) do
    out[#out + 1] = {
      mo_id = s.row.mo_id,
      provider = s.row.provider,
      repo = s.row.repo,
      number = s.row.number,
      title = s.row.title,
      state = s.row.state,
      url = s.row.url,
    }
  end
  return out
end

return M
