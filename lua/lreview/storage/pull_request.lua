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

return M
