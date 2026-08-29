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
    return nil, "no git remote detected in this repo"
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
  cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p")
  if cwd:sub(-1) == "/" or cwd:sub(-1) == "\\" then
    cwd = cwd:sub(1, -2)
  end

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
  -- Auto-pull remote updates only in interactive sessions. The headless pull
  -- job sets vim.g.lreview_pull_job before calling start_review, which would
  -- otherwise spawn an unbounded chain of nested pull jobs (each job spawning
  -- another) and pile up orphaned nvim processes contending on the SQLite DB.
  if not vim.g.lreview_pull_job then
    M.pull_review_async()
  end
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

--- Create and submit a new comment thread immediately to the remote forge.
---@param path string
---@param start_line integer
---@param end_line integer
---@param body string
---@return boolean, string|nil
function M.push_thread_immediately(path, start_line, end_line, body)
  if not M.current then
    return false, "no active review"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return false, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)
  local batch = {
    { path = path, line = start_line, body = body }
  }
  local ok, err = resolved.adapter.submit_inline_review(resolved.cfg, ctx, detail.number, batch)
  if not ok then
    return false, err
  end
  M.sync_review()
  return true, nil
end

--- Submit a reply comment immediately to the remote forge.
---@param thread_id string
---@param body string
---@return string|nil, string|nil  -- remote_comment_id, error
function M.push_reply_immediately(thread_id, body)
  if not M.current then
    return nil, "no active review"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return nil, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)

  local reply_to_id = thread_id
  if resolved.provider == "gh" or resolved.provider == "github" then
    local cs = comments.comments_for_thread(thread_id)
    if #cs > 0 then
      reply_to_id = cs[1].remote_id
    end
  end

  local comment_id, err = resolved.adapter.submit_reply(resolved.cfg, ctx, detail.number, reply_to_id, body)
  if comment_id then
    M.sync_review()
  end
  return comment_id, err
end

--- Update/edit a comment immediately on the remote forge.
---@param c_id string
---@param body string
---@return boolean, string|nil
function M.push_edit_immediately(c_id, body)
  if not M.current then
    return false, "no active review"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return false, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)

  local c = storage.query("SELECT * FROM comments WHERE c_id = ?", c_id)[1]
  if not c then
    return false, "comment not found"
  end
  local thread_id = c.t_id

  if c.remote_id then
    local ok, err = resolved.adapter.update_comment(resolved.cfg, ctx, detail.number, thread_id, c.remote_id, body)
    if not ok then
      return false, err
    end
    M.sync_review()
  end
  return true, nil
end

