---@meta

-- GitLab adapter: wraps the `glab` CLI.
--
-- Ops are named defaults that can be overridden per-domain in config with a
-- string CLI template or a Lua function hook. Each op returns a lreview.CliResult
-- (see adapter/base.lua).

local base = require("lreview.adapter.base")
local mappers = require("lreview.mappers")
local model = require("lreview.model")

local M = {}

M.name = "gitlab"
M.provider = "glab"

M.capabilities = {
  review_verdict   = true,
  request_changes  = false,
  draft_mr         = true,
  update_mr        = true,
  close_mr         = true,
  approve_mr       = true,
  list_templates   = true,
  inline_comments  = true,
  resolve_threads  = true,
  -- `glab mr note create` is one note per call: no batching, and therefore no
  -- atomic all-or-nothing semantics either. The outbox (storage/outbox.lua)
  -- commits each note as it succeeds, which is what keeps a mid-loop failure
  -- from re-posting notes that already landed.
  batch_submit     = false,
  atomic_inline_batch = false,
  -- `mr note create` has no review-event concept: the verdict must be its own
  -- submit_verdict call.
  verdict_in_review_batch = false,
  assign_reviewers = true,
  offline_staging  = true,
  issues           = true,
}

--- Build the base argv with optional --repo.
---@param cfg table
---@param ctx table
---@return string[]
local function base_argv(cfg, ctx)
  local argv = { cfg.provider or "glab" }
  if ctx.repo then
    argv[#argv + 1] = "--repo"
    local full_repo = (ctx.owner and ctx.owner ~= "" and not ctx.repo:find("/")) and (ctx.owner .. "/" .. ctx.repo) or ctx.repo
    argv[#argv + 1] = full_repo
  end
  return argv
end

--- List pull requests (query). scope: "mine" | "all"; query: optional search string.
---@param cfg table
---@param ctx table
---@param opts table  -- { scope, query }
---@return lreview.MR[]|nil, string|nil
function M.list_pull_requests(cfg, ctx, opts)
  opts = opts or {}
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "list"
  if opts.scope == "mine" then
    -- glab has no --author @me; use --assignee=@me as the "mine" proxy.
    argv[#argv + 1] = "--assignee"
    argv[#argv + 1] = "@me"
  end
  if opts.query and opts.query ~= "" then
    argv[#argv + 1] = "--search"
    argv[#argv + 1] = opts.query
  end
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "json"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return mappers.glab_merge_requests_to_pull_requests(data, ctx.repo), nil
end

--- Get MR detail by ref (iid, branch, or current branch if ref is nil).
---@param cfg table
---@param ctx table
---@return lreview.MRDetail|nil, string|nil
function M.get_mr_detail(cfg, ctx)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "view"
  if ctx.ref then
    argv[#argv + 1] = tostring(ctx.ref)
  elseif ctx.number then
    argv[#argv + 1] = tostring(ctx.number)
  end
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "json"
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok and ctx.repo then
    local new_argv = {}
    local skip = false
    for _, arg in ipairs(argv) do
      if skip then
        skip = false
      elseif arg == "--repo" then
        skip = true
      else
        new_argv[#new_argv + 1] = arg
      end
    end
    local fallback_res = base.run(new_argv, { cwd = ctx.cwd })
    if fallback_res.ok then
      res = fallback_res
    end
  end

  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return mappers.glab_mr_view_to_mrdetail(data, ctx.repo), nil
end

--- Resolve an MR by branch name.
---@param cfg table
---@param ctx table
---@param branch string
---@return lreview.MR|nil, string|nil
function M.get_mr_by_branch(cfg, ctx, branch)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "list"
  argv[#argv + 1] = "--source-branch"
  argv[#argv + 1] = branch
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "json"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local prs = mappers.glab_merge_requests_to_pull_requests(data, ctx.repo)
  if #prs == 0 then
    return nil, "no merge request found for branch '" .. branch .. "'"
  end
  return prs[1], nil
end

--- Fetch remote discussions (threads) for an MR via the stable glab api.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@return lreview.Thread[]|nil, string|nil
--- Fetch every discussion (thread) on an MR.
--- Uses `glab api ... --paginate` so the response is the concatenation of all
--- pages, not just page 1. GitLab's default page size for this endpoint is 20;
--- without `--paginate`, an MR with >20 discussions silently drops any note
--- past the first page — the reason `:LocalReviewPull` missed a fresh reply
--- on MR #9 that sat on page 2. Matches how `list_users` and GitHub's
--- `--paginate` paths already work.
function M.fetch_discussions(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/:fullpath/merge_requests/%d/discussions", number)
  argv[#argv + 1] = "--paginate"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local mo_id = model.mo_id("gitlab", ctx.repo, number)
  return mappers.glab_discussions_to_threads(data, mo_id), nil
end

--- Fetch remote discussions (threads) for an MR. Alias of fetch_discussions
--- so both adapters expose a uniform `fetch_threads(cfg, ctx, number, mo_id)`.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@param mo_id string
---@return lreview.Thread[]|nil, string|nil
function M.fetch_threads(cfg, ctx, number, mo_id)
  return M.fetch_discussions(cfg, ctx, number)
end

--- List repo members (for @mention completion).
--- Uses `glab api projects/:fullpath/members/all --paginate`; glab follows
--- pagination automatically, so this scales to large organizations.
---@param cfg table
---@param ctx table
---@return table[]|nil, string|nil  -- { username, name, avatar_url }[]
function M.list_users(cfg, ctx)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = "projects/:fullpath/members/all"
  argv[#argv + 1] = "--paginate"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local out = {}
  for _, m in ipairs(data) do
    out[#out + 1] = {
      username = m.username,
      name = m.name,
      avatar_url = m.avatar_url,
    }
  end
  return out, nil
end

--- Submit a batch of inline comments as new discussion threads.
--- Uses `glab mr note create --file --line` (experimental but the only working
--- inline write path; raw glab api does not attach position).
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@param comments table[]  -- { path, line, body }
---@return boolean, string|nil
function M.submit_inline_review(cfg, ctx, number, comments, body)
  for _, c in ipairs(comments) do
    local argv = base_argv(cfg, ctx)
    argv[#argv + 1] = "mr"
    argv[#argv + 1] = "note"
    argv[#argv + 1] = "create"
    argv[#argv + 1] = tostring(number)
    argv[#argv + 1] = "--file"
    argv[#argv + 1] = c.path
    argv[#argv + 1] = "--line"
    argv[#argv + 1] = tostring(c.line)
    argv[#argv + 1] = "-m"
    argv[#argv + 1] = c.body
    local res = base.run(argv, { cwd = ctx.cwd })
    if not res.ok then
      return false, res.error
    end
  end
  return true, nil
end

--- Submit a reply to an existing discussion thread.
---@param cfg table
---@param ctx table
---@param number integer  -- MR iid
---@param thread_id string -- discussion ID
---@param body string
---@return string|nil, string|nil  -- remote_comment_id, error
function M.submit_reply(cfg, ctx, number, thread_id, body)
  local project = ctx.repo:gsub("/", "%%2F")
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/%s/merge_requests/%d/discussions/%s/notes", project, number, thread_id)
  argv[#argv + 1] = "-X"
  argv[#argv + 1] = "POST"
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "body=" .. body
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return nil, res.error
  end
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return tostring(data.id), nil
end

--- Update/edit a discussion note.
---@param cfg table
---@param ctx table
---@param number integer
---@param thread_id string
---@param note_id string
---@param body string
---@return boolean, string|nil
function M.update_comment(cfg, ctx, number, thread_id, note_id, body)
  local project = ctx.repo:gsub("/", "%%2F")
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/%s/merge_requests/%d/discussions/%s/notes/%s", project, number, thread_id, note_id)
  argv[#argv + 1] = "-X"
  argv[#argv + 1] = "PUT"
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "body=" .. body
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Delete a comment.
---@param cfg table
---@param ctx table
---@param number integer
---@param thread_id string
---@param note_id string
---@return boolean, string|nil
function M.delete_comment(cfg, ctx, number, thread_id, note_id)
  local project = ctx.repo:gsub("/", "%%2F")
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/%s/merge_requests/%d/discussions/%s/notes/%s", project, number, thread_id, note_id)
  argv[#argv + 1] = "-X"
  argv[#argv + 1] = "DELETE"
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Close a merge request.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@return boolean, string|nil
function M.close_mr(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "close"
  argv[#argv + 1] = tostring(number)
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Approve a merge request.
---@param cfg table
---@param ctx table
---@param number integer  -- iid
---@return boolean, string|nil
function M.approve_mr(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "approve"
  argv[#argv + 1] = tostring(number)
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Discover merge request templates in the repo.
--- GitLab looks in .gitlab/merge_request_templates/*.md.
---@param cfg table
---@param ctx table
---@return table[]|nil, string|nil  -- { name, path, content }[]
function M.list_templates(cfg, ctx)
  local dir = ctx.cwd .. "/.gitlab/merge_request_templates"
  local out = {}
  local p = io.popen("ls " .. vim.fn.shellescape(dir) .. " 2>/dev/null")
  if not p then
    return out, nil
  end
  for line in p:lines() do
    if line:match("%.md$") then
      local rel = ".gitlab/merge_request_templates/" .. line
      local f = io.open(ctx.cwd .. "/" .. rel, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local name = line:match("([^/]+)%.md$") or line
        out[#out + 1] = { name = name, path = rel, content = content }
      end
    end
  end
  p:close()
  return out, nil
end

--- Create a merge request.
---@param cfg table
---@param ctx table
---@param opts table  -- { title, body, source_branch, target_branch, template }
---@return string|nil url, string|nil err
function M.create_mr(cfg, ctx, opts)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "create"
  argv[#argv + 1] = "-t"
  argv[#argv + 1] = opts.title
  -- --description and --template are mutually exclusive in glab; when a
  -- template is selected it supplies the description.
  if opts.body and opts.body ~= "" and not opts.template then
    argv[#argv + 1] = "--description"
    argv[#argv + 1] = opts.body
  end
  if opts.source_branch and opts.source_branch ~= "" then
    argv[#argv + 1] = "--source-branch"
    argv[#argv + 1] = opts.source_branch
  end
  if opts.target_branch and opts.target_branch ~= "" then
    argv[#argv + 1] = "--target-branch"
    argv[#argv + 1] = opts.target_branch
  end
  if opts.template and opts.template ~= "" then
    argv[#argv + 1] = "--template"
    argv[#argv + 1] = opts.template
  end
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return nil, res.error
  end
  local url = res.stdout:match("https?://%S+")
  return url, nil
end

--- Resolve or unresolve a comment thread on GitLab.
---@param cfg table
---@param ctx table
---@param mr_number integer  -- iid
---@param thread_id string  -- discussion_id
---@param resolved boolean
---@return boolean, string|nil
function M.resolve_thread(cfg, ctx, mr_number, thread_id, resolved)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "note"
  argv[#argv + 1] = resolved and "resolve" or "reopen"
  argv[#argv + 1] = tostring(mr_number)
  argv[#argv + 1] = thread_id
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Update the MR title and description on GitLab.
---@param cfg table
---@param ctx table
---@param number integer
---@param title string
---@param body string
---@return boolean, string|nil
function M.update_mr(cfg, ctx, number, title, body)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "update"
  argv[#argv + 1] = tostring(number)
  argv[#argv + 1] = "-t"
  argv[#argv + 1] = title
  argv[#argv + 1] = "-d"
  argv[#argv + 1] = body
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Assign reviewers to a merge request.
---@param cfg table
---@param ctx table
---@param number integer
---@param reviewers string[]
---@return boolean, string|nil
function M.assign_reviewers(cfg, ctx, number, reviewers)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "mr"
  argv[#argv + 1] = "update"
  argv[#argv + 1] = tostring(number)
  argv[#argv + 1] = "--reviewer"
  argv[#argv + 1] = table.concat(reviewers, ",")
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

-- ---------------------------------------------------------------------------
-- Review verdict (standalone)
-- ---------------------------------------------------------------------------

--- Submit a review verdict that has no inline comments attached.
--- GitLab has no `mr note` equivalent of GitHub's review event: APPROVE maps to
--- `glab mr approve`, COMMENT is a no-op, and REQUEST_CHANGES is honestly
--- unsupported — the user must see that instead of a silent no-op.
---@param cfg table
---@param ctx table
---@param number integer
---@param verdict string  -- "COMMENT" | "APPROVE" | "REQUEST_CHANGES"
---@param body string|nil
---@return boolean, string|nil
function M.submit_verdict(cfg, ctx, number, verdict, body)
  verdict = verdict and tostring(verdict):upper() or "COMMENT"
  if not verdict or verdict == "COMMENT" then
    return true, nil
  end
  if verdict == "APPROVE" then
    return M.approve_mr(cfg, ctx, number)
  end
  return false, "gitlab: 'request changes' has no glab API equivalent — "
    .. "inline comments were pushed, set the verdict in the MR UI"
end

-- ---------------------------------------------------------------------------
-- Issues
-- ---------------------------------------------------------------------------

local GLAB_STATE = { open = "opened", closed = "closed", all = "all" }

--- One page of issues. Pagination is explicit so the caller can report progress.
---@param cfg table
---@param ctx table
---@param opts table|nil  -- { state, page, per_page, labels, assignee, author, filter }
---@return lreview.Issue[]|nil, string|nil
function M.list_issues(cfg, ctx, opts)
  opts = opts or {}
  local project = ctx.repo:gsub("/", "%%2F")
  local qs = {
    "state=" .. (GLAB_STATE[opts.state or "open"] or "opened"),
    "per_page=" .. tostring(opts.per_page or 50),
    "page=" .. tostring(opts.page or 1),
    -- Newest-updated first: an interrupted pull still cached the relevant rows.
    "order_by=updated_at",
    "sort=desc",
  }
  if opts.labels and opts.labels ~= "" then
    qs[#qs + 1] = "labels=" .. opts.labels
  end
  if opts.assignee and opts.assignee ~= "" then
    qs[#qs + 1] = "assignee_username=" .. opts.assignee
  end
  if opts.author and opts.author ~= "" then
    qs[#qs + 1] = "author_username=" .. opts.author
  end
  if opts.filter and opts.filter ~= "" then
    qs[#qs + 1] = "search=" .. base.uri_encode(opts.filter)
  end

  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/%s/issues?%s", project, table.concat(qs, "&"))
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return mappers.glab_issues_to_issues(data, ctx.repo), nil
end

--- Single issue detail (fresh from the hub).
---@param cfg table
---@param ctx table
---@param number integer  -- issue IID
---@return lreview.Issue|nil, string|nil
function M.get_issue(cfg, ctx, number)
  local project = ctx.repo:gsub("/", "%%2F")
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/%s/issues/%d", project, number)
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return mappers.glab_issue_to_issue(data, ctx.repo), nil
end

--- Issue notes. GitLab mixes discussion notes and system notes
--- ("added label ...") into one list; `system` is preserved so the UI can hide
--- the noise without a second round trip.
---@param cfg table
---@param ctx table
---@param number integer
---@param opts table|nil  -- { page, per_page, include_system }
---@return lreview.IssueNote[]|nil, string|nil
function M.fetch_issue_notes(cfg, ctx, number, opts)
  opts = opts or {}
  local project = ctx.repo:gsub("/", "%%2F")
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "api"
  argv[#argv + 1] = string.format("projects/%s/issues/%d/notes?per_page=%d&page=%d&sort=asc",
    project, number, opts.per_page or 100, opts.page or 1)
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local out = {}
  for _, n in ipairs(data) do
    if opts.include_system ~= false or not n.system then
      out[#out + 1] = mappers.glab_issue_note_to_note(n, ctx.repo, number)
    end
  end
  return out, nil
end

return M
