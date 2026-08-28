---@meta

-- Local-first review flow.
--
--   start_review()  -> resolve current MR by branch, open storage, cache detail
--   add_comment()   -> visual selection -> draft thread + comment INSERT
--   submit_review() -> push all draft inline comments to the platform (only
--                      inline comments; no platform review-state per user req)
--
-- "Submit" never changes platform review state (no approve/request-changes).
-- It only pushes the pending inline comments.

local config = require("lreview.config")
local git = require("lreview.git")
local model = require("lreview.model")
local adapter = require("lreview.adapter")
local storage = require("lreview.storage")
local pull_request = require("lreview.storage.pull_request")
local comments = require("lreview.storage.comments")

local M = {}

-- Current active review context (per-buffer state lives in the UI layer).
---@type table|nil
M.current = nil

--- Generate a local uuid (v4-ish) for draft ids.
---@return string
local function uuid()
  local t = {}
  for i = 1, 32 do
    local r = math.random(0, 15)
    t[i] = string.format("%x", r)
  end
  -- variant/version bits
  t[13] = "4"
  t[17] = string.format("%x", math.floor(math.random(8, 11)))
  return table.concat(t, "", 1, 8) .. "-" .. table.concat(t, "", 9, 12)
    .. "-" .. table.concat(t, "", 13, 16) .. "-" .. table.concat(t, "", 17, 20)
    .. "-" .. table.concat(t, "", 21, 32)
end

--- Resolve the current MR for a directory (by branch, or current branch).
---@param cwd string|nil
---@return lreview.MRDetail|nil, string|nil
function M.resolve_current_mr(cwd)
  local resolved = adapter.resolve(cwd)
  if not resolved then
    return nil, "no forge remote detected in this repo"
  end
  local branch = git.current_branch(cwd)
  local ctx = adapter.ctx(resolved, branch)
  local detail, err = resolved.adapter.get_mr_detail(resolved.cfg, ctx)
  if not detail then
    -- fall back to branch resolution
    local mr, err2 = resolved.adapter.get_mr_by_branch(resolved.cfg, ctx, branch)
    if not mr then
      return nil, err or err2
    end
    detail = mr
  end
  return detail, nil
end

--- Start a review: resolve MR, open storage, cache the MR detail.
---@param cwd string|nil
---@return lreview.MRDetail|nil, string|nil
function M.start_review(cwd)
  local detail, err = M.resolve_current_mr(cwd)
  if not detail then
    return nil, err
  end
  local ok, oerr = storage.open()
  if not ok then
    return nil, oerr
  end
  pull_request.upsert(detail)
  M.current = {
    detail = detail,
    cwd = cwd,
  }
  return detail, nil
end

--- Add a draft comment on a line range of a file in the current review.
---@param path string
---@param start_line integer
---@param end_line integer|nil
---@param body string
---@return lreview.Thread|nil, string|nil
function M.add_comment(path, start_line, end_line, body)
  if not M.current then
    return nil, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local t_id = uuid()
  local thread = {
    t_id = t_id,
    mo_id = detail.mo_id,
    path = path,
    commit_sha = detail.head_sha,
    start_line = start_line,
    end_line = end_line or start_line,
    is_draft = true,
    last_synced_at = nil,
    comments = {},
  }
  comments.create_thread(thread)
  local c = {
    c_id = uuid(),
    t_id = t_id,
    remote_id = nil,
    author = nil, -- filled at submit time from CLI identity
    body = body,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    in_reply_to = nil,
  }
  comments.add_comment(c)
  thread.comments[1] = c
  return thread, nil
end

--- Submit the review: push all draft inline comments for the current MR.
--- Only pushes inline comments; does NOT change platform review state.
---@return integer pushed, string|nil err
function M.submit_review()
  if not M.current then
    return 0, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return 0, "no forge remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)

  -- Collect draft threads + their comments.
  local drafts = comments.draft_threads(detail.mo_id)
  local batch = {}
  for _, t in ipairs(drafts) do
    local cs = comments.comments_for_thread(t.t_id)
    for _, c in ipairs(cs) do
      batch[#batch + 1] = {
        path = t.path,
        line = t.start_line,
        body = c.body,
        t_id = t.t_id,
        c_id = c.c_id,
      }
    end
  end
  if #batch == 0 then
    return 0, "no draft comments to submit"
  end

  local ok, err = resolved.adapter.submit_inline_review(resolved.cfg, ctx, detail.number, batch)
  if not ok then
    return 0, err
  end

  -- Mark threads synced on success.
  for _, b in ipairs(batch) do
    comments.mark_synced(b.t_id)
  end
  return #batch, nil