--- Submit the review: push all draft inline comments (new threads and replies) for the current MR.
--- Only pushes inline comments; does NOT change platform review state.
---@return integer pushed, string|nil err
function M.submit_review()
  if not M.current then
    return 0, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return 0, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)

  -- Query drafts (remote_id IS NULL) AND dirty edits (dirty = 1)
  local drafts = storage.query([[
    SELECT c.c_id, c.t_id, c.body, c.remote_id, c.dirty, c.in_reply_to, t.path, t.start_line, t.end_line, t.is_draft as thread_is_draft
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND (c.remote_id IS NULL OR c.dirty = 1)
  ]], detail.mo_id)

  if not drafts or #drafts == 0 then
    return 0, "no draft or edited comments to submit"
  end

  local new_threads_batch = {}
  local replies = {}
  local edits = {}

  for _, d in ipairs(drafts) do
    if d.remote_id and d.remote_id ~= "" and d.dirty == 1 then
      edits[#edits + 1] = {
        t_id = d.t_id,
        c_id = d.c_id,
        remote_id = d.remote_id,
        body = d.body,
      }
    elseif d.thread_is_draft == 1 then
      new_threads_batch[#new_threads_batch + 1] = {
        path = d.path,
        line = d.start_line,
        body = d.body,
        t_id = d.t_id,
        c_id = d.c_id,
      }
    else
      local reply_to_id = d.t_id
      if resolved.provider == "gh" or resolved.provider == "github" then
        local cs = comments.comments_for_thread(d.t_id)
        if #cs > 0 then
          reply_to_id = cs[1].remote_id
        end
      end
      replies[#replies + 1] = {
        t_id = d.t_id,
        c_id = d.c_id,
        body = d.body,
        reply_to_id = reply_to_id,
      }
    end
  end

  -- Format confirmation summary
  local summary = { "Pending Review Changes:" }
  for _, nt in ipairs(new_threads_batch) do
    local snippet = nt.body:gsub("\n", " "):sub(1, 45)
    summary[#summary + 1] = string.format("  [New Thread]  %s:%d: %s", nt.path, nt.line, snippet)
  end
  for _, r in ipairs(replies) do
    local snippet = r.body:gsub("\n", " "):sub(1, 45)
    summary[#summary + 1] = string.format("  [New Reply]   %s", snippet)
  end
  for _, e in ipairs(edits) do
    local snippet = e.body:gsub("\n", " "):sub(1, 45)
    summary[#summary + 1] = string.format("  [Edit Note]   %s", snippet)
  end

  local total_pending = #new_threads_batch + #replies + #edits
  local msg = table.concat(summary, "\n") .. string.format("\n\nPush these %d change(s) to %s?", total_pending, resolved.provider)
  local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
  if choice ~= 1 then
    vim.notify("lreview: push cancelled", vim.log.levels.INFO)
    return 0, nil
  end

  local count = 0

  -- 1. Submit new threads in a batch
  if #new_threads_batch > 0 then
    local ok, err = resolved.adapter.submit_inline_review(resolved.cfg, ctx, detail.number, new_threads_batch)
    if not ok then
      return 0, err
    end
    -- Clear local drafts on success
    for _, nt in ipairs(new_threads_batch) do
      comments.delete_comment(nt.c_id)
      comments.delete_thread(nt.t_id)
    end
    count = count + #new_threads_batch
  end

  -- 2. Submit replies individually
  for _, r in ipairs(replies) do
    local comment_id, err = resolved.adapter.submit_reply(resolved.cfg, ctx, detail.number, r.reply_to_id, r.body)
    if not comment_id then
      return count, err
    end
    -- Clear local draft reply on success
    comments.delete_comment(r.c_id)
    count = count + 1
  end

  -- 3. Submit edits individually
  for _, e in ipairs(edits) do
    local ok, err = resolved.adapter.update_comment(resolved.cfg, ctx, detail.number, e.t_id, e.remote_id, e.body)
    if not ok then
      return count, err
    end
    -- Mark comment clean on success
    comments.mark_clean(e.c_id)
    count = count + 1
  end

  -- Sync remote state on success to update local IDs and clear draft markers
  M.sync_review()
  return count, nil
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
    return 0, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)
  local remote_threads, err = resolved.adapter.fetch_threads(resolved.cfg, ctx, detail.number, detail.mo_id)
  if not remote_threads then
    return 0, err
  end

  local remote_c_ids = {}
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
      resolved = t.resolved == 1,
      last_synced_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    for _, c in ipairs(t.comments or {}) do
      remote_c_ids[c.c_id] = true

      -- Preserve local dirty edits during remote sync
      local local_c = storage.query("SELECT dirty, body FROM comments WHERE remote_id = ?", c.remote_id)[1]
      local body_val = c.body
      local dirty_val = false
      if local_c and local_c.dirty == 1 then
        body_val = local_c.body
        dirty_val = true
      end

      comments.add_comment({
        c_id = c.c_id,
        t_id = t.t_id,
        remote_id = c.remote_id,
        author = c.author,
        body = body_val,
        created_at = c.created_at,
        in_reply_to = c.in_reply_to,
        deleted = false,
        dirty = dirty_val,
      })
    end
    n = n + 1
  end

  -- Detect and soft-delete local synced comments that were deleted on the remote
  local existing_comments = storage.query([[
    SELECT c.c_id, c.remote_id, c.deleted
    FROM comments c
    JOIN threads t ON c.t_id = t.t_id
    WHERE t.mo_id = ? AND c.remote_id IS NOT NULL
  ]], detail.mo_id)

  for _, ec in ipairs(existing_comments or {}) do
    if not remote_c_ids[ec.remote_id] and ec.deleted == 0 then
      comments.soft_delete_comment(ec.c_id)
    end
  end

  return n, nil
end

--- List available MR/PR templates for the current repo.
---@param cwd string|nil
---@return table[]|nil templates, string|nil err
function M.list_templates(cwd)
  local resolved = adapter.resolve(cwd or vim.fn.getcwd())
  if not resolved then
    return nil, "no git remote detected"
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
    return nil, "no git remote detected"
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
    return false, "no git remote detected"
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
    return false, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.approve_mr(resolved.cfg, ctx, num)
  if not ok then
    return false, err
  end
  return true, nil
end
--- Update an MR/PR's title and description.
---@param title string
---@param body string
---@param number integer|nil
---@param cwd string|nil
---@return boolean, string|nil
function M.update_review(title, body, number, cwd)
  local num = number or (M.current and M.current.detail.number)
  if not num then
    return false, "no active review"
  end
  cwd = cwd or (M.current and M.current.cwd) or vim.fn.getcwd()
  local resolved = adapter.resolve(cwd)
  if not resolved then
    return false, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, num)
  local ok, err = resolved.adapter.update_mr(resolved.cfg, ctx, num, title, body)
  if not ok then
    return false, err
  end

  -- Update local cached details if active
  if M.current and M.current.detail.number == num then
    M.current.detail.title = title
    M.current.detail.body = body
  end

  local pull_request = require("lreview.storage.pull_request")
  local ok_storage = storage.open()
  if ok_storage then
    local key = resolved.provider .. ":" .. resolved.repo .. ":" .. num
    local cached = pull_request.get(key)
    if cached then
      cached.title = title
      cached.body = body
      pull_request.upsert(cached)
    end
  end

  return true, nil
end

--- Resolve or unresolve a comment thread.
--- Handles both local-only updates for drafts and remote platform calls for synced threads.
---@param thread_id string
---@param resolved_val boolean
---@return boolean, string|nil
function M.resolve_thread(thread_id, resolved_val)
  local t = comments.get_thread(thread_id)
  if not t then
    return false, "thread not found"
  end

  -- If it's a draft, just update local storage.
  if t.is_draft == 1 then
    comments.resolve_thread(thread_id, resolved_val)
    return true, nil
  end

  -- For synced threads, call the remote forge.
  if not M.current then
    return false, "no active review; run LocalReviewStart first"
  end
  local detail = M.current.detail
  local resolved = adapter.resolve(M.current.cwd)
  if not resolved then
    return false, "no git remote detected"
  end
  local ctx = adapter.ctx(resolved, detail.number)
  local ok, err = resolved.adapter.resolve_thread(resolved.cfg, ctx, detail.number, thread_id, resolved_val)
  if not ok then
    return false, err
  end

  -- Sync local state on success.
  comments.resolve_thread(thread_id, resolved_val)
  return true, nil
end

--- Fetch remote reviews asynchronously (non-blocking).
--- Executes the sync_review script in a headless Neovim background job.
---@param callback fun(success: boolean)|nil
---@return boolean, string|nil
function M.pull_review_async(callback)
  if not M.current then
    if callback then callback(false) end
    return false, "no active review"
  end

  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1).source:match("@(.*)$"), ":h:h:h")
  local current_cwd = M.current.cwd or vim.fn.getcwd()
  local cmd = {
    vim.v.progpath,
    "--headless",
    "--cmd",
    "set runtimepath^=" .. vim.fn.escape(plugin_root, " "),
    "-c",
    string.format("lua vim.g.lreview_pull_job = true; require('lreview').api.start_review(%q)", current_cwd),
    "-c",
    "lua require('lreview').api.sync_review()",
    "-c",
    "qa"
  }

  vim.system(cmd, { cwd = current_cwd }, function(res)
    vim.schedule(function()
      local success = (res.code == 0)
      if success then
        -- Refresh highlights on active buffers
        local decor = require("lreview.ui.decor")
        for bufnr, _ in pairs(decor.enabled_buffers) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            decor.refresh(bufnr)
          end
        end
        -- Refresh thread view if it is open
        local tv = require("lreview.ui.thread_view")
        if tv.state and vim.api.nvim_buf_is_valid(tv.state.bufnr) then
          tv.redraw()
        end
      end
      if callback then
        callback(success)
      end
    end)
  end)
  return true, nil
end

return M
