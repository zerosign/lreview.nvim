---@meta

-- GitHub adapter: wraps the `gh` CLI.
--
-- Ops are named defaults that can be overridden per-domain in config with a
-- string CLI template or a Lua function hook. Each op returns a lreview.CliResult
-- (see adapter/base.lua).

local base = require("lreview.adapter.base")
local mappers = require("lreview.mappers")
local model = require("lreview.model")

local M = {}

M.name = "github"
M.provider = "gh"

M.capabilities = {
  review_verdict   = true,
  draft_mr         = true,
  update_mr        = true,
  close_mr         = true,
  approve_mr       = true,
  list_templates   = true,
  inline_comments  = true,
  resolve_threads  = true,
  batch_submit     = true,
  assign_reviewers = true,
  offline_staging  = true,
}

--- Resolve an op value (string template or fn) into an argv list.
---@param cfg table  -- merged per-domain config
---@param op string  -- op name
---@param ctx table  -- { ref, repo, host, ... }
---@return string[]|nil argv
local function resolve_op(cfg, op, ctx)
  local v = cfg[op]
  if v == nil then
    return nil
  end
  if type(v) == "function" then
    local s = v(ctx)
    if s == nil then
      return nil
    end
    v = s
  end
  -- substitute placeholders
  v = v:gsub("{ref}", ctx.ref or "")
  v = v:gsub("{id}", ctx.ref or "")
  v = v:gsub("{repo}", ctx.repo or "")
  v = v:gsub("{host}", ctx.host or "")
  -- split into argv (simple whitespace split; quoted args not supported)
  local argv = {}
  for tok in v:gmatch("%S+") do
    argv[#argv + 1] = tok
  end
  return argv
end

--- Build the base argv with optional --repo.
---@param cfg table
---@param ctx table
---@return string[]
local function base_argv(cfg, ctx)
  local argv = { cfg.provider or "gh" }
  if ctx.host and ctx.host ~= "github.com" then
    argv[#argv + 1] = "--hostname"
    argv[#argv + 1] = ctx.host
  end
  if ctx.repo then
    argv[#argv + 1] = "--repo"
    argv[#argv + 1] = ctx.repo
  end
  return argv
end

--- Build the base argv for `gh api` calls.
--- `gh api` does NOT accept --repo; it resolves {owner}/{repo} placeholders
--- from the current directory's git remote (or --hostname). So we only add
--- --hostname here, never --repo.
---@param cfg table
---@param ctx table
---@return string[]
local function api_argv(cfg, ctx)
  local argv = { cfg.provider or "gh", "api" }
  if ctx.host and ctx.host ~= "github.com" then
    argv[#argv + 1] = "--hostname"
    argv[#argv + 1] = ctx.host
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
  if opts.scope == "mine" then
    argv[#argv + 1] = "pr"
    argv[#argv + 1] = "list"
    argv[#argv + 1] = "--author"
    argv[#argv + 1] = "@me"
    argv[#argv + 1] = "--state"
    argv[#argv + 1] = "open"
    argv[#argv + 1] = "--json"
    argv[#argv + 1] = "number,title,author,state,headRefName,baseRefName,url,updatedAt"
  else
    argv[#argv + 1] = "pr"
    argv[#argv + 1] = "list"
    argv[#argv + 1] = "--state"
    argv[#argv + 1] = "open"
    argv[#argv + 1] = "--json"
    argv[#argv + 1] = "number,title,author,state,headRefName,baseRefName,url,updatedAt"
    if opts.query and opts.query ~= "" then
      argv[#argv + 1] = "--search"
      argv[#argv + 1] = opts.query
    end
  end
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return mappers.gh_prs_to_pull_requests(data, ctx.repo), nil
end

--- Get MR detail by ref (number, branch, or current branch if ref is nil).
---@param cfg table
---@param ctx table
---@return lreview.MRDetail|nil, string|nil
function M.get_mr_detail(cfg, ctx)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "pr"
  argv[#argv + 1] = "view"
  if ctx.ref then
    argv[#argv + 1] = ctx.ref
  end
  argv[#argv + 1] = "--json"
  argv[#argv + 1] = "number,title,body,author,baseRefName,headRefName,state,url,baseRefOid,headRefOid,mergeable,isDraft,reviewDecision,files,commits"
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
  return mappers.gh_pr_view_to_mrdetail(data, ctx.repo), nil
end

--- Resolve an MR by branch name.
---@param cfg table
---@param ctx table
---@param branch string
---@return lreview.MR|nil, string|nil
function M.get_mr_by_branch(cfg, ctx, branch)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "pr"
  argv[#argv + 1] = "list"
  argv[#argv + 1] = "--head"
  argv[#argv + 1] = branch
  argv[#argv + 1] = "--json"
  argv[#argv + 1] = "number,title,author,state,headRefName,baseRefName,url,updatedAt"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local prs = mappers.gh_prs_to_pull_requests(data, ctx.repo)
  if #prs == 0 then
    return nil, "no pull request found for branch '" .. branch .. "'"
  end
  return prs[1], nil
end

--- Fetch remote inline review comments for an MR.
---@param cfg table
---@param ctx table
---@param number integer
---@return lreview.Comment[]|nil, string|nil
function M.fetch_inline_comments(cfg, ctx, number)
  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = string.format("repos/{owner}/{repo}/pulls/%d/comments", number)
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local out = {}
  for _, c in ipairs(data) do
    out[#out + 1] = mappers.gh_review_comment_to_comment(c)
  end
  return out, nil
end

function M.fetch_threads(cfg, ctx, number, mo_id)
  local owner, repo_name = ctx.repo:match("^([^/]+)/(.+)$")
  if not owner or not repo_name then
    return nil, "invalid repository path: " .. tostring(ctx.repo)
  end

  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = "graphql"
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "owner=" .. owner
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "name=" .. repo_name
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "number=" .. number

  local query = [[
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              path
              line
              comments(first: 100) {
                nodes {
                  id
                  databaseId
                  body
                  createdAt
                  author {
                    login
                  }
                  commit {
                    oid
                  }
                }
              }
            }
          }
        }
      }
    }
  ]]
  argv[#argv + 1] = "-f"
  argv[#argv + 1] = "query=" .. query

  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end

  local pr = data.data and data.data.repository and data.data.repository.pullRequest
  if not pr then
    return {}, nil
  end

  local threads = {}
  local nodes = pr.reviewThreads and pr.reviewThreads.nodes or {}
  for _, node in ipairs(nodes) do
    local comments_nodes = node.comments and node.comments.nodes or {}
    if #comments_nodes > 0 then
      local t = {
        t_id = node.id,
        mo_id = mo_id,
        path = node.path,
        commit_sha = comments_nodes[1].commit and comments_nodes[1].commit.oid or nil,
        start_line = node.line,
        end_line = node.line,
        is_draft = false,
        resolved = node.isResolved and 1 or 0,
        last_synced_at = nil,
        comments = {},
      }
      for _, c_node in ipairs(comments_nodes) do
        t.comments[#t.comments + 1] = {
          c_id = tostring(c_node.databaseId or c_node.id),
          t_id = node.id,
          remote_id = tostring(c_node.databaseId or c_node.id),
          author = c_node.author and c_node.author.login or "ghost",
          body = c_node.body,
          created_at = c_node.createdAt,
          in_reply_to = nil,
        }
      end
      threads[#threads + 1] = t
    end
  end

  return threads, nil
end

--- List repo collaborators (for @mention completion).
--- Uses `gh api repos/{owner}/{repo}/collaborators --paginate`; gh follows
--- pagination automatically, so this scales to large organizations.
---@param cfg table
---@param ctx table
---@return table[]|nil, string|nil  -- { username, name, avatar_url }[]
function M.list_users(cfg, ctx)
  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = "repos/{owner}/{repo}/collaborators"
  argv[#argv + 1] = "--paginate"
  local res = base.run(argv, { cwd = ctx.cwd })
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  local out = {}
  for _, m in ipairs(data) do
    out[#out + 1] = {
      username = m.login,
      name = m.name,
      avatar_url = m.avatar_url,
    }
  end
  return out, nil
end

--- Submit a batch of inline comments as a review (supports verdict=APPROVE|REQUEST_CHANGES|COMMENT).
---@param cfg table
---@param ctx table
---@param number integer
---@param comments table[]  -- { path, line, body }
---@param body string|nil  -- review summary
---@param opts table|nil  -- { verdict = "APPROVE"|"REQUEST_CHANGES"|"COMMENT" }
---@return boolean, string|nil
function M.submit_inline_review(cfg, ctx, number, comments, body, opts)
  opts = opts or {}
  local event = opts.verdict or "COMMENT"
  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = string.format("repos/{owner}/{repo}/pulls/%d/reviews", number)
  argv[#argv + 1] = "-X"
  argv[#argv + 1] = "POST"
  argv[#argv + 1] = "-f"
  argv[#argv + 1] = "event=" .. event
  if body and body ~= "" then
    argv[#argv + 1] = "-f"
    argv[#argv + 1] = "body=" .. body
  end
  for _, c in ipairs(comments) do
    argv[#argv + 1] = "-F"
    argv[#argv + 1] = string.format("comments[][path]=%s", c.path)
    argv[#argv + 1] = "-F"
    argv[#argv + 1] = string.format("comments[][line]=%d", c.line)
    argv[#argv + 1] = "-F"
    argv[#argv + 1] = "comments[][side]=RIGHT"
    argv[#argv + 1] = "-F"
    argv[#argv + 1] = string.format("comments[][body]=%s", c.body)
  end
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Submit a reply to an existing thread.
---@param cfg table
---@param ctx table
---@param number integer
---@param reply_to_id string  -- comment databaseId/node ID (parent comment)
---@param body string
---@return string|nil, string|nil  -- remote_comment_id, error
function M.submit_reply(cfg, ctx, number, reply_to_id, body)
  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = string.format("repos/{owner}/{repo}/pulls/%d/comments", number)
  argv[#argv + 1] = "-X"
  argv[#argv + 1] = "POST"
  argv[#argv + 1] = "-f"
  argv[#argv + 1] = "body=" .. body
  argv[#argv + 1] = "-f"
  argv[#argv + 1] = "in_reply_to=" .. reply_to_id
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return nil, res.error
  end
  local data, err = base.parse_json(res)
  if not data then
    return nil, err
  end
  return tostring(data.databaseId or data.id), nil
end

--- Update/edit a comment.
---@param cfg table
---@param ctx table
---@param number integer
---@param thread_id string
---@param comment_id string
---@param body string
---@return boolean, string|nil
function M.update_comment(cfg, ctx, number, thread_id, comment_id, body)
  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = string.format("repos/{owner}/{repo}/pulls/comments/%s", comment_id)
  argv[#argv + 1] = "-X"
  argv[#argv + 1] = "PATCH"
  argv[#argv + 1] = "-f"
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
---@param comment_id string
---@return boolean, string|nil
function M.delete_comment(cfg, ctx, number, thread_id, comment_id)
  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = string.format("repos/{owner}/{repo}/pulls/comments/%s", comment_id)
  argv[#argv + 1] = "-X"
  argv[#argv + 1] = "DELETE"
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Close a pull request.
---@param cfg table
---@param ctx table
---@param number integer
---@return boolean, string|nil
function M.close_mr(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "pr"
  argv[#argv + 1] = "close"
  argv[#argv + 1] = tostring(number)
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Approve a pull request.
---@param cfg table
---@param ctx table
---@param number integer
---@return boolean, string|nil
function M.approve_mr(cfg, ctx, number)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "pr"
  argv[#argv + 1] = "review"
  argv[#argv + 1] = tostring(number)
  argv[#argv + 1] = "--approve"
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Discover pull request templates in the repo.
--- GitHub looks for .github/PULL_REQUEST_TEMPLATE.md and
--- .github/PULL_REQUEST_TEMPLATE/*.md (plus root/docs variants).
---@param cfg table
---@param ctx table
---@return table[]|nil, string|nil  -- { name, path, content }[]
function M.list_templates(cfg, ctx)
  local candidates = {
    ".github/PULL_REQUEST_TEMPLATE.md",
    "PULL_REQUEST_TEMPLATE.md",
    "docs/PULL_REQUEST_TEMPLATE.md",
  }
  local out = {}
  local seen = {}
  for _, rel in ipairs(candidates) do
    local abs = ctx.cwd .. "/" .. rel
    local f = io.open(abs, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local name = rel:match("([^/]+)%.md$") or rel
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = { name = name, path = rel, content = content }
      end
    end
  end
  -- Directory form: .github/PULL_REQUEST_TEMPLATE/*.md
  local dir = ctx.cwd .. "/.github/PULL_REQUEST_TEMPLATE"
  local p = io.popen("ls " .. vim.fn.shellescape(dir) .. " 2>/dev/null")
  if p then
    for line in p:lines() do
      if line:match("%.md$") then
        local rel = ".github/PULL_REQUEST_TEMPLATE/" .. line
        local f = io.open(ctx.cwd .. "/" .. rel, "r")
        if f then
          local content = f:read("*a")
          f:close()
          local name = line:match("([^/]+)%.md$") or line
          if not seen[name] then
            seen[name] = true
            out[#out + 1] = { name = name, path = rel, content = content }
          end
        end
      end
    end
    p:close()
  end
  return out, nil
end

--- Create a pull request.
---@param cfg table
---@param ctx table
---@param opts table  -- { title, body, source_branch, target_branch }
---@return string|nil url, string|nil err
function M.create_mr(cfg, ctx, opts)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "pr"
  argv[#argv + 1] = "create"
  argv[#argv + 1] = "--title"
  argv[#argv + 1] = opts.title
  if opts.body and opts.body ~= "" then
    argv[#argv + 1] = "--body"
    argv[#argv + 1] = opts.body
  end
  if opts.target_branch and opts.target_branch ~= "" then
    argv[#argv + 1] = "--base"
    argv[#argv + 1] = opts.target_branch
  end
  if opts.source_branch and opts.source_branch ~= "" then
    argv[#argv + 1] = "--head"
    argv[#argv + 1] = opts.source_branch
  end
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return nil, res.error
  end
  -- gh pr create prints the PR URL on success.
  local url = res.stdout:match("https?://%S+")
  return url, nil
end

--- Resolve or unresolve a comment thread on GitHub.
---@param cfg table
---@param ctx table
---@param mr_number integer
---@param thread_id string
---@param resolved boolean
---@return boolean, string|nil
function M.resolve_thread(cfg, ctx, mr_number, thread_id, resolved)
  local argv = api_argv(cfg, ctx)
  argv[#argv + 1] = "graphql"
  local mutation = resolved and "resolveReviewThread" or "unresolveReviewThread"
  local query = string.format([[
    mutation($id: ID!) {
      %s(input: {threadId: $id}) {
        thread { isResolved }
      }
    }
  ]], mutation)
  argv[#argv + 1] = "-f"
  argv[#argv + 1] = "query=" .. query
  argv[#argv + 1] = "-F"
  argv[#argv + 1] = "id=" .. thread_id
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

--- Update the PR title and body on GitHub.
---@param cfg table
---@param ctx table
---@param number integer
---@param title string
---@param body string
---@return boolean, string|nil
function M.update_mr(cfg, ctx, number, title, body)
  local argv = base_argv(cfg, ctx)
  argv[#argv + 1] = "pr"
  argv[#argv + 1] = "edit"
  argv[#argv + 1] = tostring(number)
  argv[#argv + 1] = "--title"
  argv[#argv + 1] = title
  argv[#argv + 1] = "--body"
  argv[#argv + 1] = body
  local res = base.run(argv, { cwd = ctx.cwd })
  if not res.ok then
    return false, res.error
  end
  return true, nil
end

return M