end

--- List draft comments for the current MR (for a review summary UI).
---@return table[]
function M.list_drafts()
  if not M.current then
    return {}
  end
  return comments.draft_threads(M.current.detail.mo_id)
end

--- Sync remote MR threads/comments into local storage.
--- Fetches the platform's inline comments/discussions for the current MR and
--- upserts them as synced (is_draft=0) threads. Local drafts (is_draft=1) are
--- preserved. Returns the number of remote threads synced.
---@return integer synced, string|nil err
function M.sync_review()
  if not M.current then
    return 0, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return 0, "no forge remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)
  local remote_threads, err = resolved.adapter.fetch_threads(resolved.cfg, ctx, detail.number, detail.mo_id)
  if not remote_threads then
    return 0, err
  end
  local n = 0
  for _, t in ipairs(remote_threads) do
    -- Upsert the thread as synced (is_draft=0). Remote threads use remote ids,
    -- so they never collide with local draft uuids.
    comments.create_thread({
      t_id = t.t_id,
      mo_id = detail.mo_id,
      path = t.path,
      commit_sha = t.commit_sha,
      start_line = t.start_line,
      end_line = t.end_line,
      is_draft = false,
      last_synced_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    for _, c in ipairs(t.comments or {}) do
      comments.add_comment({
        c_id = c.c_id,
        t_id = t.t_id,
        remote_id = c.remote_id,
        author = c.author,
        body = c.body,
        created_at = c.created_at,
        in_reply_to = c.in_reply_to,
      })
    end
    n = n + 1
  end
  return n, nil
end

--- List available MR/PR templates for the current repo.
---@param cwd string|nil
---@return table[]|nil templates, string|nil err
function M.list_templates(cwd)
  local resolved = adapter.resolve(cwd or vim.fn.getcwd())
  if not resolved then
    return nil, "no forge remote detected"
  end
  local ctx = adapter.ctx(resolved)
  return resolved.adapter.list_templates(resolved.cfg, ctx)
end

--- Create a new MR/PR on the platform.
---@param opts table  -- { title, body, source_branch, target_branch, template }
---@param cwd string|nil
---@return string|nil url, string|nil err
function M.create_review(opts, cwd)
  local resolved = adapter.resolve(cwd or vim.fn.getcwd())
  if not resolved then
    return nil, "no forge remote detected"
  end
  local ctx = adapter.ctx(resolved)
  local url, err = resolved.adapter.create_mr(resolved.cfg, ctx, opts)
  if not url then
    return nil, err
  end
  return url, nil
end

--- Close an MR on the platform.
--- Uses the given remote identifier (MR/PR number) if provided, otherwise the
--- current active review's MR.
---@param number integer|nil  -- remote MR/PR number
---@return boolean, string|nil
function M.close_review(number)
  local detail = M.current and M.current.detail
  local num = number or (detail and detail.number)
  if not num then
    return false, "no active review; run LocalReviewStart first (or pass an MR number)"
  end
  local cwd = M.current and M.current.cwd or vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then
    return false, "no forge remote detected"
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.close_mr(resolved.cfg, ctx, num)
  if not ok then
    return false, err
  end
  return true, nil
end

--- Approve an MR on the platform.
--- Uses the given remote identifier (MR/PR number) if provided, otherwise the
--- current active review's MR.
---@param number integer|nil  -- remote MR/PR number
---@return boolean, string|nil
function M.approve_review(number)
  local detail = M.current and M.current.detail
  local num = number or (detail and detail.number)
  if not num then
    return false, "no active review; run LocalReviewStart first (or pass an MR number)"
  end
  local cwd = M.current and M.current.cwd or vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then
    return false, "no forge remote detected"
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.approve_mr(resolved.cfg, ctx, num)
  if not ok then
    return false, err
  end
  return true, nil
end

return M
