---@meta

-- Mappers: convert foreign platform JSON shapes into the unified forge model.
--
-- Each mapper is a pure function (json table -> forge model table) so it can be
-- unit-tested in isolation against captured fixtures.

local model = require("lreview.model")

local M = {}

-- ===========================================================================
-- GitHub (gh) mappers
-- ===========================================================================

--- Map a `gh pr list --json` item to a lreview.MR.
---@param p table
---@param repo string
---@return lreview.MR
function M.gh_pr_to_mr(p, repo)
  if p.url then
    local parsed_repo = p.url:match("https?://[^/]+/(.-)/pull/")
    if parsed_repo then
      repo = parsed_repo
    end
  end
  return {
    mo_id = model.mo_id("github", repo, p.number),
    provider = "github",
    repo = repo,
    number = p.number,
    title = p.title,
    author = (p.author and p.author.login) or nil,
    state = (p.state or "OPEN"):lower(),
    source_branch = p.headRefName,
    target_branch = p.baseRefName,
    url = p.url,
    updated_at = p.updatedAt,
  }
end

--- Map a `gh pr list --json` array to lreview.MR[].
---@param arr table[]
---@param repo string
---@return lreview.MR[]
function M.gh_prs_to_pull_requests(arr, repo)
  local out = {}
  for _, p in ipairs(arr or {}) do
    out[#out + 1] = M.gh_pr_to_mr(p, repo)
  end
  return out
end

--- Map a `gh pr view --json` object to a lreview.MRDetail.
---@param p table
---@param repo string
---@return lreview.MRDetail
function M.gh_pr_view_to_mrdetail(p, repo)
  local detail = M.gh_pr_to_mr(p, repo)
  detail.description = p.body
  detail.base_sha = p.baseRefOid
  detail.head_sha = p.headRefOid
  detail.mergeable = p.mergeable == "MERGEABLE"
  detail.files = {}
  for _, f in ipairs(p.files or {}) do
    detail.files[#detail.files + 1] = {
      path = f.path,
      additions = f.additions,
      deletions = f.deletions,
      change_type = f.changeType,
    }
  end
  detail.commits = {}
  for _, c in ipairs(p.commits or {}) do
    detail.commits[#detail.commits + 1] = {
      sha = c.oid,
      message = c.messageHeadline,
      author = c.authors and c.authors[1] and c.authors[1].login,
    }
  end
  return detail
end

--- Map a `gh api .../pulls/{n}/comments` item (inline review comment) to a
--- lreview.Comment. `in_reply_to_id` is the GitHub threading primitive.
---@param c table
---@return lreview.Comment
function M.gh_review_comment_to_comment(c)
  return {
    c_id = tostring(c.id),
    remote_id = tostring(c.id),
    author = c.user and c.user.login,
    body = c.body,
    created_at = c.created_at,
    in_reply_to = c.in_reply_to_id and tostring(c.in_reply_to_id) or nil,
    -- Position info (used to group into threads for local sync).
    path = c.path,
    line = c.line or c.original_line,
    commit_sha = c.commit_id,
  }
end

--- Map a `gh pr view --json comments` item (general comment) to a lreview.Comment.
---@param c table
---@return lreview.Comment
function M.gh_issue_comment_to_comment(c)
  return {
    c_id = tostring(c.id),
    remote_id = tostring(c.id),
    author = c.author and c.author.login,
    body = c.body,
    created_at = c.createdAt,
  }
end

-- ===========================================================================
-- GitLab (glab) mappers
-- ===========================================================================

--- Map a `glab mr list -F json` item to a lreview.MR.
---@param m table
---@param repo string
---@return lreview.MR
function M.glab_mr_to_mr(m, repo)
  if m.web_url then
    local parsed_repo = m.web_url:match("https?://[^/]+/(.-)/%-/merge_requests/") or m.web_url:match("https?://[^/]+/(.-)/merge_requests/")
    if parsed_repo then
      repo = parsed_repo
    end
  end
  return {
    mo_id = model.mo_id("gitlab", repo, m.iid),
    provider = "gitlab",
    repo = repo,
    number = m.iid,
    title = m.title,
    author = m.author and m.author.username,
    state = m.state,
    source_branch = m.source_branch,
    target_branch = m.target_branch,
    url = m.web_url,
    updated_at = m.updated_at,
  }
end

--- Map a `glab mr list -F json` array to lreview.MR[].
---@param arr table[]
---@param repo string
---@return lreview.MR[]
function M.glab_merge_requests_to_pull_requests(arr, repo)
  local out = {}
  for _, m in ipairs(arr or {}) do
    out[#out + 1] = M.glab_mr_to_mr(m, repo)
  end
  return out
end

--- Map a `glab mr view -F json` object to a lreview.MRDetail.
---@param m table
---@param repo string
---@return lreview.MRDetail
function M.glab_mr_view_to_mrdetail(m, repo)
  local detail = M.glab_mr_to_mr(m, repo)
  detail.description = m.description
  detail.base_sha = nil -- not directly in view; available via diff/versions
  detail.head_sha = m.sha
  detail.mergeable = m.detailed_merge_status == "mergeable"
  return detail
end

--- Map a `glab api .../discussions` array to lreview.Thread[].
---
--- Each discussion groups notes. Inline notes carry a `position` with
--- new_path/new_line/line_range; general notes have position == nil.
---@param discussions table[]
---@param mo_id string
---@return lreview.Thread[]
function M.glab_discussions_to_threads(discussions, mo_id)
  local out = {}
  for _, disc in ipairs(discussions or {}) do
    local notes = disc.notes or {}
    -- Skip pure system discussions (e.g. "resolved all threads").
    local real = {}
    for _, n in ipairs(notes) do
      if not n.system then
        real[#real + 1] = n
      end
    end
    if #real > 0 then
      local first = real[1]
      local pos = first.position
      local start_line, end_line
      if pos and pos ~= vim.NIL then
        local lr = pos.line_range
        if lr and type(lr) == "table" then
          local s = lr.start
          local e = lr["end"]
          start_line = (s and type(s) == "table" and s.new_line) or pos.new_line
          end_line = (e and type(e) == "table" and e.new_line) or pos.new_line
        else
          start_line = pos.new_line
          end_line = pos.new_line
        end
      end
      local function clean(v)
        -- vim.NIL (JSON null) -> nil
        return (v == vim.NIL) and nil or v
      end
      local thread = {
        t_id = disc.id,
        mo_id = mo_id,
        path = clean(pos and (pos.new_path or pos.old_path)) or "",
        commit_sha = clean(pos and pos.head_sha),
        start_line = start_line or 0,
        end_line = end_line or 0,
        is_draft = false,
        last_synced_at = nil,
        comments = {},
      }
      for _, n in ipairs(real) do
        thread.comments[#thread.comments + 1] = {
          c_id = tostring(n.id),
          remote_id = tostring(n.id),
          author = n.author and n.author.username,
          body = n.body,
          created_at = nil,
          in_reply_to = disc.id,
        }
      end
      out[#out + 1] = thread
    end
  end
  return out
end

return M
